import snowflake from "snowflake-sdk";
import fs from "fs";

snowflake.configure({ logLevel: "ERROR" });

let connection: snowflake.Connection | null = null;
let cachedToken: string | null = null;

export function getSchema(): string {
  return process.env.SNOWFLAKE_SCHEMA || "BOM3";
}

export function getDatabase(): string {
  return process.env.SNOWFLAKE_DATABASE || "BOM";
}

export function getFullTableName(table: string): string {
  return `${getDatabase()}.${getSchema()}.${table}`;
}

export function getSemanticView(): string {
  const schema = getSchema();
  return schema === "BOM4" 
    ? `${getDatabase()}.${schema}.TRUCK_CONFIG_ANALYST_V2`
    : `${getDatabase()}.${schema}.TRUCK_CONFIG_ANALYST`;
}

export function getCortexAgent(): string {
  const schema = getSchema();
  return schema === "BOM4"
    ? `${getDatabase()}/schemas/${schema}/agents/TRUCK_CONFIG_AGENT_V2`
    : `${getDatabase()}/schemas/${schema}/agents/TRUCK_CONFIG_AGENT`;
}

export function getCortexSearchService(): string {
  return `${getDatabase()}.${getSchema()}.ENGINEERING_DOCS_SEARCH`;
}

function getPrivateKey(): string | null {
  let privateKeyPem = process.env.SNOWFLAKE_PRIVATE_KEY || "";
  if (!privateKeyPem) return null;
  
  privateKeyPem = privateKeyPem.replace(/\\n/g, '\n');
  
  if (!privateKeyPem.includes("-----BEGIN")) {
    privateKeyPem = `-----BEGIN PRIVATE KEY-----\n${privateKeyPem}\n-----END PRIVATE KEY-----`;
  }
  
  return privateKeyPem;
}

function getConfig(): snowflake.ConnectionOptions {
  const privateKey = getPrivateKey();
  if (privateKey) {
    console.log("Using Key-Pair authentication");
    return {
      account: process.env.SNOWFLAKE_ACCOUNT || "SFSENORTHAMERICA-AWSBARBARIAN",
      username: process.env.SNOWFLAKE_USER || "Horizonadmin",
      authenticator: "SNOWFLAKE_JWT",
      privateKey: privateKey,
      warehouse: process.env.SNOWFLAKE_WAREHOUSE || "DEMO_WH",
      database: getDatabase(),
      schema: getSchema(),
    } as snowflake.ConnectionOptions;
  }

  // Fallback to PAT for local dev (set SNOWFLAKE_PAT env var)
  console.log("Using PAT authentication");
  const pat = process.env.SNOWFLAKE_PAT || "";
  
  return {
    account: process.env.SNOWFLAKE_ACCOUNT || "SFSENORTHAMERICA-AWSBARBARIAN",
    host: process.env.SNOWFLAKE_HOST || "sfsenorthamerica-awsbarbarian.snowflakecomputing.com",
    username: process.env.SNOWFLAKE_USER || "Horizonadmin",
    password: pat,
    warehouse: process.env.SNOWFLAKE_WAREHOUSE || "DEMO_WH",
    database: getDatabase(),
    schema: getSchema(),
  };
}

export async function getConnection(): Promise<snowflake.Connection> {
  if (connection) {
    return connection;
  }

  const config = getConfig();
  
  const conn = snowflake.createConnection(config);
  
  await new Promise<void>((resolve, reject) => {
    conn.connect((err) => {
      if (err) reject(err);
      else resolve();
    });
  });
  
  connection = conn;
  return connection;
}

function isRetryableError(err: unknown): boolean {
  const error = err as { message?: string; code?: number };
  return !!(
    error.message?.includes("OAuth access token expired") ||
    error.message?.includes("terminated connection") ||
    error.code === 407002
  );
}

export async function query<T>(sql: string, retries = 1): Promise<T[]> {
  try {
    const conn = await getConnection();
    return await new Promise<T[]>((resolve, reject) => {
      conn.execute({
        sqlText: sql,
        complete: (err, stmt, rows) => {
          if (err) {
            reject(err);
          } else {
            resolve((rows || []) as T[]);
          }
        },
      });
    });
  } catch (err) {
    console.error("Query error:", (err as Error).message);
    if (retries > 0 && isRetryableError(err)) {
      connection = null;
      return query(sql, retries - 1);
    }
    throw err;
  }
}

export async function putFile(localPath: string, stagePath: string): Promise<void> {
  const conn = await getConnection();
  const sql = `PUT 'file://${localPath}' '${stagePath}' AUTO_COMPRESS=FALSE OVERWRITE=TRUE`;
  console.log("PUT command:", sql);
  
  return new Promise<void>((resolve, reject) => {
    conn.execute({
      sqlText: sql,
      complete: (err) => {
        if (err) {
          console.error("PUT error:", err);
          reject(err);
        } else {
          resolve();
        }
      },
    });
  });
}

export async function getFile(stagePath: string, localDir: string): Promise<string> {
  const conn = await getConnection();
  const sql = `GET '${stagePath}' 'file://${localDir}'`;
  
  return new Promise<string>((resolve, reject) => {
    conn.execute({
      sqlText: sql,
      complete: (err, stmt, rows) => {
        if (err) {
          console.error("GET error:", err);
          reject(err);
        } else if (rows && rows.length > 0) {
          const result = rows[0] as { file: string; status: string };
          resolve(result.file || '');
        } else {
          resolve('');
        }
      },
    });
  });
}
