#!/bin/bash
# Digital Twin Truck Configurator - Automated Setup Script
# Deploys the demo to any AWS Snowflake account
#
# IMPORTANT NOTES (learned from production deployments):
# 1. SPCS OAuth tokens only work for SQL connections, NOT REST APIs
# 2. PAT is required for Cortex Analyst REST API calls
# 3. Key-pair auth is required for PUT commands (file uploads)
# 4. networkPolicyConfig.allowInternetEgress is NOT enough - need EXTERNAL_ACCESS_INTEGRATIONS
# 5. Secrets YAML must use snowflakeSecret.objectName + secretKeyRef syntax

set -e

echo "=================================================="
echo "  Digital Twin Truck Configurator Setup"
echo "=================================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CONNECTION_NAME=""
SNOWFLAKE_ACCOUNT=""
SNOWFLAKE_USER=""
SNOWFLAKE_WAREHOUSE=""
DATABASE=""
SCHEMA=""
COMPUTE_POOL=""
REPO_URL=""

# Helper function to run snow sql with correct connection
snow_sql() {
    if [[ -n "$CONNECTION_NAME" ]]; then
        snow sql --connection "$CONNECTION_NAME" "$@"
    else
        snow sql "$@"
    fi
}

# Check prerequisites
check_prereqs() {
    echo "Checking prerequisites..."
    
    if ! command -v snow &> /dev/null; then
        echo -e "${RED}Error: 'snow' CLI not found. Install with: pip install snowflake-cli${NC}"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: 'docker' not found. Please install Docker Desktop.${NC}"
        exit 1
    fi
    
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}Error: 'openssl' not found. Required for key-pair generation.${NC}"
        exit 1
    fi
    
    # Check Docker is running
    if ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker is not running. Please start Docker Desktop.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ All prerequisites satisfied${NC}"
    echo ""
}

# Setup or select connection
setup_connection() {
    echo "Snowflake Connection Setup"
    echo "--------------------------"
    echo ""
    
    # List existing connections
    echo "Existing connections:"
    snow connection list 2>/dev/null || echo "  (none found)"
    echo ""
    
    read -p "Use existing connection? Enter name (or press Enter to create new): " EXISTING_CONN
    
    if [[ -n "$EXISTING_CONN" ]]; then
        CONNECTION_NAME="$EXISTING_CONN"
        echo -e "${GREEN}Using existing connection: $CONNECTION_NAME${NC}"
        
        # Try to extract account info from connection test
        read -p "Snowflake Account (e.g., MYORG-MYACCOUNT): " SNOWFLAKE_ACCOUNT
        read -p "Snowflake Username: " SNOWFLAKE_USER
    else
        read -p "Snowflake Account (e.g., MYORG-MYACCOUNT): " SNOWFLAKE_ACCOUNT
        read -p "Snowflake Username: " SNOWFLAKE_USER
        
        CONN_NAME=$(echo "$SNOWFLAKE_ACCOUNT" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        
        if snow connection list 2>/dev/null | grep -q "$CONN_NAME"; then
            echo -e "${GREEN}Found existing connection: $CONN_NAME${NC}"
            CONNECTION_NAME="$CONN_NAME"
        else
            echo ""
            echo "Authentication method:"
            echo "  1) Browser-based SSO (externalbrowser) - Recommended"
            echo "  2) Personal Access Token (PAT)"
            read -p "Choose [1/2]: " AUTH_CHOICE
            
            echo ""
            echo -e "${YELLOW}Creating new connection: $CONN_NAME${NC}"
            
            if [[ "$AUTH_CHOICE" == "2" ]]; then
                read -p "Enter your PAT: " -s CONNECTION_PAT
                echo ""
                TOKEN_FILE="$HOME/.snowflake/${CONN_NAME}_token"
                mkdir -p "$HOME/.snowflake"
                echo "$CONNECTION_PAT" > "$TOKEN_FILE"
                chmod 600 "$TOKEN_FILE"
                snow connection add \
                    --no-interactive \
                    --connection-name "$CONN_NAME" \
                    --account "$SNOWFLAKE_ACCOUNT" \
                    --user "$SNOWFLAKE_USER" \
                    --authenticator PROGRAMMATIC_ACCESS_TOKEN \
                    --token-file-path "$TOKEN_FILE"
            else
                snow connection add \
                    --no-interactive \
                    --connection-name "$CONN_NAME" \
                    --account "$SNOWFLAKE_ACCOUNT" \
                    --user "$SNOWFLAKE_USER" \
                    --authenticator externalbrowser
            fi
            CONNECTION_NAME="$CONN_NAME"
            echo -e "${GREEN}✓ Connection created${NC}"
        fi
    fi
    
    # Test connection
    echo ""
    echo "Testing connection..."
    if snow connection test --connection "$CONNECTION_NAME"; then
        echo -e "${GREEN}✓ Connection successful${NC}"
    else
        echo -e "${RED}Connection failed. Please check your credentials.${NC}"
        exit 1
    fi
    
    # Check cloud platform
    echo ""
    echo "Checking cloud platform..."
    CLOUD_PLATFORM=$(snow_sql -q "SELECT SPLIT_PART(CURRENT_REGION(), '_', 1);" --format csv 2>/dev/null | tail -1 | tr -d '[:space:]')
    echo "Cloud Platform: $CLOUD_PLATFORM"
    
    if [[ "$CLOUD_PLATFORM" != "AWS" ]]; then
        echo ""
        echo -e "${RED}=================================================="
        echo "  WARNING: Non-AWS Platform Detected ($CLOUD_PLATFORM)"
        echo "==================================================${NC}"
        echo ""
        echo "This demo requires an AWS Snowflake account."
        echo ""
        echo "On Azure/GCP, the Cortex Analyst REST API requires OAuth authentication"
        echo "which is blocked for PAT tokens (error 395090). The Configuration Assistant"
        echo "feature will NOT work."
        echo ""
        read -p "Continue anyway? (y/n): " CONTINUE_ANYWAY
        if [[ "$CONTINUE_ANYWAY" != "y" && "$CONTINUE_ANYWAY" != "Y" ]]; then
            echo "Setup cancelled."
            exit 0
        fi
    else
        echo -e "${GREEN}✓ AWS platform - full Cortex Analyst support available${NC}"
    fi
    echo ""
}

# Gather configuration
gather_config() {
    echo "Deployment Configuration"
    echo "------------------------"
    echo "(Press Enter to accept defaults)"
    echo ""
    
    read -p "Snowflake Warehouse [COMPUTE_WH]: " SNOWFLAKE_WAREHOUSE
    SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE:-COMPUTE_WH}
    
    read -p "Database name [BOM]: " DATABASE
    DATABASE=${DATABASE:-BOM}
    
    read -p "Schema name [TRUCK_CONFIG]: " SCHEMA
    SCHEMA=${SCHEMA:-TRUCK_CONFIG}
    
    read -p "Compute Pool name [TRUCK_CONFIG_POOL]: " COMPUTE_POOL
    COMPUTE_POOL=${COMPUTE_POOL:-TRUCK_CONFIG_POOL}
    
    echo ""
    echo -e "${BLUE}Configuration Summary:${NC}"
    echo "  Connection:   $CONNECTION_NAME"
    echo "  Account:      $SNOWFLAKE_ACCOUNT"
    echo "  User:         $SNOWFLAKE_USER"
    echo "  Warehouse:    $SNOWFLAKE_WAREHOUSE"
    echo "  Database:     $DATABASE"
    echo "  Schema:       $SCHEMA"
    echo "  Compute Pool: $COMPUTE_POOL"
    echo ""
    
    read -p "Continue with this configuration? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Setup cancelled."
        exit 0
    fi
}

# Create database, schema, and infrastructure
setup_infrastructure() {
    echo ""
    echo -e "${YELLOW}Step 1/8: Creating infrastructure...${NC}"
    
    snow_sql -q "CREATE DATABASE IF NOT EXISTS $DATABASE;"
    snow_sql -q "CREATE SCHEMA IF NOT EXISTS $DATABASE.$SCHEMA;"
    
    # Create compute pool
    echo "Creating compute pool..."
    snow_sql -q "CREATE COMPUTE POOL IF NOT EXISTS $COMPUTE_POOL
        MIN_NODES = 1
        MAX_NODES = 1
        INSTANCE_FAMILY = CPU_X64_XS
        AUTO_RESUME = TRUE
        AUTO_SUSPEND_SECS = 3600;" 2>/dev/null || echo "  (compute pool may already exist)"
    
    # Create image repository
    echo "Creating image repository..."
    snow_sql -q "CREATE IMAGE REPOSITORY IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIG_REPO;"
    
    # Get repository URL
    REPO_URL=$(snow_sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json 2>/dev/null | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    echo -e "${GREEN}  Image Repository: $REPO_URL${NC}"
    
    # Create network rule for external access (CRITICAL for REST APIs)
    echo "Creating external access integration..."
    echo -e "${BLUE}  Note: networkPolicyConfig.allowInternetEgress alone is NOT sufficient"
    echo "        EXTERNAL_ACCESS_INTEGRATIONS is required for Cortex Analyst REST API${NC}"
    
    snow_sql -q "CREATE OR REPLACE NETWORK RULE $DATABASE.$SCHEMA.CORTEX_API_RULE
        TYPE = HOST_PORT
        MODE = EGRESS
        VALUE_LIST = ('*.snowflakecomputing.com:443');"
    
    snow_sql -q "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
        ALLOWED_NETWORK_RULES = ($DATABASE.$SCHEMA.CORTEX_API_RULE)
        ENABLED = TRUE;"
    
    echo -e "${GREEN}✓ Infrastructure created${NC}"
}

# Load data
load_data() {
    echo ""
    echo -e "${YELLOW}Step 2/8: Loading data...${NC}"
    
    # Create backup and update scripts with user's database/schema
    for script in scripts/02_data.sql scripts/02b_bom_data.sql scripts/02c_truck_options.sql scripts/03_semantic_view.sql scripts/04_additional_objects.sql; do
        if [[ -f "$script" ]]; then
            cp "$script" "${script}.bak" 2>/dev/null || true
            sed -i.tmp "s/BOM\.BOM4/$DATABASE.$SCHEMA/g" "$script"
            sed -i.tmp "s/BOM\.TRUCK_CONFIG/$DATABASE.$SCHEMA/g" "$script"
            rm -f "${script}.tmp"
        fi
    done
    
    snow_sql -f scripts/02_data.sql
    echo "  ✓ Tables and models loaded"
    
    snow_sql -f scripts/02b_bom_data.sql
    echo "  ✓ BOM data loaded (253 parts with specifications)"
    
    snow_sql -f scripts/02c_truck_options.sql
    echo "  ✓ Truck options loaded (868 mappings)"
    
    echo -e "${GREEN}✓ Data loaded${NC}"
}

# Create semantic view
create_semantic_view() {
    echo ""
    echo -e "${YELLOW}Step 3/8: Creating semantic view...${NC}"
    
    snow_sql -f scripts/03_semantic_view.sql
    
    echo -e "${GREEN}✓ Semantic view TRUCK_CONFIG_ANALYST_V2 created${NC}"
}

# Create additional objects (stages, Cortex Search)
create_additional_objects() {
    echo ""
    echo -e "${YELLOW}Step 4/8: Creating stages and Cortex Search...${NC}"
    
    # Update warehouse in script
    sed -i.tmp "s/WAREHOUSE = DEMO_WH/WAREHOUSE = $SNOWFLAKE_WAREHOUSE/g" scripts/04_additional_objects.sql
    sed -i.tmp "s/WAREHOUSE = COMPUTE_WH/WAREHOUSE = $SNOWFLAKE_WAREHOUSE/g" scripts/04_additional_objects.sql
    rm -f scripts/04_additional_objects.sql.tmp
    
    snow_sql -f scripts/04_additional_objects.sql
    
    echo -e "${BLUE}  Note: Stage uses SNOWFLAKE_SSE encryption (required for PARSE_DOCUMENT)${NC}"
    echo -e "${GREEN}✓ Additional objects created${NC}"
}

# Setup authentication secrets
setup_secrets() {
    echo ""
    echo -e "${YELLOW}Step 5/8: Setting up authentication secrets...${NC}"
    echo ""
    
    # ========================================
    # PAT Secret (for Cortex Analyst REST API)
    # ========================================
    echo -e "${BLUE}PAT Secret Setup${NC}"
    echo "The app needs a Personal Access Token (PAT) to call Cortex Analyst REST API."
    echo "SPCS OAuth tokens only work for SQL connections, NOT for REST API calls."
    echo ""
    echo "Create a PAT at: Snowsight → Profile → Security → Personal Access Tokens"
    echo ""
    read -p "Enter your PAT (or press Enter to skip): " -s PAT_TOKEN
    echo ""
    
    if [[ -n "$PAT_TOKEN" ]]; then
        snow_sql -q "CREATE OR REPLACE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET
            TYPE = GENERIC_STRING
            SECRET_STRING = '$PAT_TOKEN';"
        echo -e "${GREEN}  ✓ PAT secret created${NC}"
    else
        echo -e "${YELLOW}  ⚠ Skipped - Configuration Assistant will not work without PAT${NC}"
        echo "  Create manually later:"
        echo "  CREATE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET TYPE=GENERIC_STRING SECRET_STRING='<PAT>';"
    fi
    
    # ========================================
    # Key-Pair Secret (for PUT commands/uploads)
    # ========================================
    echo ""
    echo -e "${BLUE}Key-Pair Authentication Setup${NC}"
    echo "Required for file uploads (PUT commands) in SPCS."
    echo "PAT authentication does NOT support PUT commands to stages."
    echo ""
    
    read -p "Generate key-pair automatically? (y/n) [y]: " GEN_KEYPAIR
    GEN_KEYPAIR=${GEN_KEYPAIR:-y}
    
    if [[ "$GEN_KEYPAIR" == "y" || "$GEN_KEYPAIR" == "Y" ]]; then
        TEMP_KEY_DIR=$(mktemp -d)
        
        echo "  Generating RSA key pair..."
        openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -inform PEM -out "$TEMP_KEY_DIR/key.p8" -nocrypt 2>/dev/null
        openssl rsa -in "$TEMP_KEY_DIR/key.p8" -pubout -out "$TEMP_KEY_DIR/key.pub" 2>/dev/null
        
        # Get public key without headers for user assignment
        PUBLIC_KEY=$(grep -v "BEGIN\|END" "$TEMP_KEY_DIR/key.pub" | tr -d '\n')
        
        # Assign to user
        echo "  Assigning public key to user $SNOWFLAKE_USER..."
        snow_sql -q "ALTER USER $SNOWFLAKE_USER SET RSA_PUBLIC_KEY='$PUBLIC_KEY';"
        
        # Store private key with escaped newlines (CRITICAL for SPCS secrets)
        echo "  Creating private key secret..."
        PRIVATE_KEY_ESCAPED=$(awk '{printf "%s\\n", $0}' "$TEMP_KEY_DIR/key.p8")
        snow_sql -q "CREATE OR REPLACE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PRIVATE_KEY_SECRET
            TYPE = GENERIC_STRING
            SECRET_STRING = '$PRIVATE_KEY_ESCAPED';"
        
        rm -rf "$TEMP_KEY_DIR"
        echo -e "${GREEN}  ✓ Key-pair authentication configured${NC}"
    else
        echo -e "${YELLOW}  ⚠ Skipped - File uploads will not work${NC}"
        echo "  To configure manually:"
        echo "  1. Generate key: openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out key.p8"
        echo "  2. Get public: openssl rsa -in key.p8 -pubout"
        echo "  3. ALTER USER $SNOWFLAKE_USER SET RSA_PUBLIC_KEY='<public_key>';"
        echo "  4. CREATE SECRET ... SECRET_STRING='<private_key_with_escaped_newlines>';"
    fi
}

# Build and push Docker image
build_docker() {
    echo ""
    echo -e "${YELLOW}Step 6/8: Building Docker image...${NC}"
    
    # Login to registry
    echo "  Logging into Snowflake image registry..."
    snow spcs image-registry login --connection "$CONNECTION_NAME"
    
    # Get fresh repo URL
    REPO_URL=$(snow_sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json 2>/dev/null | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    echo "  Building image (this takes 2-3 minutes)..."
    cd docker
    docker buildx build --platform linux/amd64 -t truck-config:v1 . 2>&1 | tail -5
    
    echo "  Tagging for Snowflake registry..."
    docker tag truck-config:v1 "$REPO_URL/truck-config:v1"
    
    echo "  Pushing to registry..."
    docker push "$REPO_URL/truck-config:v1" 2>&1 | tail -3
    
    cd ..
    echo -e "${GREEN}✓ Docker image pushed${NC}"
}

# Deploy SPCS service
deploy_service() {
    echo ""
    echo -e "${YELLOW}Step 7/8: Deploying SPCS service...${NC}"
    
    # Get repo URL
    REPO_URL=$(snow_sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json 2>/dev/null | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    # Derive host from account
    SNOWFLAKE_HOST="${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com"
    
    echo -e "${BLUE}  Note: Using correct secrets YAML syntax (snowflakeSecret.objectName + secretKeyRef)${NC}"
    
    snow_sql -q "CREATE SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC
      IN COMPUTE POOL $COMPUTE_POOL
      FROM SPECIFICATION \$\$
spec:
  containers:
    - name: truck-configurator
      image: $REPO_URL/truck-config:v1
      env:
        SNOWFLAKE_ACCOUNT: $SNOWFLAKE_ACCOUNT
        SNOWFLAKE_HOST: $SNOWFLAKE_HOST
        SNOWFLAKE_USER: $SNOWFLAKE_USER
        SNOWFLAKE_WAREHOUSE: $SNOWFLAKE_WAREHOUSE
        SNOWFLAKE_DATABASE: $DATABASE
        SNOWFLAKE_SCHEMA: $SCHEMA
        SNOWFLAKE_SEMANTIC_VIEW: $DATABASE.$SCHEMA.TRUCK_CONFIG_ANALYST_V2
      secrets:
        - snowflakeSecret:
            objectName: $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET
          secretKeyRef: secret_string
          envVarName: SNOWFLAKE_PAT
        - snowflakeSecret:
            objectName: $DATABASE.$SCHEMA.SNOWFLAKE_PRIVATE_KEY_SECRET
          secretKeyRef: secret_string
          envVarName: SNOWFLAKE_PRIVATE_KEY
      resources:
        requests:
          cpu: 0.5
          memory: 1Gi
        limits:
          cpu: 2
          memory: 4Gi
  endpoints:
    - name: app
      port: 3000
      public: true
  networkPolicyConfig:
    allowInternetEgress: true
\$\$
EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS)
MIN_INSTANCES = 1
MAX_INSTANCES = 1;"
    
    echo ""
    echo "  Waiting for service to start (60-90 seconds)..."
    sleep 45
    
    # Check status
    STATUS=$(snow_sql -q "SELECT SYSTEM\$GET_SERVICE_STATUS('$DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC');" --format csv 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [[ "$STATUS" == "READY" ]]; then
        echo -e "${GREEN}✓ Service is running!${NC}"
    else
        echo -e "${YELLOW}  Service status: $STATUS (may still be starting)${NC}"
    fi
}

# Get service URL and finish
finish_setup() {
    echo ""
    echo -e "${YELLOW}Step 8/8: Getting service URL...${NC}"
    
    sleep 10
    
    # Get endpoint URL
    ENDPOINT_URL=$(snow_sql -q "SHOW ENDPOINTS IN SERVICE $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC;" --format json 2>/dev/null | grep -o '"ingress_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    echo ""
    echo -e "${GREEN}=================================================="
    echo "  Setup Complete!"
    echo "==================================================${NC}"
    echo ""
    if [[ -n "$ENDPOINT_URL" ]]; then
        echo -e "  ${GREEN}Application URL: $ENDPOINT_URL${NC}"
    fi
    echo ""
    echo "  Useful Commands:"
    echo "  ----------------"
    echo "  Check status:"
    echo "    snow sql --connection $CONNECTION_NAME -q \"SELECT SYSTEM\\\$GET_SERVICE_STATUS('$DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC');\""
    echo ""
    echo "  View logs:"
    echo "    snow sql --connection $CONNECTION_NAME -q \"CALL SYSTEM\\\$GET_SERVICE_LOGS('$DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);\""
    echo ""
    echo "  Get URL:"
    echo "    snow sql --connection $CONNECTION_NAME -q \"SHOW ENDPOINTS IN SERVICE $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC;\""
    echo ""
    echo -e "${BLUE}  Demo Tip: Upload demo_assets/605_HP_Engine_Requirements.pdf to test validation!${NC}"
    echo ""
}

# Main
main() {
    check_prereqs
    setup_connection
    gather_config
    setup_infrastructure
    load_data
    create_semantic_view
    create_additional_objects
    setup_secrets
    
    echo ""
    read -p "Build and deploy Docker image? (y/n) [y]: " BUILD_DOCKER
    BUILD_DOCKER=${BUILD_DOCKER:-y}
    
    if [[ "$BUILD_DOCKER" == "y" || "$BUILD_DOCKER" == "Y" ]]; then
        build_docker
        deploy_service
        finish_setup
    else
        echo ""
        echo "To complete setup manually:"
        echo "1. cd docker && docker buildx build --platform linux/amd64 -t truck-config:v1 ."
        echo "2. docker tag truck-config:v1 $REPO_URL/truck-config:v1"
        echo "3. docker push $REPO_URL/truck-config:v1"
        echo "4. snow sql --connection $CONNECTION_NAME -f scripts/05_service.sql"
    fi
}

main
