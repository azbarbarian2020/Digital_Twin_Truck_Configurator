#!/bin/bash
set -e

echo "========================================="
echo "  Truck Configurator Demo - Setup Script"
echo "========================================="
echo ""

# Configuration - MODIFY THESE FOR YOUR TARGET ACCOUNT
DATABASE="BOM"
SCHEMA="TRUCK_CONFIG"
WAREHOUSE="DEMO_WH"
COMPUTE_POOL="TRUCK_CONFIG_POOL"
IMAGE_REPO="TRUCK_CONFIG_REPO"
SERVICE_NAME="TRUCK_CONFIGURATOR_SVC"

# Connection setup
setup_connection() {
    echo "Available connections:"
    snow connection list 2>/dev/null || echo "  (none found)"
    echo ""
    
    read -p "Enter connection name to use: " CONNECTION_NAME
    
    if [[ -z "$CONNECTION_NAME" ]]; then
        echo "ERROR: Connection name required"
        exit 1
    fi
    
    # Test connection
    echo "Testing connection..."
    snow sql -q "SELECT CURRENT_ACCOUNT(), CURRENT_USER()" --connection "$CONNECTION_NAME" || {
        echo "ERROR: Connection failed"
        exit 1
    }
    
    # Get account identifier for network rule
    ACCOUNT_INFO=$(snow sql -q "SELECT CURRENT_ACCOUNT()" --connection "$CONNECTION_NAME" --format json 2>/dev/null | grep -o '"CURRENT_ACCOUNT()":"[^"]*"' | cut -d'"' -f4)
    echo "Account: $ACCOUNT_INFO"
    
    export CONNECTION_NAME
    export ACCOUNT_INFO
}

run_sql() {
    snow sql -q "$1" --connection "$CONNECTION_NAME"
}

# Step 1: Setup connection
echo "STEP 1: Connection Setup"
echo "------------------------"
setup_connection
echo ""

# Step 2: Create database and schema
echo "STEP 2: Create Database/Schema"
echo "------------------------------"
run_sql "CREATE DATABASE IF NOT EXISTS $DATABASE"
run_sql "CREATE SCHEMA IF NOT EXISTS $DATABASE.$SCHEMA"
run_sql "USE SCHEMA $DATABASE.$SCHEMA"
echo ""

# Step 3: Create tables
echo "STEP 3: Create Tables"
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
    CONFIG_ID VARCHAR(50) NOT NULL,
    CONFIG_NAME VARCHAR(200) NOT NULL,
    MODEL_ID VARCHAR(50) NOT NULL,
    CREATED_BY VARCHAR(100),
    CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    TOTAL_COST_USD NUMBER(12,2),
    TOTAL_WEIGHT_LBS NUMBER(12,2),
    PERFORMANCE_SUMMARY VARIANT,
    CONFIG_OPTIONS VARIANT,
    NOTES VARCHAR(2000),
    IS_BASELINE BOOLEAN DEFAULT FALSE,
    IS_VALIDATED BOOLEAN DEFAULT FALSE,
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

# Step 4: Create stages
echo "STEP 4: Create Stages"
echo "--------------------"
run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.ENGINEERING_DOCS_STAGE DIRECTORY = (ENABLE = TRUE)"
run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.SEMANTIC_MODELS COMMENT = 'Stage for semantic model YAML files'"
echo ""

# Step 5: Create image repository
echo "STEP 5: Create Image Repository"
echo "-------------------------------"
run_sql "CREATE IMAGE REPOSITORY IF NOT EXISTS $DATABASE.$SCHEMA.$IMAGE_REPO"
echo ""

# Step 6: Create compute pool
echo "STEP 6: Create Compute Pool"
echo "--------------------------"
run_sql "CREATE COMPUTE POOL IF NOT EXISTS $COMPUTE_POOL
    MIN_NODES = 1
    MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300
    COMMENT = 'Compute pool for Truck Configurator'"
echo ""

# Step 7: Create network rule and external access integration
echo "STEP 7: Create Network Rule & External Access"
echo "---------------------------------------------"

# Determine the account hostname for network rule
# Format: orgname-accountname.snowflakecomputing.com
ACCOUNT_HOST=$(snow sql -q "SELECT CONCAT(LOWER(CURRENT_ORGANIZATION_NAME()), '-', LOWER(CURRENT_ACCOUNT_NAME()), '.snowflakecomputing.com')" --connection "$CONNECTION_NAME" --format json 2>/dev/null | grep -o '"CONCAT[^"]*":"[^"]*"' | cut -d'"' -f4 || echo "")

if [[ -z "$ACCOUNT_HOST" ]]; then
    # Fallback: ask user
    read -p "Enter your Snowflake hostname (e.g., sfsenorthamerica-jdrew.snowflakecomputing.com): " ACCOUNT_HOST
fi

echo "Using hostname for network rule: $ACCOUNT_HOST"

run_sql "CREATE OR REPLACE NETWORK RULE $DATABASE.$SCHEMA.SNOWFLAKE_API_RULE
    TYPE = HOST_PORT
    MODE = EGRESS
    VALUE_LIST = ('$ACCOUNT_HOST:443')"

run_sql "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${SCHEMA}_EXTERNAL_ACCESS
    ALLOWED_NETWORK_RULES = ($DATABASE.$SCHEMA.SNOWFLAKE_API_RULE)
    ENABLED = TRUE
    COMMENT = 'Allow truck configurator to access Snowflake Cortex APIs'"
echo ""

# Step 8: Create secret for private key
echo "STEP 8: Create Secret"
echo "--------------------"
echo "You need to provide the base64-encoded private key content."
echo "This is used for key-pair authentication from the SPCS container."
echo ""

if [[ -f "$HOME/.snowflake/keys/rsa_key.p8" ]]; then
    echo "Found key at ~/.snowflake/keys/rsa_key.p8"
    read -p "Use this key? (y/n): " USE_KEY
    if [[ "$USE_KEY" == "y" ]]; then
        # Extract just the base64 content (no headers)
        PRIVATE_KEY_CONTENT=$(grep -v "^-----" "$HOME/.snowflake/keys/rsa_key.p8" | tr -d '\n')
    fi
fi

if [[ -z "$PRIVATE_KEY_CONTENT" ]]; then
    echo "Enter the base64 private key content (without BEGIN/END headers):"
    read -s PRIVATE_KEY_CONTENT
fi

run_sql "CREATE OR REPLACE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PRIVATE_KEY_SECRET
    TYPE = GENERIC_STRING
    SECRET_STRING = '$PRIVATE_KEY_CONTENT'"
echo "Secret created."
echo ""

# Step 9: Build and push Docker image
echo "STEP 9: Build and Push Docker Image"
echo "-----------------------------------"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Build image for linux/amd64
echo "Building Docker image..."
docker build --platform linux/amd64 -t truck-configurator:latest .

# Tag and push
IMAGE_TAG="v1-setup"
docker tag truck-configurator:latest "$REPO_URL/truck-configurator:$IMAGE_TAG"
echo "Pushing image..."
docker push "$REPO_URL/truck-configurator:$IMAGE_TAG"
echo "Image pushed: $REPO_URL/truck-configurator:$IMAGE_TAG"
echo ""

# Step 10: Get account details for service spec
echo "STEP 10: Create Service"
echo "----------------------"

# Get current user
CURRENT_USER=$(snow sql -q "SELECT CURRENT_USER()" --connection "$CONNECTION_NAME" --format json 2>/dev/null | grep -o '"CURRENT_USER()":"[^"]*"' | cut -d'"' -f4)

# Get account name (org-account format)
ACCOUNT_NAME=$(snow sql -q "SELECT CURRENT_ACCOUNT()" --connection "$CONNECTION_NAME" --format json 2>/dev/null | grep -o '"CURRENT_ACCOUNT()":"[^"]*"' | cut -d'"' -f4)

echo "User: $CURRENT_USER"
echo "Account: $ACCOUNT_NAME"
echo "Host: $ACCOUNT_HOST"

# Create service
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
echo "Waiting for service to start..."
sleep 30

# Check status
snow spcs service status $SERVICE_NAME \
    --database "$DATABASE" \
    --schema "$SCHEMA" \
    --connection "$CONNECTION_NAME"

echo ""

# Get endpoint
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
echo "Next steps:"
echo "1. Load data into tables (MODEL_TBL, BOM_TBL, TRUCK_OPTIONS, etc.)"
echo "2. Upload engineering docs to ENGINEERING_DOCS_STAGE"
echo "3. Create Cortex Search Service for document search"
echo "4. Access the app at the endpoint URL above"
echo ""
