import os
import json
import time
import hashlib
import base64
from typing import Optional, List, Dict, Any
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import snowflake.connector
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
import jwt

app = FastAPI(title="Truck Configurator API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SNOWFLAKE_ACCOUNT = os.getenv("SNOWFLAKE_ACCOUNT", "")
SNOWFLAKE_HOST = os.getenv("SNOWFLAKE_HOST", f"{SNOWFLAKE_ACCOUNT}.snowflakecomputing.com" if SNOWFLAKE_ACCOUNT else "")
SNOWFLAKE_WAREHOUSE = os.getenv("SNOWFLAKE_WAREHOUSE", "DEMO_WH")
SNOWFLAKE_DATABASE = os.getenv("SNOWFLAKE_DATABASE", "BOM")
SNOWFLAKE_SCHEMA = os.getenv("SNOWFLAKE_SCHEMA", "TRUCK_CONFIG")
SNOWFLAKE_USER = os.getenv("SNOWFLAKE_USER", "")

_connection = None
_jwt_token = None
_jwt_expiry = 0

def get_spcs_token() -> Optional[str]:
    token_path = "/snowflake/session/token"
    try:
        if os.path.exists(token_path):
            with open(token_path, "r") as f:
                return f.read().strip()
    except Exception:
        pass
    return None

def generate_jwt_token() -> str:
    """Generate JWT token using private key for REST API authentication"""
    global _jwt_token, _jwt_expiry
    
    current_time = int(time.time())
    if _jwt_token and current_time < _jwt_expiry - 60:
        return _jwt_token
    
    private_key_pem = os.getenv("SNOWFLAKE_PRIVATE_KEY", "")
    if not private_key_pem:
        raise ValueError("SNOWFLAKE_PRIVATE_KEY not set")
    
    if "-----BEGIN" not in private_key_pem:
        private_key_pem = f"-----BEGIN PRIVATE KEY-----\n{private_key_pem}\n-----END PRIVATE KEY-----"
    
    private_key = serialization.load_pem_private_key(
        private_key_pem.encode(),
        password=None,
        backend=default_backend()
    )
    
    public_key = private_key.public_key()
    public_key_bytes = public_key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo
    )
    sha256hash = hashlib.sha256()
    sha256hash.update(public_key_bytes)
    public_key_fp = "SHA256:" + base64.b64encode(sha256hash.digest()).decode('utf-8')
    
    account_for_jwt = SNOWFLAKE_ACCOUNT.upper()
    if "-" in account_for_jwt:
        account_for_jwt = account_for_jwt.replace("-", "_")
    
    qualified_username = f"{account_for_jwt}.{SNOWFLAKE_USER.upper()}"
    
    print(f"JWT qualified_username: {qualified_username}")
    print(f"JWT public_key_fp: {public_key_fp}")
    
    now = int(time.time())
    lifetime = 59 * 60
    
    payload = {
        "iss": f"{qualified_username}.{public_key_fp}",
        "sub": qualified_username,
        "iat": now,
        "exp": now + lifetime
    }
    
    _jwt_token = jwt.encode(payload, private_key, algorithm="RS256")
    _jwt_expiry = now + lifetime
    
    print(f"Generated new JWT token, expires in {lifetime}s")
    return _jwt_token

def get_auth_header() -> Dict[str, str]:
    """Get authentication header for Snowflake REST APIs.
    
    IMPORTANT: SPCS OAuth token (/snowflake/session/token) CANNOT be used for REST APIs!
    It only works for drivers (Python connector, Snowpark Session).
    For REST APIs, use PAT (Personal Access Token) or external OAuth.
    """
    pat = os.getenv("SNOWFLAKE_PAT", "")
    if pat:
        print("Using PAT for REST API")
        return {
            "Authorization": f"Bearer {pat}",
            "X-Snowflake-Authorization-Token-Type": "PROGRAMMATIC_ACCESS_TOKEN",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    private_key_pem = os.getenv("SNOWFLAKE_PRIVATE_KEY", "")
    if private_key_pem:
        try:
            jwt_token = generate_jwt_token()
            print("Using JWT token for REST API")
            return {
                "Authorization": f"Bearer {jwt_token}",
                "Content-Type": "application/json"
            }
        except Exception as e:
            print(f"JWT generation failed: {e}")
    
    raise ValueError("No REST API authentication available - need PAT or JWT")

def get_connection():
    global _connection
    if _connection is not None:
        try:
            _connection.cursor().execute("SELECT 1")
            return _connection
        except:
            _connection = None
    
    token = get_spcs_token()
    private_key_pem = os.getenv("SNOWFLAKE_PRIVATE_KEY", "")
    
    if private_key_pem:
        print("Connecting with Key-Pair authentication")
        if "-----BEGIN" not in private_key_pem:
            private_key_pem = f"-----BEGIN PRIVATE KEY-----\n{private_key_pem}\n-----END PRIVATE KEY-----"
        _connection = snowflake.connector.connect(
            account=SNOWFLAKE_ACCOUNT,
            user=SNOWFLAKE_USER,
            private_key=serialization.load_pem_private_key(
                private_key_pem.encode(),
                password=None,
                backend=default_backend()
            ),
            warehouse=SNOWFLAKE_WAREHOUSE,
            database=SNOWFLAKE_DATABASE,
            schema=SNOWFLAKE_SCHEMA,
        )
    elif token:
        print("Connecting with SPCS OAuth token")
        # CRITICAL: Must use host from SNOWFLAKE_HOST env var for SPCS internal network
        _connection = snowflake.connector.connect(
            host=SNOWFLAKE_HOST,
            account=SNOWFLAKE_ACCOUNT,
            authenticator="oauth",
            token=token,
            warehouse=SNOWFLAKE_WAREHOUSE,
            database=SNOWFLAKE_DATABASE,
            schema=SNOWFLAKE_SCHEMA,
        )
    else:
        print("Connecting with connection name (local dev)")
        conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "awsbarbarian_CoCo")
        _connection = snowflake.connector.connect(
            connection_name=conn_name,
            warehouse=SNOWFLAKE_WAREHOUSE,
            database=SNOWFLAKE_DATABASE,
            schema=SNOWFLAKE_SCHEMA,
        )
    
    return _connection

def query(sql: str) -> List[Dict]:
    conn = get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(sql)
        if cursor.description:
            columns = [col[0] for col in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]
        return []
    finally:
        cursor.close()

def query_single(sql: str) -> Any:
    conn = get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(sql)
        row = cursor.fetchone()
        return row[0] if row else None
    finally:
        cursor.close()

def get_semantic_view() -> str:
    return f"{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_CONFIG_ANALYST_V2"

def get_cortex_agent_path() -> str:
    return f"{SNOWFLAKE_DATABASE}/schemas/{SNOWFLAKE_SCHEMA}/agents/TRUCK_CONFIG_AGENT_V2"

# ============ CORTEX AI FUNCTIONS ============

def optimize_via_sql(model_id: str, categories_to_maximize: List[str], minimize_cost: bool) -> Dict[str, Any]:
    """Use direct SQL for optimization - bypasses REST API auth issues"""
    try:
        print(f"SQL-based optimization: model={model_id}, maximize={categories_to_maximize}, minimize_cost={minimize_cost}")
        
        if categories_to_maximize and minimize_cost:
            cat_list = ", ".join([f"'{c}'" for c in categories_to_maximize])
            sql = f"""
                WITH component_priority AS (
                    SELECT 
                        b.COMPONENT_GROUP,
                        MAX(CASE WHEN b.PERFORMANCE_CATEGORY IN ({cat_list}) THEN 1 ELSE 0 END) as should_maximize
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    WHERE t.MODEL_ID = '{model_id}'
                    GROUP BY b.COMPONENT_GROUP
                ),
                ranked_maximize AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.PERFORMANCE_SCORE DESC, b.COST_USD ASC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    JOIN component_priority cp ON b.COMPONENT_GROUP = cp.COMPONENT_GROUP
                    WHERE t.MODEL_ID = '{model_id}'
                      AND cp.should_maximize = 1
                      AND b.PERFORMANCE_CATEGORY IN ({cat_list})
                ),
                ranked_minimize AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.COST_USD ASC, b.PERFORMANCE_SCORE DESC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    JOIN component_priority cp ON b.COMPONENT_GROUP = cp.COMPONENT_GROUP
                    WHERE t.MODEL_ID = '{model_id}'
                      AND cp.should_maximize = 0
                )
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, 
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_maximize WHERE rn = 1
                UNION ALL
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, 
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_minimize WHERE rn = 1
                ORDER BY SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP
            """
        elif categories_to_maximize:
            cat_list = ", ".join([f"'{c}'" for c in categories_to_maximize])
            sql = f"""
                WITH relevant_component_groups AS (
                    -- Only find component groups that have options matching the requested categories
                    SELECT DISTINCT b.COMPONENT_GROUP
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    WHERE t.MODEL_ID = '{model_id}'
                      AND b.PERFORMANCE_CATEGORY IN ({cat_list})
                ),
                ranked_options AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.PERFORMANCE_SCORE DESC, b.COST_USD ASC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    JOIN relevant_component_groups rcg ON b.COMPONENT_GROUP = rcg.COMPONENT_GROUP
                    WHERE t.MODEL_ID = '{model_id}'
                      AND b.PERFORMANCE_CATEGORY IN ({cat_list})
                )
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS,
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_options
                WHERE rn = 1
                ORDER BY SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP
            """
        else:
            sql = f"""
                WITH ranked_options AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.COST_USD ASC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    WHERE t.MODEL_ID = '{model_id}'
                )
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS,
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_options
                WHERE rn = 1
                ORDER BY SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP
            """
        
        results = query(sql)
        print(f"SQL optimization returned {len(results)} rows")
        return {"results": results, "sql": sql, "error": None}
    except Exception as e:
        print(f"SQL optimization failed: {e}")
        return {"results": [], "sql": None, "error": str(e)}

def optimize_via_sql_weight(model_id: str, categories_to_maximize: List[str], minimize_weight: bool) -> Dict[str, Any]:
    """Optimize configuration prioritizing weight minimization"""
    try:
        print(f"Weight optimization: model={model_id}, maximize={categories_to_maximize}, minimize_weight={minimize_weight}")
        
        if categories_to_maximize and minimize_weight:
            # Maximize specified categories, minimize weight for others
            cat_list = ", ".join([f"'{c}'" for c in categories_to_maximize])
            sql = f"""
                WITH component_priority AS (
                    SELECT 
                        b.COMPONENT_GROUP,
                        MAX(CASE WHEN b.PERFORMANCE_CATEGORY IN ({cat_list}) THEN 1 ELSE 0 END) as should_maximize
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    WHERE t.MODEL_ID = '{model_id}'
                    GROUP BY b.COMPONENT_GROUP
                ),
                ranked_maximize AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.PERFORMANCE_SCORE DESC, b.WEIGHT_LBS ASC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    JOIN component_priority cp ON b.COMPONENT_GROUP = cp.COMPONENT_GROUP
                    WHERE t.MODEL_ID = '{model_id}'
                      AND cp.should_maximize = 1
                      AND b.PERFORMANCE_CATEGORY IN ({cat_list})
                ),
                ranked_minimize AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.WEIGHT_LBS ASC, b.PERFORMANCE_SCORE DESC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    JOIN component_priority cp ON b.COMPONENT_GROUP = cp.COMPONENT_GROUP
                    WHERE t.MODEL_ID = '{model_id}'
                      AND cp.should_maximize = 0
                )
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, 
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_maximize WHERE rn = 1
                UNION ALL
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, 
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_minimize WHERE rn = 1
                ORDER BY SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP
            """
        else:
            # Just minimize weight across all components
            sql = f"""
                WITH ranked_options AS (
                    SELECT 
                        b.OPTION_ID, b.OPTION_NM, b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS,
                        b.PERFORMANCE_CATEGORY, b.PERFORMANCE_SCORE, b.SYSTEM_NM, b.SUBSYSTEM_NM,
                        ROW_NUMBER() OVER (PARTITION BY b.COMPONENT_GROUP ORDER BY b.WEIGHT_LBS ASC) as rn
                    FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                    JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                    WHERE t.MODEL_ID = '{model_id}'
                )
                SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS,
                       PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, SYSTEM_NM, SUBSYSTEM_NM
                FROM ranked_options
                WHERE rn = 1
                ORDER BY SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP
            """
        
        results = query(sql)
        print(f"Weight optimization returned {len(results)} rows")
        return {"results": results, "sql": sql, "error": None}
    except Exception as e:
        print(f"Weight optimization failed: {e}")
        return {"results": [], "sql": None, "error": str(e)}

def call_cortex_analyst_via_complete(question: str, model_id: str) -> Dict[str, Any]:
    """Use Cortex COMPLETE to generate SQL for optimization - works via SQL connector"""
    try:
        schema_info = f"""
Tables in {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}:
- BOM_TBL: OPTION_ID, OPTION_NM, SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, PERFORMANCE_CATEGORY (Safety|Comfort|Power|Economy|Durability|Hauling), PERFORMANCE_SCORE (1-10)
- TRUCK_OPTIONS: MODEL_ID, OPTION_ID, IS_DEFAULT (join table linking models to available options)
- MODEL_TBL: MODEL_ID, MODEL_NM, BASE_MSRP, BASE_WEIGHT_LBS

Current MODEL_ID: {model_id}
"""
        
        prompt = f"""You are a SQL expert. Generate a Snowflake SQL query for this request.

{schema_info}

User request: {question}

Requirements:
1. Join BOM_TBL with TRUCK_OPTIONS to get options for the specific MODEL_ID
2. Return: OPTION_ID, OPTION_NM, COMPONENT_GROUP, COST_USD, WEIGHT_LBS, PERFORMANCE_CATEGORY, PERFORMANCE_SCORE
3. Select ONE best option per COMPONENT_GROUP based on the user's optimization criteria
4. Use window functions with ROW_NUMBER() partitioned by COMPONENT_GROUP

Return ONLY the SQL query, no explanation."""

        escaped_prompt = prompt.replace("'", "''").replace("\\", "\\\\")
        sql = f"SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', '{escaped_prompt}') as response"
        result = query_single(sql)
        
        if result:
            generated_sql = result.strip()
            if generated_sql.startswith("```"):
                generated_sql = generated_sql.split("```")[1]
                if generated_sql.startswith("sql"):
                    generated_sql = generated_sql[3:]
            generated_sql = generated_sql.strip()
            
            if generated_sql.upper().startswith("SELECT"):
                print(f"COMPLETE generated SQL: {generated_sql[:200]}...")
                return {"response": None, "sql": generated_sql, "error": None}
        
        return {"response": None, "sql": None, "error": "Failed to generate SQL"}
    except Exception as e:
        print(f"Cortex COMPLETE SQL generation failed: {e}")
        return {"response": None, "sql": None, "error": str(e)}

def call_cortex_agent(message: str) -> Dict[str, Any]:
    """Call Cortex Agent REST API with proper authentication"""
    agent_path = get_cortex_agent_path()
    url = f"https://{SNOWFLAKE_HOST}/api/v2/databases/{agent_path}:run"
    
    request_body = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": message}]}]
    }
    
    headers = get_auth_header()
    headers["Accept"] = "text/event-stream"
    
    print(f"Calling Cortex Agent: {message[:100]}...")
    
    try:
        response = requests.post(url, json=request_body, headers=headers, timeout=120, stream=True)
        
        if not response.ok:
            print(f"Agent error: {response.status_code}")
            return {"response": None, "error": response.text}
        
        full_text = ""
        for line in response.iter_lines():
            if line:
                line_str = line.decode('utf-8')
                if line_str.startswith("data: "):
                    try:
                        data = json.loads(line_str[6:])
                        if data.get("role") == "assistant" and data.get("content"):
                            for item in data["content"]:
                                if item.get("type") == "text":
                                    full_text = item.get("text", "")
                        if data.get("text") and not data.get("content_index"):
                            full_text += data.get("text", "")
                    except json.JSONDecodeError:
                        pass
        
        print(f"Agent returned {len(full_text)} chars")
        return {"response": full_text, "error": None}
    except Exception as e:
        print(f"Agent call failed: {e}")
        return {"response": None, "error": str(e)}

def call_cortex_complete(prompt: str, model: str = "claude-3-5-sonnet") -> str:
    """Call Cortex Complete via SQL (always works with SPCS)"""
    try:
        escaped_prompt = prompt.replace("'", "''").replace("\\", "\\\\")
        sql = f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{model}', '{escaped_prompt}') as response"
        result = query_single(sql)
        return result if result else ""
    except Exception as e:
        print(f"Cortex COMPLETE error: {e}")
        return ""

def call_cortex_search(search_query: str, limit: int = 5) -> List[Dict]:
    """Call Cortex Search via SQL using SEARCH_PREVIEW"""
    try:
        escaped_query = search_query.replace("'", "''").replace('"', '\\"')
        sql = f"""
            SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                '{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_SEARCH',
                '{{"query": "{escaped_query}", "columns": ["CHUNK_TEXT", "DOC_TITLE", "DOC_ID"], "limit": {limit}}}'
            )):results as results
        """
        result = query_single(sql)
        if result:
            import json
            parsed = json.loads(result) if isinstance(result, str) else result
            return parsed if isinstance(parsed, list) else []
        return []
    except Exception as e:
        print(f"Cortex Search error: {e}")
        return []

# ============ API ENDPOINTS ============

@app.get("/api/health")
def health():
    try:
        query("SELECT 1")
        return {"status": "ok", "database": "connected"}
    except Exception as e:
        return {"status": "error", "error": str(e)}

@app.get("/api/models")
def get_models():
    try:
        sql = f"SELECT * FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.MODEL_TBL ORDER BY BASE_MSRP"
        return query(sql)
    except Exception as e:
        print(f"Error fetching models: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/options")
def get_options(modelId: Optional[str] = None):
    try:
        base_sql = f"""
            SELECT b.OPTION_ID, b.OPTION_NM, t.MODEL_ID, b.SYSTEM_NM, b.SUBSYSTEM_NM, 
                   b.COMPONENT_GROUP, b.COST_USD, b.WEIGHT_LBS, b.PERFORMANCE_CATEGORY, 
                   b.PERFORMANCE_SCORE, t.IS_DEFAULT, b.DESCRIPTION, b.SPECS
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t
            JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b ON t.OPTION_ID = b.OPTION_ID
        """
        if modelId:
            sql = f"{base_sql} WHERE t.MODEL_ID = '{modelId}' ORDER BY b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP, b.COST_USD"
        else:
            sql = f"{base_sql} ORDER BY b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP, b.COST_USD"
        
        options = query(sql)
        
        # Parse SPECS JSON for each option
        for opt in options:
            if opt.get("SPECS") and isinstance(opt["SPECS"], str):
                try:
                    opt["SPECS"] = json.loads(opt["SPECS"])
                except:
                    pass
        
        hierarchy = {}
        for opt in options:
            system = opt.get("SYSTEM_NM", "Other")
            subsystem = opt.get("SUBSYSTEM_NM", "Other")
            component_group = opt.get("COMPONENT_GROUP", "Other")
            
            if system not in hierarchy:
                hierarchy[system] = {"subsystems": {}}
            if subsystem not in hierarchy[system]["subsystems"]:
                hierarchy[system]["subsystems"][subsystem] = {"componentGroups": {}}
            if component_group not in hierarchy[system]["subsystems"][subsystem]["componentGroups"]:
                hierarchy[system]["subsystems"][subsystem]["componentGroups"][component_group] = []
            hierarchy[system]["subsystems"][subsystem]["componentGroups"][component_group].append(opt)
        
        model_options = [{"OPTION_ID": str(opt["OPTION_ID"]), "IS_DEFAULT": opt.get("IS_DEFAULT", False)} for opt in options]
        
        return {"hierarchy": hierarchy, "options": options, "modelOptions": model_options}
    except Exception as e:
        print(f"Error fetching options: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/configs")
def get_configs():
    try:
        sql = f"""
            SELECT CONFIG_ID, CONFIG_NAME, MODEL_ID, CONFIG_OPTIONS, 
                   TOTAL_COST_USD, TOTAL_WEIGHT_LBS, PERFORMANCE_SUMMARY, NOTES,
                   IS_VALIDATED, CREATED_AT
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.SAVED_CONFIGS
            ORDER BY CREATED_AT DESC
        """
        results = query(sql)
        for r in results:
            if r.get("CONFIG_OPTIONS") and isinstance(r["CONFIG_OPTIONS"], str):
                try:
                    r["CONFIG_OPTIONS"] = json.loads(r["CONFIG_OPTIONS"])
                except:
                    pass
            if r.get("PERFORMANCE_SUMMARY") and isinstance(r["PERFORMANCE_SUMMARY"], str):
                try:
                    r["PERFORMANCE_SUMMARY"] = json.loads(r["PERFORMANCE_SUMMARY"])
                except:
                    pass
        return results
    except Exception as e:
        print(f"Error fetching configs: {e}")
        raise HTTPException(status_code=500, detail=str(e))

class SaveConfigRequest(BaseModel):
    configName: str
    modelId: str
    selectedOptions: List[str]
    totalCost: float
    totalWeight: float
    performanceSummary: Dict[str, Any]
    notes: Optional[str] = ""
    isValidated: Optional[bool] = False

@app.post("/api/configs")
def save_config(req: SaveConfigRequest):
    try:
        config_id = f"CFG-{int(time.time() * 1000)}"
        options_json = json.dumps(req.selectedOptions).replace("'", "''")
        perf_json = json.dumps(req.performanceSummary).replace("'", "''")
        notes_escaped = (req.notes or "").replace("'", "''")
        
        sql = f"""
            INSERT INTO {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.SAVED_CONFIGS 
            (CONFIG_ID, CONFIG_NAME, MODEL_ID, CONFIG_OPTIONS, TOTAL_COST_USD, TOTAL_WEIGHT_LBS, 
             PERFORMANCE_SUMMARY, NOTES, IS_VALIDATED)
            SELECT '{config_id}', '{req.configName.replace("'", "''")}', '{req.modelId}', 
                   PARSE_JSON('{options_json}'), {req.totalCost}, {req.totalWeight},
                   PARSE_JSON('{perf_json}'), '{notes_escaped}', {str(req.isValidated).upper()}
        """
        query(sql)
        
        return {"success": True, "configId": config_id}
    except Exception as e:
        print(f"Error saving config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/api/configs/{config_id}")
def delete_config_by_path(config_id: str):
    try:
        sql = f"""
            DELETE FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.SAVED_CONFIGS 
            WHERE CONFIG_ID = '{config_id.replace("'", "''")}'
        """
        query(sql)
        return {"success": True}
    except Exception as e:
        print(f"Error deleting config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/api/configs")
def delete_config_by_query(configId: str = None):
    if not configId:
        raise HTTPException(status_code=400, detail="configId query parameter is required")
    try:
        sql = f"""
            DELETE FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.SAVED_CONFIGS 
            WHERE CONFIG_ID = '{configId.replace("'", "''")}'
        """
        query(sql)
        return {"success": True}
    except Exception as e:
        print(f"Error deleting config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

class UpdateConfigRequest(BaseModel):
    configId: str
    configName: str
    notes: Optional[str] = ""

@app.put("/api/configs")
def update_config(req: UpdateConfigRequest):
    try:
        sql = f"""
            UPDATE {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.SAVED_CONFIGS 
            SET CONFIG_NAME = '{req.configName.replace("'", "''")}',
                NOTES = '{(req.notes or "").replace("'", "''")}',
                UPDATED_AT = CURRENT_TIMESTAMP()
            WHERE CONFIG_ID = '{req.configId.replace("'", "''")}'
        """
        query(sql)
        return {"success": True}
    except Exception as e:
        print(f"Error updating config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ============ CHAT / OPTIMIZATION ============

class ChatRequest(BaseModel):
    message: str
    modelId: Optional[str] = None
    selectedOptions: Optional[List[Any]] = None
    modelInfo: Optional[Dict[str, Any]] = None
    
    class Config:
        extra = "allow"

@app.post("/api/chat")
def chat(req: ChatRequest):
    """Handle chat requests using Cortex AI - all via SQL (works with SPCS)"""
    try:
        message = req.message
        model_id = req.modelId
        
        if not model_id and req.modelInfo:
            model_id = req.modelInfo.get("modelId")
        
        if not model_id:
            return {"response": "Please select a truck model first to get optimization recommendations."}
        
        selected_option_ids = []
        if req.selectedOptions:
            if isinstance(req.selectedOptions, list):
                for opt in req.selectedOptions:
                    if isinstance(opt, dict):
                        selected_option_ids.append(str(opt.get("optionId", "")))
                    else:
                        selected_option_ids.append(str(opt))
        
        print(f"=== CHAT REQUEST ===")
        print(f"Message: {message}")
        print(f"Model: {model_id}")
        print(f"Selected Options Count: {len(selected_option_ids)}")
        
        lower_msg = message.lower()
        
        # Check if asking about engineering docs / specifications
        is_doc_query = any(kw in lower_msg for kw in ['specification', 'document', 'attached', 'linked', 'spec doc', 'engineering doc', 'which options have', 'what has'])
        
        if is_doc_query:
            return handle_doc_query(message, model_id)
        
        # Check if this is a general question (use Cortex Search + Complete)
        is_general_question = any(kw in lower_msg for kw in ['what', 'which', 'highest', 'default', 'power rating', 'tell me', 'show me', 'list'])
        is_optimization = any(kw in lower_msg for kw in ['maximize', 'minimize', 'optimize', 'best', 'cheapest', 'lightest', 'lightweight', 'recommend', 'performance', 'all categories'])
        
        # Handle general questions using Cortex Search + Complete
        if is_general_question and not is_optimization:
            print("Handling general question with Cortex Search + Complete")
            return handle_general_question(message, model_id, selected_option_ids)
        
        if is_optimization:
            print("Using Cortex AI to generate optimization SQL...")
            
            ai_result = generate_optimization_sql_with_ai(message, model_id)
            
            # Check if we have direct results (from our optimized SQL functions)
            results_to_use = ai_result.get('direct_results', [])
            
            if not results_to_use and ai_result.get("sql"):
                try:
                    results_to_use = query(ai_result["sql"])
                    print(f"AI-generated SQL returned {len(results_to_use)} rows")
                except Exception as sql_err:
                    print(f"SQL execution failed: {sql_err}")
            
            if results_to_use:
                recommendations = []
                recommended_ids = []
                for r in results_to_use:
                    cg = r.get("COMPONENT_GROUP", r.get("component_group", ""))
                    opt_id = str(r.get("OPTION_ID", r.get("option_id", "")))
                    score = float(r.get("PERFORMANCE_SCORE", r.get("performance_score", 0)) or 0)
                    cost = float(r.get("COST_USD", r.get("cost_usd", 0)) or 0)
                    weight = float(r.get("WEIGHT_LBS", r.get("weight_lbs", 0)) or 0)
                    perf_cat = r.get("PERFORMANCE_CATEGORY", r.get("performance_category", ""))
                    
                    recommended_ids.append(opt_id)
                    
                    # Generate reason
                    if score >= 8:
                        reason = f"Top performer ({perf_cat}, score: {score})"
                    elif cost == 0:
                        reason = "Base option ($0)"
                    elif cost <= 500:
                        reason = f"Budget-friendly (${cost:,.0f})"
                    else:
                        reason = f"{perf_cat} (score: {score})"
                    
                    recommendations.append({
                        "optionId": opt_id,
                        "optionName": r.get("OPTION_NM", r.get("option_nm", "")),
                        "componentGroup": cg,
                        "cost": cost,
                        "weight": weight,
                        "reason": reason,
                        "action": "optimize",
                        "performanceCategory": perf_cat
                    })
                
                if recommendations:
                    total_cost = sum(r["cost"] for r in recommendations)
                    total_weight = sum(r["weight"] for r in recommendations)
                    
                    summary = ai_result.get("summary", f"Found {len(recommendations)} optimizations based on your request.")
                    
                    # Indicate if Cortex Analyst verified query was used
                    analyst_badge = "Powered by Cortex Analyst"
                    if ai_result.get("verified_query"):
                        analyst_badge = f"Powered by Cortex Analyst (Verified Query: {ai_result['verified_query']})"
                    
                    return {
                        "response": f"**AI-Optimized Configuration** ({analyst_badge})\n\n{summary}\n\n**Total: ${total_cost:,.0f}** | Weight: {total_weight:,.0f} lbs\n\nClick Apply to update your configuration.",
                        "recommendations": recommendations,
                        "canApply": True,
                        "applyAction": {
                            "type": "optimize",
                            "optionIds": recommended_ids,
                            "summary": f"Apply {len(recommendations)} Cortex Analyst optimizations"
                        }
                    }
            
            # If AI fails, provide helpful message
            error_msg = ai_result.get('error', '')
            return {"response": f"I understood your request: '{message}'. However, I couldn't generate a valid optimization. Try being more specific, like 'maximize power and safety' or 'minimize all costs'."}
        
        # For non-optimization queries, use Cortex Complete for conversation
        ai_response = call_cortex_complete(f"User asked about truck configuration: {message}. Provide a helpful, concise response about truck configuration options.", "mistral-large2")
        if ai_response:
            return {"response": ai_response}
        
        return {"response": "I can help you optimize your truck configuration. Try asking me to 'maximize comfort and safety while minimizing other costs'."}
    
    except Exception as e:
        print(f"Chat error: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

def handle_doc_query(message: str, model_id: str) -> Dict[str, Any]:
    """Handle questions about engineering documents and linked parts"""
    try:
        # Query engineering docs with their linked parts - LINKED_PARTS contains objects with optionId key
        docs_with_parts = query(f"""
            SELECT DISTINCT 
                d.DOC_ID, d.DOC_TITLE,
                lp.value:optionId::VARCHAR as LINKED_OPTION_ID,
                lp.value:optionName::VARCHAR as LINKED_OPTION_NAME,
                b.OPTION_ID, b.OPTION_NM, b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED d,
                 LATERAL FLATTEN(input => d.LINKED_PARTS) lp
            JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b 
                ON b.OPTION_ID = lp.value:optionId::VARCHAR
            WHERE d.LINKED_PARTS IS NOT NULL AND ARRAY_SIZE(d.LINKED_PARTS) > 0
            ORDER BY b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP
        """)
        
        if not docs_with_parts:
            return {"response": "No engineering specification documents are currently linked to any BOM options. You can upload documents and link them to specific parts in the Engineering Docs panel."}
        
        # Build response
        response_lines = ["**Options with Specification Documents:**\n"]
        for doc in docs_with_parts:
            opt_name = doc.get("OPTION_NM", "") or doc.get("LINKED_OPTION_NAME", "")
            doc_title = doc.get("DOC_TITLE", "")
            system = doc.get("SYSTEM_NM", "")
            subsystem = doc.get("SUBSYSTEM_NM", "")
            cg = doc.get("COMPONENT_GROUP", "")
            
            path = f"{system} → {subsystem} → {cg}"
            response_lines.append(f"• **{opt_name}** has document: *{doc_title}*")
            response_lines.append(f"  BOM Path: {path}\n")
        
        return {"response": "\n".join(response_lines)}
    except Exception as e:
        print(f"Doc query error: {e}")
        return {"response": f"I couldn't retrieve information about specification documents. Error: {str(e)}"}

def handle_general_question(message: str, model_id: str, selected_option_ids: List[str]) -> Dict[str, Any]:
    """Handle general questions using Cortex Search + Complete via SQL"""
    try:
        print(f"General question: {message}")
        lower_msg = message.lower()
        
        # Check for power rating question
        if 'power' in lower_msg and ('highest' in lower_msg or 'default' in lower_msg or 'rating' in lower_msg):
            # Query BOM data directly
            sql = f"""
                SELECT m.MODEL_NM, b.OPTION_NM, b.PERFORMANCE_SCORE, b.COST_USD
                FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.MODEL_TBL m
                JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON m.MODEL_ID = t.MODEL_ID
                JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b ON t.OPTION_ID = b.OPTION_ID
                WHERE b.COMPONENT_GROUP = 'Power Rating' AND t.IS_DEFAULT = TRUE
                ORDER BY b.PERFORMANCE_SCORE DESC
                LIMIT 5
            """
            results = query(sql)
            if results:
                response_lines = ["**Trucks by Default Power Rating:**\n"]
                for r in results:
                    response_lines.append(f"• **{r['MODEL_NM']}**: {r['OPTION_NM']} (score: {r['PERFORMANCE_SCORE']})")
                return {"response": "\n".join(response_lines)}
        
        # Check if asking about documents  
        if 'document' in lower_msg or 'spec' in lower_msg or 'attached' in lower_msg:
            return handle_doc_query(message, model_id)
        
        # Use Cortex Search for context, then Cortex Complete for answer
        search_results = []
        try:
            escaped_query = message.replace("'", "''").replace('"', '\\"')
            search_sql = f"""
                SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                    '{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_SEARCH',
                    '{{"query": "{escaped_query}", "columns": ["CHUNK_TEXT", "DOC_TITLE"], "limit": 3}}'
                )):results as results
            """
            search_result = query_single(search_sql)
            if search_result:
                search_results = json.loads(search_result) if isinstance(search_result, str) else search_result
        except Exception as search_err:
            print(f"Cortex Search error (non-fatal): {search_err}")
        
        # Build context from BOM data
        bom_context = ""
        try:
            bom_sql = f"""
                SELECT DISTINCT COMPONENT_GROUP, OPTION_NM, COST_USD, PERFORMANCE_CATEGORY, PERFORMANCE_SCORE
                FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                WHERE t.MODEL_ID = '{model_id}'
                ORDER BY COMPONENT_GROUP, PERFORMANCE_SCORE DESC
                LIMIT 50
            """
            bom_data = query(bom_sql)
            if bom_data:
                bom_context = "Available options include: " + ", ".join([f"{r['OPTION_NM']} ({r['COMPONENT_GROUP']})" for r in bom_data[:20]])
        except:
            pass
        
        # Build prompt with search context
        doc_context = ""
        if search_results:
            doc_context = "Engineering document context:\n" + "\n".join([f"- {r.get('CHUNK_TEXT', '')[:300]}" for r in search_results[:2]])
        
        prompt = f"""Answer this truck configuration question based on the data provided.

Question: {message}
Truck Model: {model_id}

{doc_context}

{bom_context}

Provide a concise, helpful answer. If the information is not available, say so."""
        
        ai_response = call_cortex_complete(prompt, "mistral-large2")
        if ai_response:
            return {"response": ai_response}
        
        return {"response": f"I don't have enough information to answer '{message}'. Try asking about specific options, or request an optimization like 'maximize safety'."}
    except Exception as e:
        print(f"General question error: {e}")
        return {"response": f"I encountered an error processing your question. Please try rephrasing."}

def generate_optimization_sql_with_ai(user_request: str, model_id: str) -> Dict[str, Any]:
    """Generate optimization SQL using Cortex Analyst via SQL (ANALYST_PREVIEW function)"""
    try:
        print(f"Generating optimization SQL with CORTEX ANALYST for: {user_request} (model: {model_id})")
        
        # Build the Cortex Analyst request with model_id prefix
        analyst_question = f"For {model_id}: {user_request}"
        
        # Escape for SQL string
        escaped_question = analyst_question.replace("'", "''").replace('"', '\\"')
        
        # Call Cortex Analyst via SQL function (works with SPCS session token!)
        analyst_sql = f"""
            SELECT SNOWFLAKE.CORTEX.ANALYST_PREVIEW(
                '{{"semantic_view": "{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_CONFIG_ANALYST_V2", "messages": [{{"role": "user", "content": [{{"type": "text", "text": "{escaped_question}"}}]}}]}}'
            ) as result
        """
        
        print(f"Calling CORTEX.ANALYST_PREVIEW...")
        analyst_result = query_single(analyst_sql)
        
        if analyst_result:
            # Parse the Cortex Analyst response
            parsed = json.loads(analyst_result) if isinstance(analyst_result, str) else analyst_result
            
            message = parsed.get('message', {})
            content = message.get('content', [])
            
            # Extract SQL and interpretation from response
            generated_sql = None
            interpretation = None
            verified_query_used = None
            
            for item in content:
                if item.get('type') == 'text':
                    interpretation = item.get('text', '')
                elif item.get('type') == 'sql':
                    generated_sql = item.get('statement', '')
                    # Check if a verified query was used (higher confidence)
                    confidence = item.get('confidence', {})
                    if confidence.get('verified_query_used'):
                        verified_query_used = confidence['verified_query_used'].get('name')
            
            if generated_sql:
                print(f"Cortex Analyst generated SQL (verified_query: {verified_query_used})")
                print(f"SQL: {generated_sql[:200]}...")
                
                # Execute the generated SQL
                try:
                    results = query(generated_sql)
                    print(f"Cortex Analyst SQL returned {len(results)} rows")
                    
                    summary = interpretation or f"Cortex Analyst optimized for: {user_request}"
                    if verified_query_used:
                        summary = f"[Verified Query: {verified_query_used}] {summary}"
                    
                    return {
                        "sql": generated_sql, 
                        "summary": summary, 
                        "error": None, 
                        "direct_results": results,
                        "verified_query": verified_query_used
                    }
                except Exception as exec_err:
                    print(f"Cortex Analyst SQL execution failed: {exec_err}")
                    return {"sql": generated_sql, "summary": interpretation, "error": str(exec_err), "direct_results": []}
            else:
                # Analyst returned text but no SQL (might be a question it can't answer)
                print(f"Cortex Analyst returned no SQL. Interpretation: {interpretation}")
                return {"sql": None, "summary": interpretation, "error": "No SQL generated", "direct_results": []}
        
        print("Cortex Analyst returned empty response")
        return {"sql": None, "summary": None, "error": "Empty Analyst response"}
    
    except Exception as e:
        print(f"Cortex Analyst call failed: {e}")
        import traceback
        traceback.print_exc()
        return {"sql": None, "summary": None, "error": str(e)}

# ============ VALIDATION ============

class ValidateRequest(BaseModel):
    selectedOptions: List[str]
    modelId: str
    incrementalOnly: Optional[List[str]] = None

@app.post("/api/validate")
def validate_config(req: ValidateRequest):
    """Validate configuration using Cortex Search for engineering docs + Cortex Complete for requirement extraction"""
    try:
        if not req.selectedOptions:
            return {"isValid": True, "issues": [], "fixPlan": None}
        
        print(f"\n=== VALIDATION API CALLED ===")
        print(f"Validating {len(req.selectedOptions)} options for model {req.modelId}")
        print(f"Selected option IDs: {', '.join(req.selectedOptions[:10])}...")
        
        option_list = ",".join([f"'{o}'" for o in req.selectedOptions])
        
        # Get selected options with their SPECS
        options_sql = f"""
            SELECT OPTION_ID, OPTION_NM, COMPONENT_GROUP, SYSTEM_NM, 
                   PERFORMANCE_CATEGORY, SPECS
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL
            WHERE OPTION_ID IN ({option_list})
        """
        selected_options = query(options_sql)
        
        options_by_group = {}
        selected_specs = {}
        for opt in selected_options:
            cg = opt['COMPONENT_GROUP']
            options_by_group[cg] = opt
            if opt.get('SPECS'):
                specs = opt['SPECS'] if isinstance(opt['SPECS'], dict) else json.loads(opt['SPECS']) if opt['SPECS'] else {}
                selected_specs[cg] = specs
        
        # Find engineering docs linked to selected parts
        print(f"Looking for docs linked to options: {', '.join(req.selectedOptions[:5])}...")
        
        linked_docs = query(f"""
            SELECT DISTINCT 
                d.DOC_ID, d.DOC_TITLE, d.CHUNK_TEXT,
                d.LINKED_PARTS::VARCHAR as LINKED_PARTS_JSON
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED d
            WHERE d.LINKED_PARTS IS NOT NULL 
              AND ARRAY_SIZE(d.LINKED_PARTS) > 0
        """)
        
        print(f"Found {len(linked_docs)} engineering docs in database")
        
        # Find which docs are linked to selected options
        docs_for_selected = []
        for doc in linked_docs:
            try:
                linked_parts = json.loads(doc['LINKED_PARTS_JSON']) if doc.get('LINKED_PARTS_JSON') else []
                print(f"  Doc \"{doc['DOC_TITLE']}\": parsed LINKED_PARTS = {json.dumps(linked_parts)}")
                for part in linked_parts:
                    if part.get('optionId') in req.selectedOptions:
                        docs_for_selected.append({
                            'docId': doc['DOC_ID'],
                            'docTitle': doc['DOC_TITLE'],
                            'linkedPart': part,
                            'chunkText': doc['CHUNK_TEXT']
                        })
                        break
            except Exception as parse_err:
                print(f"  Error parsing LINKED_PARTS for {doc['DOC_ID']}: {parse_err}")
        
        print(f"Found {len(docs_for_selected)} engineering docs linked to selected parts")
        
        issues = []
        
        if docs_for_selected:
            # Get all chunks for each linked doc for validation
            doc_ids = list(set([d['docId'] for d in docs_for_selected]))
            
            for doc_info in docs_for_selected:
                doc_id = doc_info['docId']
                doc_title = doc_info['docTitle']
                linked_part = doc_info['linkedPart']
                
                print(f"\n=== VALIDATING AGAINST: {doc_title} (linked to {linked_part.get('optionName', linked_part.get('optionId'))}) ===")
                
                # Get all chunks for this document
                escaped_doc_id = doc_id.replace("'", "''")
                all_chunks = query(f"""
                    SELECT CHUNK_TEXT FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
                    WHERE DOC_ID = '{escaped_doc_id}'
                    ORDER BY CHUNK_INDEX
                """)
                newline_char = '\n'
                full_doc_text = newline_char.join([c['CHUNK_TEXT'] for c in all_chunks])
                
                # Use Cortex Complete to extract requirements from the document
                doc_content = full_doc_text[:8000]
                extract_prompt = f"""Analyze this engineering specification document and extract the specific technical requirements.

Document: {doc_title}
Content:
{doc_content}

Extract requirements as JSON array. Each requirement should have:
- componentType: the component this applies to (e.g., "Turbocharger", "Radiator", "Transmission Type")
- specName: the specification name (e.g., "boost_psi", "cooling_capacity_btu")  
- minValue: minimum required value (number or null)
- maxValue: maximum allowed value (number or null)
- unit: the unit of measurement
- rawRequirement: the original requirement text

Return ONLY a JSON array, no other text. Example:
[
  {{"componentType": "Turbocharger", "specName": "boost_psi", "minValue": 45, "maxValue": null, "unit": "PSI", "rawRequirement": "minimum boost pressure of 45 PSI"}}
]"""

                escaped_prompt = extract_prompt.replace("'", "''").replace("\\", "\\\\")
                
                try:
                    ai_result = query_single(f"SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet', '{escaped_prompt}') as response")
                    
                    if ai_result:
                        # Parse the requirements JSON
                        ai_text = ai_result.strip()
                        if '[' in ai_text:
                            json_start = ai_text.index('[')
                            json_end = ai_text.rindex(']') + 1
                            requirements = json.loads(ai_text[json_start:json_end])
                            
                            print(f"Extracted {len(requirements)} requirements: {json.dumps(requirements, indent=2)}")
                            
                            # Validate each requirement against selected options
                            for req in requirements:
                                component_type = req.get('componentType', '')
                                spec_name = req.get('specName', '')
                                min_val = req.get('minValue')
                                max_val = req.get('maxValue')
                                unit = req.get('unit', '')
                                raw_req = req.get('rawRequirement', '')
                                
                                # Find the selected option for this component
                                selected_opt = options_by_group.get(component_type, {})
                                selected_spec = selected_specs.get(component_type, {})
                                
                                if selected_opt and selected_spec:
                                    actual_value = selected_spec.get(spec_name, 0)
                                    opt_name = selected_opt.get('OPTION_NM', 'Unknown')
                                    
                                    print(f"Checking {opt_name} against {len([r for r in requirements if r.get('componentType') == component_type])} requirements for {component_type}")
                                    
                                    # Check minimum requirement
                                    if min_val is not None and actual_value < min_val:
                                        print(f"  ✗ {spec_name}={actual_value} < {min_val} ✗")
                                        issues.append({
                                            "type": "requirement",
                                            "message": f"{opt_name}: {spec_name} is {actual_value} {unit} but spec requires minimum {min_val} {unit}",
                                            "severity": "error",
                                            "requirement": raw_req,
                                            "sourceDoc": doc_title,
                                            "fix": f"Upgrade {component_type} to meet {min_val}+ {unit} requirement"
                                        })
                                    elif min_val is not None:
                                        print(f"  ✓ {spec_name}={actual_value:,} >= {min_val:,} ✓")
                                    
                                    # Check maximum requirement
                                    if max_val is not None and actual_value > max_val:
                                        issues.append({
                                            "type": "requirement",
                                            "message": f"{opt_name}: {spec_name} is {actual_value} {unit} but spec allows maximum {max_val} {unit}",
                                            "severity": "warning",
                                            "requirement": raw_req,
                                            "sourceDoc": doc_title,
                                            "fix": f"Consider downgrading {component_type}"
                                        })
                            
                            # Find cheapest option that meets requirements
                            for requirement in requirements:
                                component_type = requirement.get('componentType', '')
                                min_val = requirement.get('minValue')
                                spec_name = requirement.get('specName', '')
                                
                                if min_val is None:
                                    continue
                                    
                                selected_spec = selected_specs.get(component_type, {})
                                actual_value = selected_spec.get(spec_name, 0)
                                
                                if actual_value < min_val:
                                    # Find cheapest option meeting this requirement
                                    req_count = len([r for r in requirements if r.get('componentType') == component_type])
                                    print(f"  Finding cheapest {component_type} meeting {req_count} requirements...")
                                    
                                    escaped_component = component_type.replace("'", "''")
                                    candidates_sql = f"""
                                        SELECT b.OPTION_ID, b.OPTION_NM, b.COST_USD, b.SPECS
                                        FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b
                                        JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t ON b.OPTION_ID = t.OPTION_ID
                                        WHERE t.MODEL_ID = '{req.modelId}'
                                          AND b.COMPONENT_GROUP = '{escaped_component}'
                                        ORDER BY b.COST_USD ASC
                                    """
                                    candidates = query(candidates_sql)
                                    print(f"  Evaluating {len(candidates)} candidates (sorted by cost)...")
                                    
                                    for candidate in candidates:
                                        cand_specs = candidate['SPECS'] if isinstance(candidate['SPECS'], dict) else json.loads(candidate['SPECS']) if candidate['SPECS'] else {}
                                        cand_value = cand_specs.get(spec_name, 0)
                                        if cand_value >= min_val:
                                            cand_cost = candidate['COST_USD']
                                            print(f"  CHEAPEST: {candidate['OPTION_NM']} (${cand_cost:,}) meets all requirements")
                                            # Update the fix suggestion
                                            for issue in issues:
                                                if component_type in issue.get('message', ''):
                                                    issue['fix'] = f"Upgrade to {candidate['OPTION_NM']} (${cand_cost:,})"
                                            break
                                    
                except Exception as ai_err:
                    print(f"AI requirement extraction failed: {ai_err}")
                    import traceback
                    traceback.print_exc()
        
        is_valid = len([i for i in issues if i.get("severity") == "error"]) == 0
        
        fix_plan = None
        if issues:
            fixes = list(set([i.get("fix") for i in issues if i.get("fix")]))
            fix_plan = {
                "recommendations": fixes,
                "summary": f"Found {len(issues)} issue(s) based on engineering specifications"
            }
        
        print(f"\nValidation complete: isValid={is_valid}, issues={len(issues)}")
        print(f"=== VALIDATION END ===\n")
        
        return {"isValid": is_valid, "issues": issues, "fixPlan": fix_plan}
        
    except Exception as e:
        print(f"Validation error: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

# ============ AI DESCRIPTION ============

class DescribeRequest(BaseModel):
    modelName: str
    modelId: Optional[str] = None
    selectedOptions: List[str]
    totalCost: float
    totalWeight: float
    performanceSummary: Dict[str, Any]
    optimizationHistory: Optional[List[str]] = None
    manualChanges: Optional[List[str]] = None
    costDelta: Optional[float] = None
    weightDelta: Optional[float] = None

@app.post("/api/describe")
def describe_config(req: DescribeRequest):
    """Generate AI description using Cortex Complete - context-aware of optimizations and manual changes"""
    try:
        print(f"=== DESCRIBE REQUEST ===")
        print(f"Model: {req.modelName}")
        print(f"Optimization History: {req.optimizationHistory}")
        print(f"Manual Changes: {req.manualChanges}")
        print(f"Cost Delta: {req.costDelta}, Weight Delta: {req.weightDelta}")
        
        model_desc = ""
        try:
            model_lookup = query(f"""
                SELECT MODEL_ID, TRUCK_DESCRIPTION 
                FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.MODEL_TBL 
                WHERE MODEL_NM ILIKE '%{req.modelName.replace("'", "''")}%' 
                LIMIT 1
            """)
            if model_lookup:
                model_desc = model_lookup[0].get("TRUCK_DESCRIPTION", "")
        except:
            pass
        
        opt_history = req.optimizationHistory or []
        manual_changes = req.manualChanges or []
        base_desc = model_desc[:150] if model_desc else ""
        
        last_opt = opt_history[-1] if opt_history else None
        
        cost_delta = req.costDelta or 0
        weight_delta = req.weightDelta or 0
        
        cost_summary = ""
        if cost_delta > 500:
            cost_summary = f"Added ${cost_delta:,.0f} in upgrades"
        elif cost_delta < -500:
            cost_summary = f"Saved ${abs(cost_delta):,.0f} from default"
        else:
            cost_summary = "Near-default cost"
            
        weight_summary = ""
        if weight_delta > 100:
            weight_summary = f"Added {weight_delta:,.0f} lbs"
        elif weight_delta < -100:
            weight_summary = f"Saved {abs(weight_delta):,.0f} lbs"
        
        prompt = f"""Write a 2-sentence marketing description for this custom truck configuration.

BASE MODEL: {req.modelName}
{f"Base description: {base_desc}" if base_desc else ""}

CONFIGURATION STRATEGY:
{f'- AI Optimizations applied: {", ".join(opt_history)}' if opt_history else '- No AI optimizations applied'}
{f'- Manual additions: {", ".join(manual_changes[-5:])}' if manual_changes else '- No manual changes'}

KEY METRICS:
- {cost_summary}
- {weight_summary if weight_summary else "Standard weight"}
- Total: ${req.totalCost:,.0f} | {req.totalWeight:,.0f} lbs

WRITING RULES:
1. First sentence: Brief model intro (1 phrase) + primary configuration strategy
2. Second sentence: Key benefit or value proposition
3. Use natural language - no bullet points or lists
4. If "maximize X while minimizing costs" was applied: emphasize budget-friendly approach
5. If "maximize X" alone: emphasize upgraded/enhanced X capability  
6. If "minimize weight" was applied: mention weight savings
7. If manual additions exist: briefly mention notable upgrades
8. Keep it concise and marketing-focused

Examples of good output:
- "This budget-optimized F-150 maximizes safety and economy while keeping other costs minimal. Perfect for practical buyers who prioritize protection without breaking the bank."
- "This performance-enhanced Silverado features upgraded power components with a manual V8 addition. Built for those who demand maximum capability on and off the road."
- "This lightweight Ram 1500 saves 450 lbs through strategic component selection. Ideal for improved fuel efficiency and responsive handling."

Write exactly 2 sentences."""

        print(f"Sending prompt to Cortex...")
        description = call_cortex_complete(prompt, "mistral-large2")
        print(f"Cortex response: {description[:200] if description else 'None'}...")
        
        if not description:
            if opt_history:
                description = f"This {req.modelName} has been optimized for {opt_history[-1]}. {cost_summary}."
            else:
                description = f"Custom {req.modelName} configuration. Total investment: ${req.totalCost:,.0f}."
        
        return {"description": description}
    except Exception as e:
        print(f"Describe error: {e}")
        return {"description": f"Custom {req.modelName} configuration."}

# ============ ENGINEERING DOCS ============

@app.get("/api/engineering-docs")
def get_engineering_docs():
    """Get list of indexed engineering documents"""
    try:
        docs = query(f"""
            SELECT 
                DOC_ID, DOC_TITLE, DOC_PATH,
                COUNT(*) as CHUNK_COUNT,
                MIN(CREATED_AT) as CREATED_AT,
                MAX(LINKED_PARTS)::VARCHAR as LINKED_PARTS
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
            GROUP BY DOC_ID, DOC_TITLE, DOC_PATH
            ORDER BY 5 DESC
        """)
        
        results = []
        for doc in docs:
            linked_parts = []
            if doc.get("LINKED_PARTS"):
                try:
                    linked_parts = json.loads(doc["LINKED_PARTS"])
                except:
                    pass
            
            results.append({
                "docId": doc["DOC_ID"],
                "docTitle": doc["DOC_TITLE"],
                "docPath": doc["DOC_PATH"],
                "chunkCount": doc["CHUNK_COUNT"],
                "linkedParts": linked_parts,
                "createdAt": str(doc["CREATED_AT"])
            })
        
        return {"docs": results}
    except Exception as e:
        print(f"Error fetching docs: {e}")
        return {"docs": [], "error": str(e)}

class DeleteDocRequest(BaseModel):
    docId: str

@app.get("/api/engineering-docs/view")
def view_engineering_doc(docId: str):
    """Get presigned URL for viewing a document"""
    try:
        doc_info = query(f"""
            SELECT DISTINCT DOC_PATH
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
            WHERE DOC_ID = '{docId.replace("'", "''")}'
            LIMIT 1
        """)
        
        if not doc_info:
            raise HTTPException(status_code=404, detail="Document not found")
        
        doc_path = doc_info[0]["DOC_PATH"]
        filename = doc_path.split("/")[-1] if doc_path else ""
        
        if not filename:
            raise HTTPException(status_code=404, detail="Document path invalid")
        
        # Generate presigned URL for the file
        presigned_result = query(f"""
            SELECT GET_PRESIGNED_URL(
                @{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_STAGE,
                '{filename.replace("'", "''")}',
                3600
            ) as url
        """)
        
        if presigned_result and presigned_result[0].get("URL"):
            return {"url": presigned_result[0]["URL"]}
        
        raise HTTPException(status_code=500, detail="Could not generate presigned URL")
    except HTTPException:
        raise
    except Exception as e:
        print(f"View doc error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/engineering-docs/upload")
async def upload_engineering_doc(
    file: UploadFile = File(...),
    linkedParts: str = Form(default="[]")
):
    """Upload, extract, chunk and index an engineering document with SSE progress"""
    import uuid
    import base64
    
    # CRITICAL: Read file content BEFORE creating the generator
    # The file handle will be closed after the request handler returns
    content = await file.read()
    filename = file.filename or "Untitled"
    
    def generate_progress():
        try:
            # Parse linked parts
            try:
                parts_list = json.loads(linkedParts)
            except:
                parts_list = []
            
            # Generate doc ID
            doc_id = f"DOC-{uuid.uuid4().hex[:8]}"
            doc_title = filename
            staged_filename = doc_title.replace("'", "").replace(" ", "_")
            
            # Step 1: Upload to stage
            yield f"data: {json.dumps({'step': 'upload', 'status': 'active', 'message': 'Uploading to stage...'})}\n\n"
            
            is_text = filename and (filename.endswith('.txt') or filename.endswith('.md'))
            
            if is_text:
                try:
                    full_text = content.decode('utf-8')
                except:
                    full_text = content.decode('latin-1')
                yield f"data: {json.dumps({'step': 'upload', 'status': 'done'})}\n\n"
            else:
                content_base64 = base64.b64encode(content).decode('utf-8')
                print(f"Uploading {staged_filename} via stored procedure ({len(content)} bytes)")
                
                try:
                    upload_result = query(f"""
                        CALL {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.UPLOAD_AND_PARSE_DOCUMENT(
                            '{content_base64}',
                            '{staged_filename}'
                        )
                    """)
                    
                    if upload_result and len(upload_result) > 0:
                        result_data = upload_result[0].get("UPLOAD_AND_PARSE_DOCUMENT", {})
                        if isinstance(result_data, str):
                            result_data = json.loads(result_data)
                        
                        if result_data.get("error"):
                            yield f"data: {json.dumps({'step': 'upload', 'status': 'error', 'message': result_data['error']})}\n\n"
                            yield f"data: {json.dumps({'type': 'result', 'success': False, 'error': result_data['error']})}\n\n"
                            return
                        
                        full_text = result_data.get("parsed_text", "")
                        if not full_text:
                            yield f"data: {json.dumps({'step': 'upload', 'status': 'error', 'message': 'No text extracted'})}\n\n"
                            yield f"data: {json.dumps({'type': 'result', 'success': False, 'error': 'Failed to extract text'})}\n\n"
                            return
                    else:
                        yield f"data: {json.dumps({'step': 'upload', 'status': 'error', 'message': 'No result'})}\n\n"
                        yield f"data: {json.dumps({'type': 'result', 'success': False, 'error': 'Upload returned no result'})}\n\n"
                        return
                        
                except Exception as e:
                    print(f"Stored procedure upload failed: {e}")
                    yield f"data: {json.dumps({'step': 'upload', 'status': 'error', 'message': str(e)})}\n\n"
                    yield f"data: {json.dumps({'type': 'result', 'success': False, 'error': str(e)})}\n\n"
                    return
            
            yield f"data: {json.dumps({'step': 'upload', 'status': 'done'})}\n\n"
            
            # Step 2: Extract text (already done via stored procedure, but show progress)
            yield f"data: {json.dumps({'step': 'extract', 'status': 'active', 'message': 'Processing document...'})}\n\n"
            yield f"data: {json.dumps({'step': 'extract', 'status': 'done', 'message': f'{len(full_text)} chars'})}\n\n"
            
            # Step 3: Chunk the text
            yield f"data: {json.dumps({'step': 'chunk', 'status': 'active', 'message': 'Creating chunks...'})}\n\n"
            
            chunks = []
            chunk_size = 1500
            overlap = 200
            
            if len(full_text) <= chunk_size:
                chunks = [full_text]
            else:
                start = 0
                while start < len(full_text):
                    end = min(start + chunk_size, len(full_text))
                    chunk = full_text[start:end]
                    chunks.append(chunk)
                    start = end - overlap
                    if start + overlap >= len(full_text):
                        break
            
            # Insert chunks into table
            linked_parts_json = json.dumps(parts_list).replace("'", "''")
            stage_path = f"@{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_STAGE/{staged_filename}"
            
            for i, chunk in enumerate(chunks):
                chunk_escaped = chunk.replace("'", "''").replace("\\", "\\\\")
                query(f"""
                    INSERT INTO {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
                    (DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_TEXT, LINKED_PARTS)
                    SELECT '{doc_id}', '{doc_title.replace("'", "''")}', '{stage_path}', 
                           {i}, '{chunk_escaped}', PARSE_JSON('{linked_parts_json}')
                """)
            
            yield f"data: {json.dumps({'step': 'chunk', 'status': 'done', 'message': f'{len(chunks)} chunks'})}\n\n"
            
            # Step 4: Refresh search service
            yield f"data: {json.dumps({'step': 'search', 'status': 'active', 'message': 'Indexing...'})}\n\n"
            try:
                query(f"ALTER CORTEX SEARCH SERVICE {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_SEARCH REFRESH")
                yield f"data: {json.dumps({'step': 'search', 'status': 'done'})}\n\n"
            except Exception as refresh_err:
                print(f"Search refresh warning: {refresh_err}")
                yield f"data: {json.dumps({'step': 'search', 'status': 'done', 'message': 'Auto-refresh scheduled'})}\n\n"
            
            # Step 5: Extract validation rules using Cortex Complete
            yield f"data: {json.dumps({'step': 'rules', 'status': 'active', 'message': 'Extracting validation rules...'})}\n\n"
            
            rules_created = 0
            try:
                # Get linked option ID if available
                linked_option_id = parts_list[0].get('optionId') if parts_list else None
                
                # Use first few chunks (most likely to have specs) for rule extraction
                combined_text = '\n\n'.join(chunks[:5])[:6000]
                
                prompt = f"""Extract component requirements from this engineering specification.

DOCUMENT: {doc_title}

CONTENT:
{combined_text}

Extract numeric requirements for supporting components. Valid component groups and their spec names:
- Turbocharger: boost_psi, max_hp_supported
- Radiator: cooling_capacity_btu, core_rows
- Transmission Type: torque_rating_lb_ft
- Engine Brake Type: braking_hp, brake_stages
- Frame Rails: yield_strength_psi, rbm_rating_in_lb
- Axle Rating: gawr_lb, beam_thickness_in
- Front Suspension Type: spring_rating_lb
- Rear Suspension Type: spring_rating_lb

For each requirement, return JSON with the EXACT componentGroup name from above.

Return JSON array:
[
  {{"componentGroup": "Turbocharger", "specName": "boost_psi", "minValue": 45, "unit": "PSI", "rawRequirement": "minimum 45 PSI boost"}},
  {{"componentGroup": "Frame Rails", "specName": "yield_strength_psi", "minValue": 80000, "unit": "PSI", "rawRequirement": "80,000 PSI yield strength"}}
]

Return [] if no numeric requirements found. Return ONLY the JSON array.""".replace("'", "''")
                
                ai_result = query(f"""
                    SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', '{prompt}') AS RESPONSE
                """)
                
                if ai_result and len(ai_result) > 0:
                    response = ai_result[0].get("RESPONSE", "").strip()
                    # Strip markdown code blocks
                    response = response.replace("```json", "").replace("```", "")
                    
                    import re
                    json_match = re.search(r'\[[\s\S]*\]', response)
                    if json_match:
                        rules = json.loads(json_match.group(0))
                        
                        for rule in rules:
                            component_group = rule.get('componentGroup', '').replace("'", "''")
                            spec_name = rule.get('specName', '').replace("'", "''")
                            min_value = rule.get('minValue')
                            max_value = rule.get('maxValue')
                            unit = rule.get('unit', '').replace("'", "''")
                            raw_req = rule.get('rawRequirement', '').replace("'", "''")
                            
                            query(f"""
                                INSERT INTO {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.VALIDATION_RULES
                                (DOC_ID, DOC_TITLE, LINKED_OPTION_ID, COMPONENT_GROUP, SPEC_NAME, MIN_VALUE, MAX_VALUE, UNIT, RAW_REQUIREMENT)
                                VALUES (
                                    '{doc_id}',
                                    '{doc_title.replace("'", "''")}',
                                    {f"'{linked_option_id}'" if linked_option_id else 'NULL'},
                                    '{component_group}',
                                    '{spec_name}',
                                    {min_value if min_value is not None else 'NULL'},
                                    {max_value if max_value is not None else 'NULL'},
                                    '{unit}',
                                    '{raw_req}'
                                )
                            """)
                            rules_created += 1
                        
                        print(f"Created {rules_created} validation rules for {doc_title}")
                
            except Exception as rule_err:
                print(f"Rule extraction error: {rule_err}")
            
            yield f"data: {json.dumps({'step': 'rules', 'status': 'done', 'message': f'{rules_created} rules created'})}\n\n"
            
            # Final result
            yield f"data: {json.dumps({'type': 'result', 'success': True, 'docId': doc_id, 'docTitle': doc_title, 'chunkCount': len(chunks), 'linkedParts': parts_list, 'rulesCreated': rules_created})}\n\n"
            
        except Exception as e:
            print(f"Upload error: {e}")
            yield f"data: {json.dumps({'type': 'result', 'success': False, 'error': str(e)})}\n\n"
    
    return StreamingResponse(
        generate_progress(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        }
    )

# ============ CHAT HISTORY ============

_chat_history: Dict[str, Dict] = {}

@app.get("/api/chat-history")
def get_chat_history(sessionId: str):
    """Get chat history for a session"""
    if sessionId in _chat_history:
        return _chat_history[sessionId]
    return {"messages": [], "optimizationRequests": [], "configId": None}

class ChatHistoryPatchRequest(BaseModel):
    sessionId: str
    configId: Optional[str] = None
    message: Optional[Dict] = None
    optimizationRequest: Optional[str] = None

@app.patch("/api/chat-history")
def patch_chat_history(req: ChatHistoryPatchRequest):
    """Update chat history for a session"""
    if req.sessionId not in _chat_history:
        _chat_history[req.sessionId] = {"messages": [], "optimizationRequests": [], "configId": None}
    
    if req.configId:
        _chat_history[req.sessionId]["configId"] = req.configId
    if req.message:
        _chat_history[req.sessionId]["messages"].append(req.message)
    if req.optimizationRequest:
        _chat_history[req.sessionId]["optimizationRequests"].append(req.optimizationRequest)
    
    return {"success": True}

@app.delete("/api/engineering-docs")
async def delete_engineering_doc(req: DeleteDocRequest):
    """Delete an engineering document and refresh search index"""
    try:
        doc_id = req.docId.replace("'", "''")
        
        # Get doc info
        doc_info = query(f"""
            SELECT DISTINCT DOC_PATH, DOC_TITLE
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
            WHERE DOC_ID = '{doc_id}'
            LIMIT 1
        """)
        
        if not doc_info:
            raise HTTPException(status_code=404, detail="Document not found")
        
        doc_title = doc_info[0]["DOC_TITLE"]
        doc_path = doc_info[0]["DOC_PATH"]
        
        # Delete chunks
        query(f"""
            DELETE FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED
            WHERE DOC_ID = '{doc_id}'
        """)
        
        # Remove from stage
        try:
            filename = doc_path.split("/")[-1]
            if filename:
                query(f"REMOVE @{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_STAGE/{filename}")
        except:
            pass
        
        # Refresh search service
        try:
            query(f"ALTER CORTEX SEARCH SERVICE {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_SEARCH REFRESH")
        except:
            pass
        
        return {"success": True, "deletedDocId": req.docId, "docTitle": doc_title}
    except HTTPException:
        raise
    except Exception as e:
        print(f"Delete error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ============ REPORT ============

@app.get("/api/report")
def get_report(modelId: str, options: Optional[str] = None, configId: Optional[str] = None):
    """Generate detailed BOM report"""
    try:
        # Get model info
        model_result = query(f"""
            SELECT MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.MODEL_TBL
            WHERE MODEL_ID = '{modelId}'
        """)
        
        if not model_result:
            raise HTTPException(status_code=404, detail="Model not found")
        
        model = model_result[0]
        
        # Get all options for this model
        all_options = query(f"""
            SELECT b.OPTION_ID, b.OPTION_NM, b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP,
                   b.DESCRIPTION, b.COST_USD, b.WEIGHT_LBS, b.PERFORMANCE_CATEGORY, 
                   b.PERFORMANCE_SCORE, t.IS_DEFAULT
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.TRUCK_OPTIONS t
            JOIN {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.BOM_TBL b ON t.OPTION_ID = b.OPTION_ID
            WHERE t.MODEL_ID = '{modelId}'
            ORDER BY b.SYSTEM_NM, b.SUBSYSTEM_NM, b.COMPONENT_GROUP, b.COST_USD
        """)
        
        # Parse selected options
        selected_option_ids = []
        if options:
            try:
                selected_option_ids = json.loads(options)
            except:
                selected_option_ids = options.split(",")
        
        default_option_ids = [o["OPTION_ID"] for o in all_options if o.get("IS_DEFAULT")]
        
        # Build BOM hierarchy
        bom_hierarchy = build_bom_hierarchy(all_options, selected_option_ids, default_option_ids)
        
        return {
            "model": model,
            "bomHierarchy": bom_hierarchy,
            "selectedOptionIds": selected_option_ids,
            "defaultOptionIds": default_option_ids,
            "allOptions": all_options
        }
    except HTTPException:
        raise
    except Exception as e:
        print(f"Report error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

def build_bom_hierarchy(all_options: List[Dict], selected_ids: List[str], default_ids: List[str]) -> List[Dict]:
    """Build hierarchical BOM structure"""
    systems = {}
    
    # Determine which option is active per component group
    cg_selections = {}
    cg_defaults = {}
    
    for opt in all_options:
        cg_key = f"{opt['SYSTEM_NM']}|{opt['SUBSYSTEM_NM']}|{opt['COMPONENT_GROUP']}"
        
        if opt.get("IS_DEFAULT"):
            cg_defaults[cg_key] = opt
        
        if opt["OPTION_ID"] in selected_ids:
            cg_selections[cg_key] = opt["OPTION_ID"]
        elif cg_key not in cg_selections and opt.get("IS_DEFAULT"):
            cg_selections[cg_key] = opt["OPTION_ID"]
    
    for opt in all_options:
        cg_key = f"{opt['SYSTEM_NM']}|{opt['SUBSYSTEM_NM']}|{opt['COMPONENT_GROUP']}"
        active_id = cg_selections.get(cg_key)
        is_active = opt["OPTION_ID"] == active_id
        is_default = opt["OPTION_ID"] in default_ids
        is_selected = opt["OPTION_ID"] in selected_ids
        
        if is_active:
            if is_default:
                status = "default"
            elif is_selected:
                default_opt = cg_defaults.get(cg_key)
                if default_opt and opt["COST_USD"] > default_opt["COST_USD"]:
                    status = "upgraded"
                else:
                    status = "downgraded"
            else:
                status = "default"
        else:
            status = "base"
        
        bom_item = {
            "optionId": opt["OPTION_ID"],
            "optionName": opt["OPTION_NM"],
            "description": opt.get("DESCRIPTION", ""),
            "cost": opt["COST_USD"],
            "weight": opt["WEIGHT_LBS"],
            "performanceCategory": opt["PERFORMANCE_CATEGORY"],
            "performanceScore": opt["PERFORMANCE_SCORE"],
            "status": status,
            "isSelected": is_active
        }
        
        sys_name = opt["SYSTEM_NM"]
        sub_name = opt["SUBSYSTEM_NM"]
        cg_name = opt["COMPONENT_GROUP"]
        
        if sys_name not in systems:
            systems[sys_name] = {"name": sys_name, "subsystems": [], "totalCost": 0, "totalWeight": 0}
        
        sys_obj = systems[sys_name]
        sub_obj = next((s for s in sys_obj["subsystems"] if s["name"] == sub_name), None)
        if not sub_obj:
            sub_obj = {"name": sub_name, "componentGroups": [], "totalCost": 0, "totalWeight": 0}
            sys_obj["subsystems"].append(sub_obj)
        
        cg_obj = next((c for c in sub_obj["componentGroups"] if c["name"] == cg_name), None)
        if not cg_obj:
            cg_obj = {"name": cg_name, "items": [], "selectedItem": None, "totalCost": 0, "totalWeight": 0}
            sub_obj["componentGroups"].append(cg_obj)
        
        cg_obj["items"].append(bom_item)
        if is_active:
            cg_obj["selectedItem"] = bom_item
            cg_obj["totalCost"] = bom_item["cost"]
            cg_obj["totalWeight"] = bom_item["weight"]
    
    # Calculate totals
    for sys_obj in systems.values():
        for sub_obj in sys_obj["subsystems"]:
            sub_obj["totalCost"] = sum(cg["totalCost"] for cg in sub_obj["componentGroups"])
            sub_obj["totalWeight"] = sum(cg["totalWeight"] for cg in sub_obj["componentGroups"])
        sys_obj["totalCost"] = sum(s["totalCost"] for s in sys_obj["subsystems"])
        sys_obj["totalWeight"] = sum(s["totalWeight"] for s in sys_obj["subsystems"])
    
    return sorted(systems.values(), key=lambda x: x["name"])

@app.get("/api/engineering-docs/download")
async def download_engineering_doc(docId: str):
    """Download an engineering document from the stage using presigned URL"""
    from fastapi.responses import RedirectResponse
    try:
        docs = query(f"""
            SELECT DISTINCT DOC_PATH, DOC_TITLE 
            FROM {SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_CHUNKED 
            WHERE DOC_ID = '{docId.replace("'", "''")}'
            LIMIT 1
        """)
        
        if not docs:
            raise HTTPException(status_code=404, detail="Document not found")
        
        doc_path = docs[0]["DOC_PATH"]
        filename = doc_path.split('/')[-1] if '/' in doc_path else doc_path
        
        presigned_url = query_single(f"""
            SELECT GET_PRESIGNED_URL(
                @{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}.ENGINEERING_DOCS_STAGE, 
                '{filename}', 
                3600
            )
        """)
        
        if presigned_url:
            return RedirectResponse(url=presigned_url, status_code=302)
        else:
            raise HTTPException(status_code=500, detail="Failed to generate download URL")
            
    except HTTPException:
        raise
    except Exception as e:
        print(f"Download error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
