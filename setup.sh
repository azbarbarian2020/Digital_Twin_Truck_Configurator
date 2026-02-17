#!/bin/bash
set -e

echo "========================================="
echo "  Truck Configurator Demo - Setup Script"
echo "========================================="
echo ""

# Configuration
DATABASE="BOM"
SCHEMA="TRUCK_CONFIG"
WAREHOUSE="DEMO_WH"
COMPUTE_POOL="TRUCK_CONFIG_POOL"
IMAGE_REPO="TRUCK_CONFIG_REPO"
SERVICE_NAME="TRUCK_CONFIGURATOR_SVC"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ STEP 1: Connection Setup ============
echo "STEP 1: Connection Setup"
echo "------------------------"
echo ""

# Use provided connection name or prompt
if [[ -n "$1" ]]; then
    CONNECTION_NAME="$1"
    echo "Using connection: $CONNECTION_NAME"
else
    echo "Available Snowflake CLI connections:"
    echo ""
    # Parse connections from config file (snow connection list can be buggy)
    if [[ -f "$HOME/.snowflake/config.toml" ]]; then
        grep -E "^\[connections\." "$HOME/.snowflake/config.toml" 2>/dev/null | sed 's/\[connections\.//; s/\]//' | while read conn; do
            echo "  - $conn"
        done
    else
        echo "  (no config file found at ~/.snowflake/config.toml)"
    fi
    echo ""
    read -p "Enter connection name to use: " CONNECTION_NAME
fi

if [[ -z "$CONNECTION_NAME" ]]; then
    echo "ERROR: Connection name required"
    exit 1
fi

# Test connection
echo ""
echo "Testing connection..."
snow sql -q "SELECT CURRENT_ACCOUNT(), CURRENT_USER()" --connection "$CONNECTION_NAME" || {
    echo "ERROR: Connection failed"
    exit 1
}

run_sql() {
    snow sql -q "$1" --connection "$CONNECTION_NAME"
}

# Get account hostname for network rule (auto-detect)
ACCOUNT_HOST=$(snow sql -q "SELECT CONCAT(LOWER(CURRENT_ORGANIZATION_NAME()), '-', LOWER(CURRENT_ACCOUNT_NAME()), '.snowflakecomputing.com') AS HOST" --connection "$CONNECTION_NAME" 2>/dev/null | grep -v "SELECT" | grep "snowflakecomputing.com" | tr -d '| ' | head -1)

if [[ -z "$ACCOUNT_HOST" || ! "$ACCOUNT_HOST" == *"snowflakecomputing.com"* ]]; then
    echo "Could not auto-detect account hostname."
    read -p "Enter your Snowflake hostname (e.g., sfsenorthamerica-jdrew.snowflakecomputing.com): " ACCOUNT_HOST
fi

CURRENT_USER=$(snow sql -q "SELECT CURRENT_USER() AS CUR_USER" --connection "$CONNECTION_NAME" 2>/dev/null | grep -E "^\| [A-Z]" | tail -1 | sed 's/|//g' | tr -d ' ')
# Derive org-account format from ACCOUNT_HOST (e.g., sfsenorthamerica-jdrew.snowflakecomputing.com -> SFSENORTHAMERICA-JDREW)
ACCOUNT_NAME=$(echo "$ACCOUNT_HOST" | sed 's/.snowflakecomputing.com//' | tr '[:lower:]' '[:upper:]')

echo ""
echo "Account: $ACCOUNT_NAME"
echo "User: $CURRENT_USER"
echo "Host: $ACCOUNT_HOST"
echo ""

# ============ STEP 2: Private Key Setup ============
echo "STEP 2: Private Key Setup"
echo "-------------------------"

# Generate a NEW key pair specifically for this deployment
KEY_DIR="$HOME/.snowflake/keys"
mkdir -p "$KEY_DIR"
PRIVATE_KEY_FILE="$KEY_DIR/truck_config_key.p8"
PUBLIC_KEY_FILE="$KEY_DIR/truck_config_key.pub"

echo "Generating new RSA key pair for this deployment..."
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out "$PRIVATE_KEY_FILE" -nocrypt 2>/dev/null
openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE" 2>/dev/null

# Extract public key content (single line, no headers)
PUBLIC_KEY_CONTENT=$(grep -v "^-----" "$PUBLIC_KEY_FILE" | tr -d '\n')

echo "Key pair generated."
echo "Registering public key with user $CURRENT_USER..."

# Register the public key with the current user
run_sql "ALTER USER $CURRENT_USER SET RSA_PUBLIC_KEY='$PUBLIC_KEY_CONTENT'"
echo "Public key registered with $CURRENT_USER"

# Extract base64 content (strip headers and newlines)
PRIVATE_KEY_CONTENT=$(grep -v "^-----" "$PRIVATE_KEY_FILE" | tr -d '\n')
echo "Private key loaded (${#PRIVATE_KEY_CONTENT} chars)"
echo ""

# ============ STEP 3: Create Database/Schema ============
echo "STEP 3: Create Database/Schema"
echo "------------------------------"
run_sql "CREATE DATABASE IF NOT EXISTS $DATABASE"
run_sql "CREATE SCHEMA IF NOT EXISTS $DATABASE.$SCHEMA"
run_sql "CREATE WAREHOUSE IF NOT EXISTS $WAREHOUSE WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE"
echo ""

# ============ STEP 4: Create Tables ============
echo "STEP 4: Create Tables"
echo "--------------------"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.MODEL_TBL (
    MODEL_ID VARCHAR(50) NOT NULL,
    MODEL_NM VARCHAR(100) NOT NULL,
    TRUCK_DESCRIPTION VARCHAR(2000),
    BASE_MSRP NUMBER(12,2) NOT NULL,
    BASE_WEIGHT_LBS NUMBER(10,2) NOT NULL,
    MAX_PAYLOAD_LBS NUMBER(38,0),
    MAX_TOWING_LBS NUMBER(38,0),
    SLEEPER_AVAILABLE BOOLEAN DEFAULT FALSE,
    MODEL_TIER VARCHAR(20),
    PRIMARY KEY (MODEL_ID)
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.BOM_TBL (
    OPTION_ID VARCHAR(50) NOT NULL,
    SYSTEM_NM VARCHAR(100) NOT NULL,
    SUBSYSTEM_NM VARCHAR(100) NOT NULL,
    COMPONENT_GROUP VARCHAR(100) NOT NULL,
    OPTION_NM VARCHAR(150) NOT NULL,
    COST_USD NUMBER(12,2) NOT NULL,
    WEIGHT_LBS NUMBER(10,2) NOT NULL,
    SOURCE_COUNTRY VARCHAR(50) NOT NULL,
    PERFORMANCE_CATEGORY VARCHAR(50) NOT NULL,
    PERFORMANCE_SCORE NUMBER(3,1) NOT NULL,
    DESCRIPTION VARCHAR(500),
    OPTION_TIER VARCHAR(20),
    SPECS VARIANT,
    PRIMARY KEY (OPTION_ID)
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.TRUCK_OPTIONS (
    MODEL_ID VARCHAR(50) NOT NULL,
    OPTION_ID VARCHAR(50) NOT NULL,
    IS_DEFAULT BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (MODEL_ID, OPTION_ID)
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.SAVED_CONFIGS (
    CONFIG_ID VARCHAR(100) NOT NULL,
    MODEL_ID VARCHAR(20) NOT NULL,
    CONFIG_NAME VARCHAR(200),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    TOTAL_COST NUMBER(12,2) DEFAULT 0,
    TOTAL_WEIGHT NUMBER(12,2) DEFAULT 0,
    SELECTIONS VARIANT NOT NULL,
    NOTES VARCHAR(4000),
    PRIMARY KEY (CONFIG_ID)
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.CHAT_HISTORY (
    CHAT_ID VARCHAR(50) NOT NULL DEFAULT UUID_STRING(),
    SESSION_ID VARCHAR(50) NOT NULL,
    MODEL_ID VARCHAR(50) NOT NULL,
    CONFIG_ID VARCHAR(50),
    MESSAGE_ROLE VARCHAR(20) NOT NULL,
    MESSAGE_CONTENT VARCHAR(16777216) NOT NULL,
    OPTIMIZATION_APPLIED BOOLEAN DEFAULT FALSE,
    CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (CHAT_ID)
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.ENGINEERING_DOCS_CHUNKED (
    CHUNK_ID VARCHAR(50) DEFAULT UUID_STRING(),
    DOC_ID VARCHAR(100),
    DOC_TITLE VARCHAR(500),
    DOC_PATH VARCHAR(500),
    CHUNK_INDEX NUMBER(38,0),
    CHUNK_TEXT VARCHAR(16777216),
    CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    LINKED_PARTS VARIANT,
    CACHED_REQUIREMENTS VARIANT
)"

run_sql "CREATE OR REPLACE TABLE $DATABASE.$SCHEMA.VALIDATION_RULES (
    RULE_ID VARCHAR(50) NOT NULL DEFAULT UUID_STRING(),
    DOC_ID VARCHAR(100) NOT NULL,
    DOC_TITLE VARCHAR(500),
    LINKED_OPTION_ID VARCHAR(50),
    COMPONENT_GROUP VARCHAR(100) NOT NULL,
    SPEC_NAME VARCHAR(100) NOT NULL,
    MIN_VALUE NUMBER(38,2),
    MAX_VALUE NUMBER(38,2),
    UNIT VARCHAR(50),
    RAW_REQUIREMENT VARCHAR(2000),
    CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (RULE_ID)
)"

echo "Tables created."
echo ""

# ============ STEP 5: Create Stages ============
echo "STEP 5: Create Stages"
echo "--------------------"
run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.ENGINEERING_DOCS_STAGE ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE)"
run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.SEMANTIC_MODELS ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') COMMENT = 'Stage for semantic model YAML files'"
echo ""

# ============ STEP 5b: Create Stored Procedures ============
echo "STEP 5b: Create Stored Procedures"
echo "---------------------------------"

run_sql "CREATE OR REPLACE PROCEDURE $DATABASE.$SCHEMA.UPLOAD_AND_PARSE_DOCUMENT(FILE_CONTENT_BASE64 VARCHAR, FILE_NAME VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS \$\$
import base64
import tempfile
import os
import json

def main(session, file_content_base64: str, file_name: str):
    result = {
        \"success\": False, 
        \"file_name\": file_name, 
        \"stage_path\": None, 
        \"parsed_text\": None,
        \"chunks_inserted\": 0,
        \"error\": None
    }
    
    try:
        # Decode and write to temp file
        file_bytes = base64.b64decode(file_content_base64)
        suffix = '.' + file_name.split('.')[-1] if '.' in file_name else ''
        temp_dir = tempfile.gettempdir()
        temp_path = os.path.join(temp_dir, file_name)
        
        with open(temp_path, 'wb') as f:
            f.write(file_bytes)
        
        # Upload to stage
        stage_path = \"@$DATABASE.$SCHEMA.ENGINEERING_DOCS_STAGE\"
        put_result = session.file.put(
            temp_path, 
            stage_path, 
            auto_compress=False, 
            overwrite=True
        )
        
        result[\"stage_path\"] = f\"{stage_path}/{file_name}\"
        
        # Parse document if supported type
        if suffix.lower() in ['.pdf', '.docx', '.doc', '.pptx', '.ppt']:
            # Parse the document
            parse_sql = f\"\"\"
                SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
                    '@$DATABASE.$SCHEMA.ENGINEERING_DOCS_STAGE',
                    '{file_name}',
                    {{'mode': 'LAYOUT'}}
                ):content::VARCHAR as content
            \"\"\"
            parse_result = session.sql(parse_sql).collect()
            if parse_result and parse_result[0]['CONTENT']:
                content = parse_result[0]['CONTENT']
                result[\"parsed_text\"] = content
                
                # NOTE: Chunk insertion is handled by the Python backend
                # This stored procedure only uploads and parses
                result[\"chunks_inserted\"] = 0
        else:
            result[\"parsed_text\"] = file_bytes.decode('utf-8', errors='ignore')
        
        result[\"success\"] = True
        
    except Exception as e:
        result[\"error\"] = str(e)
    finally:
        if 'temp_path' in dir() and os.path.exists(temp_path):
            os.unlink(temp_path)
    
    return result
\$\$"

echo "Stored procedures created."
echo ""

# ============ STEP 6: Load Data ============
echo "STEP 6: Load Data"
echo "----------------"
if [[ -f "$SCRIPT_DIR/deployment/scripts/03_load_data.sql" ]]; then
    echo "Loading demo data (BOM_TBL, MODEL_TBL, TRUCK_OPTIONS)..."
    # Process SQL file - replace placeholders with actual values
    sed "s/\${DATABASE}/$DATABASE/g; s/\${SCHEMA}/$SCHEMA/g; s/\${WAREHOUSE}/$WAREHOUSE/g" \
        "$SCRIPT_DIR/deployment/scripts/03_load_data.sql" > /tmp/load_data_processed.sql
    snow sql -f /tmp/load_data_processed.sql --connection "$CONNECTION_NAME"
    echo "Data loaded."
else
    echo "WARNING: 03_load_data.sql not found, skipping data load"
fi
echo ""

# ============ STEP 7: Create Cortex Search Service ============
echo "STEP 7: Create Cortex Search Service"
echo "------------------------------------"
run_sql "CREATE CORTEX SEARCH SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.ENGINEERING_DOCS_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX
    WAREHOUSE = $WAREHOUSE
    TARGET_LAG = '1 minute'
    AS (
        SELECT CHUNK_ID, DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_TEXT
        FROM $DATABASE.$SCHEMA.ENGINEERING_DOCS_CHUNKED
    )"
echo ""

# ============ STEP 8: Create Semantic View ============
echo "STEP 8: Create Semantic View for Cortex Analyst"
echo "-----------------------------------------------"

# Process YAML - replace placeholders
sed "s/\${DATABASE}/$DATABASE/g; s/\${SCHEMA}/$SCHEMA/g" "$SCRIPT_DIR/deployment/data/truck_config_analyst.yaml" > /tmp/truck_config_analyst_processed.yaml

# Upload to stage (for reference/backup)
snow stage copy /tmp/truck_config_analyst_processed.yaml "@$DATABASE.$SCHEMA.SEMANTIC_MODELS/" --connection "$CONNECTION_NAME" --overwrite 2>/dev/null || true

# Create semantic view using stored procedure with YAML content
YAML_CONTENT=$(cat /tmp/truck_config_analyst_processed.yaml)
snow sql -q "CALL SYSTEM\$CREATE_SEMANTIC_VIEW_FROM_YAML('$DATABASE.$SCHEMA', \$\$${YAML_CONTENT}\$\$)" --connection "$CONNECTION_NAME"
echo "Semantic view created."
echo ""

# ============ STEP 9: Create Infrastructure ============
echo "STEP 9: Create SPCS Infrastructure"
echo "----------------------------------"

# Image repository
run_sql "CREATE IMAGE REPOSITORY IF NOT EXISTS $DATABASE.$SCHEMA.$IMAGE_REPO"

# Compute pool
run_sql "CREATE COMPUTE POOL IF NOT EXISTS $COMPUTE_POOL
    MIN_NODES = 1
    MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300"

# Network rule (CRITICAL: must use target account hostname)
echo "Creating network rule for: $ACCOUNT_HOST"
run_sql "CREATE OR REPLACE NETWORK RULE $DATABASE.$SCHEMA.SNOWFLAKE_API_RULE
    TYPE = HOST_PORT
    MODE = EGRESS
    VALUE_LIST = ('$ACCOUNT_HOST:443')"

# External access integration
run_sql "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${SCHEMA}_EXTERNAL_ACCESS
    ALLOWED_NETWORK_RULES = ($DATABASE.$SCHEMA.SNOWFLAKE_API_RULE)
    ENABLED = TRUE"

# Secret for private key
run_sql "CREATE OR REPLACE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PRIVATE_KEY_SECRET
    TYPE = GENERIC_STRING
    SECRET_STRING = '$PRIVATE_KEY_CONTENT'"
echo "Secret created."
echo ""

# ============ STEP 10: Build and Push Docker Image ============
echo "STEP 10: Build and Push Docker Image"
echo "------------------------------------"

cd "$SCRIPT_DIR"

# Login to registry
echo "Logging into image registry..."
snow spcs image-registry login --connection "$CONNECTION_NAME"

# Get repository URL
REPO_URL=$(snow spcs image-repository url $IMAGE_REPO \
    --database "$DATABASE" \
    --schema "$SCHEMA" \
    --connection "$CONNECTION_NAME" | tr -d '[:space:]')

echo "Repository URL: $REPO_URL"

# Build image
echo "Building Docker image (this may take a few minutes)..."
docker build --platform linux/amd64 -t truck-configurator:latest .

# Tag and push
IMAGE_TAG="v1-$(date +%Y%m%d-%H%M%S)"
docker tag truck-configurator:latest "$REPO_URL/truck-configurator:$IMAGE_TAG"
echo "Pushing image..."
docker push "$REPO_URL/truck-configurator:$IMAGE_TAG"
echo "Image pushed: $REPO_URL/truck-configurator:$IMAGE_TAG"
echo ""

# ============ STEP 11: Deploy Service ============
echo "STEP 11: Deploy SPCS Service"
echo "----------------------------"

run_sql "CREATE SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.$SERVICE_NAME
    IN COMPUTE POOL $COMPUTE_POOL
    EXTERNAL_ACCESS_INTEGRATIONS = (${SCHEMA}_EXTERNAL_ACCESS)
    FROM SPECIFICATION \$\$
spec:
  containers:
  - name: truck-configurator
    image: $REPO_URL/truck-configurator:$IMAGE_TAG
    env:
      SNOWFLAKE_ACCOUNT: $ACCOUNT_NAME
      SNOWFLAKE_HOST: $ACCOUNT_HOST
      SNOWFLAKE_USER: $CURRENT_USER
      SNOWFLAKE_DATABASE: $DATABASE
      SNOWFLAKE_SCHEMA: $SCHEMA
      SNOWFLAKE_WAREHOUSE: $WAREHOUSE
      NODE_ENV: production
    secrets:
    - snowflakeSecret: $DATABASE.$SCHEMA.SNOWFLAKE_PRIVATE_KEY_SECRET
      secretKeyRef: secret_string
      envVarName: SNOWFLAKE_PRIVATE_KEY
    resources:
      requests:
        memory: 2G
        cpu: 1
      limits:
        memory: 4G
        cpu: 2
  endpoints:
  - name: app
    port: 8080
    public: true
  networkPolicyConfig:
    allowInternetEgress: true
\$\$"

echo ""
echo "Waiting for service to start (this may take 1-2 minutes)..."
sleep 45

# Check status
echo ""
echo "Service Status:"
snow spcs service status $SERVICE_NAME \
    --database "$DATABASE" \
    --schema "$SCHEMA" \
    --connection "$CONNECTION_NAME"

echo ""
echo "Service Endpoint:"
snow spcs service list-endpoints $SERVICE_NAME \
    --database "$DATABASE" \
    --schema "$SCHEMA" \
    --connection "$CONNECTION_NAME"

echo ""
echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo ""
echo "Open the endpoint URL above in your browser."
echo ""
