#!/bin/bash
# =============================================================================
# Digital Twin Truck Configurator - Automated Deployment Script
# =============================================================================
# This script deploys the complete demo to a Snowflake account.
# It handles:
#   - Connection setup (existing or new)
#   - Infrastructure creation (compute pool, image repo, stages)
#   - Table creation and data loading
#   - Cortex Search service setup
#   - Docker image build and push
#   - SPCS service deployment
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Digital Twin Truck Configurator${NC}"
echo -e "${BLUE}  Deployment Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================
DEFAULT_DATABASE="BOM"
DEFAULT_SCHEMA="TRUCK_CONFIG"
DEFAULT_WAREHOUSE="DEMO_WH"
DEFAULT_POOL_NAME="TRUCK_CONFIG_POOL"

# =============================================================================
# STEP 1: CONNECTION SETUP
# =============================================================================
setup_connection() {
    echo -e "${YELLOW}Step 1: Connection Setup${NC}"
    echo "----------------------------------------"
    echo "Existing Snowflake connections:"
    snow connection list 2>/dev/null || echo "  (none found)"
    echo ""
    
    read -p "Use existing connection? Enter name (or press Enter to create new): " EXISTING_CONN
    
    if [[ -n "$EXISTING_CONN" ]]; then
        CONNECTION_NAME="$EXISTING_CONN"
        echo -e "${GREEN}Using existing connection: $CONNECTION_NAME${NC}"
    else
        echo ""
        echo "Creating new connection..."
        read -p "Connection name: " CONN_NAME
        read -p "Snowflake account (e.g., ORG-ACCOUNT): " SNOWFLAKE_ACCOUNT
        read -p "Username: " SNOWFLAKE_USER
        
        echo ""
        echo "Authentication method:"
        echo "  1. Browser (externalbrowser) - Recommended"
        echo "  2. PAT (Programmatic Access Token)"
        read -p "Select (1-2): " AUTH_CHOICE
        
        if [[ "$AUTH_CHOICE" == "2" ]]; then
            read -sp "Enter PAT: " CONNECTION_PAT
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
    fi
    
    # Test connection
    echo ""
    echo "Testing connection..."
    if snow sql -q "SELECT CURRENT_USER(), CURRENT_ROLE()" --connection "$CONNECTION_NAME" > /dev/null 2>&1; then
        echo -e "${GREEN}Connection successful!${NC}"
    else
        echo -e "${RED}Connection failed. Please check your credentials.${NC}"
        exit 1
    fi
    
    export CONNECTION_NAME
}

# =============================================================================
# STEP 2: CONFIGURATION PROMPTS
# =============================================================================
get_configuration() {
    echo ""
    echo -e "${YELLOW}Step 2: Configuration${NC}"
    echo "----------------------------------------"
    
    read -p "Database name [$DEFAULT_DATABASE]: " DATABASE
    DATABASE=${DATABASE:-$DEFAULT_DATABASE}
    
    read -p "Schema name [$DEFAULT_SCHEMA]: " SCHEMA
    SCHEMA=${SCHEMA:-$DEFAULT_SCHEMA}
    
    read -p "Warehouse name [$DEFAULT_WAREHOUSE]: " WAREHOUSE
    WAREHOUSE=${WAREHOUSE:-$DEFAULT_WAREHOUSE}
    
    read -p "Compute pool name [$DEFAULT_POOL_NAME]: " POOL_NAME
    POOL_NAME=${POOL_NAME:-$DEFAULT_POOL_NAME}
    
    export DATABASE SCHEMA WAREHOUSE POOL_NAME
    
    echo ""
    echo -e "${GREEN}Configuration:${NC}"
    echo "  Database: $DATABASE"
    echo "  Schema: $SCHEMA"
    echo "  Warehouse: $WAREHOUSE"
    echo "  Compute Pool: $POOL_NAME"
}

# =============================================================================
# STEP 3: RUN SQL SCRIPTS
# =============================================================================
run_sql() {
    local sql="$1"
    local description="$2"
    echo "  Running: $description..."
    echo "$sql" | snow sql -i --connection "$CONNECTION_NAME" > /dev/null 2>&1
}

run_sql_file() {
    local file="$1"
    local description="$2"
    echo "  Running: $description..."
    
    # Replace placeholders in SQL file
    sed -e "s/\${DATABASE}/$DATABASE/g" \
        -e "s/\${SCHEMA}/$SCHEMA/g" \
        -e "s/\${WAREHOUSE}/$WAREHOUSE/g" \
        -e "s/\${POOL_NAME}/$POOL_NAME/g" \
        "$file" | snow sql -i --connection "$CONNECTION_NAME" > /dev/null 2>&1
}

deploy_infrastructure() {
    echo ""
    echo -e "${YELLOW}Step 3: Infrastructure Setup${NC}"
    echo "----------------------------------------"
    
    # Create database and schema
    run_sql "CREATE DATABASE IF NOT EXISTS $DATABASE" "Create database"
    run_sql "CREATE SCHEMA IF NOT EXISTS $DATABASE.$SCHEMA" "Create schema"
    run_sql "USE DATABASE $DATABASE" "Use database"
    run_sql "USE SCHEMA $SCHEMA" "Use schema"
    
    # Create warehouse
    run_sql "CREATE WAREHOUSE IF NOT EXISTS $WAREHOUSE WITH WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 120 AUTO_RESUME = TRUE" "Create warehouse"
    
    # Create compute pool
    run_sql "CREATE COMPUTE POOL IF NOT EXISTS $POOL_NAME MIN_NODES = 1 MAX_NODES = 2 INSTANCE_FAMILY = CPU_X64_XS AUTO_RESUME = TRUE AUTO_SUSPEND_SECS = 300" "Create compute pool"
    
    # Create image repository
    run_sql "CREATE IMAGE REPOSITORY IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIG_REPO" "Create image repository"
    
    # Create stages
    run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.ENGINEERING_DOCS_STAGE DIRECTORY = (ENABLE = TRUE)" "Create engineering docs stage"
    run_sql "CREATE STAGE IF NOT EXISTS $DATABASE.$SCHEMA.SEMANTIC_MODELS" "Create semantic models stage"
    
    # Create network rule and external access integration
    run_sql "CREATE OR REPLACE NETWORK RULE cortex_network_rule TYPE = HOST_PORT VALUE_LIST = ('snowflake.com:443', 'api.snowflake.com:443')" "Create network rule"
    run_sql "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS ALLOWED_NETWORK_RULES = (cortex_network_rule) ENABLED = TRUE" "Create external access integration"
    
    echo -e "${GREEN}Infrastructure setup complete!${NC}"
}

# =============================================================================
# STEP 4: CREATE TABLES
# =============================================================================
create_tables() {
    echo ""
    echo -e "${YELLOW}Step 4: Create Tables${NC}"
    echo "----------------------------------------"
    
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    run_sql_file "$SCRIPT_DIR/scripts/02_create_tables.sql" "Create tables"
    
    echo -e "${GREEN}Tables created!${NC}"
}

# =============================================================================
# STEP 5: LOAD DATA
# =============================================================================
load_data() {
    echo ""
    echo -e "${YELLOW}Step 5: Load Data${NC}"
    echo "----------------------------------------"
    
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    
    # Check if data file exists
    if [[ -f "$SCRIPT_DIR/scripts/03_load_data.sql" ]]; then
        run_sql_file "$SCRIPT_DIR/scripts/03_load_data.sql" "Load BOM and model data"
        echo -e "${GREEN}Data loaded!${NC}"
    else
        echo -e "${YELLOW}Note: 03_load_data.sql not found. You may need to load data manually.${NC}"
    fi
}

# =============================================================================
# STEP 6: SETUP CORTEX SERVICES
# =============================================================================
setup_cortex() {
    echo ""
    echo -e "${YELLOW}Step 6: Setup Cortex Services${NC}"
    echo "----------------------------------------"
    
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    run_sql_file "$SCRIPT_DIR/scripts/04_cortex_services.sql" "Create Cortex Search service"
    
    echo -e "${GREEN}Cortex services configured!${NC}"
}

# =============================================================================
# STEP 7: BUILD AND PUSH DOCKER IMAGE
# =============================================================================
build_and_push_image() {
    echo ""
    echo -e "${YELLOW}Step 7: Build and Push Docker Image${NC}"
    echo "----------------------------------------"
    
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    APP_DIR="$(dirname "$SCRIPT_DIR")"
    
    # Get repository URL
    echo "  Getting repository URL..."
    REPO_URL=$(snow spcs image-repository url TRUCK_CONFIG_REPO \
        --database "$DATABASE" \
        --schema "$SCHEMA" \
        --connection "$CONNECTION_NAME" 2>/dev/null | tr -d '[:space:]')
    
    if [[ -z "$REPO_URL" ]]; then
        echo -e "${RED}Failed to get repository URL${NC}"
        exit 1
    fi
    echo "  Repository URL: $REPO_URL"
    
    # Login to registry
    echo "  Logging in to Snowflake image registry..."
    snow spcs image-registry login --connection "$CONNECTION_NAME"
    
    # Build image
    echo "  Building Docker image..."
    cd "$APP_DIR"
    docker build -t truck-configurator:latest .
    
    # Tag and push
    echo "  Tagging and pushing image..."
    docker tag truck-configurator:latest "$REPO_URL/truck-configurator:latest"
    docker push "$REPO_URL/truck-configurator:latest"
    
    echo -e "${GREEN}Docker image pushed!${NC}"
    
    export REPO_URL
}

# =============================================================================
# STEP 8: DEPLOY SPCS SERVICE
# =============================================================================
deploy_service() {
    echo ""
    echo -e "${YELLOW}Step 8: Deploy SPCS Service${NC}"
    echo "----------------------------------------"
    
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    APP_DIR="$(dirname "$SCRIPT_DIR")"
    
    # Update spec.yaml with correct image path
    IMAGE_PATH="/$DATABASE/$SCHEMA/TRUCK_CONFIG_REPO/truck-configurator:latest"
    
    # Create service
    echo "  Creating SPCS service..."
    
    SERVICE_SQL="
    CREATE SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC
      IN COMPUTE POOL $POOL_NAME
      FROM SPECIFICATION \$\$
spec:
  containers:
    - name: truck-configurator
      image: $IMAGE_PATH
      resources:
        requests:
          memory: 2G
          cpu: 1
        limits:
          memory: 4G
          cpu: 2
      env:
        SNOWFLAKE_DATABASE: $DATABASE
        SNOWFLAKE_SCHEMA: $SCHEMA
        SNOWFLAKE_WAREHOUSE: $WAREHOUSE
  endpoints:
    - name: app
      port: 3000
      public: true
\$\$
      EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS)
      MIN_INSTANCES = 1
      MAX_INSTANCES = 1;
    "
    
    run_sql "$SERVICE_SQL" "Create SPCS service"
    
    # Wait for service to be ready
    echo "  Waiting for service to start..."
    sleep 30
    
    # Get endpoint URL
    echo "  Getting service endpoint..."
    ENDPOINT_INFO=$(snow spcs service list-endpoints TRUCK_CONFIGURATOR_SVC \
        --database "$DATABASE" \
        --schema "$SCHEMA" \
        --connection "$CONNECTION_NAME" 2>/dev/null)
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Deployment Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Service endpoint information:"
    echo "$ENDPOINT_INFO"
    echo ""
    echo "Next steps:"
    echo "  1. Wait 1-2 minutes for the service to fully initialize"
    echo "  2. Access your application at the endpoint URL above"
    echo "  3. Upload engineering specification PDFs to test AI validation"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Change to script directory
    cd "$(dirname "$0")"
    
    setup_connection
    get_configuration
    deploy_infrastructure
    create_tables
    load_data
    setup_cortex
    
    read -p "Build and deploy SPCS service? (y/n): " DEPLOY_SPCS
    if [[ "$DEPLOY_SPCS" == "y" || "$DEPLOY_SPCS" == "Y" ]]; then
        build_and_push_image
        deploy_service
    else
        echo ""
        echo -e "${GREEN}Infrastructure and data setup complete!${NC}"
        echo "To deploy the SPCS service later:"
        echo "  1. Build Docker image: docker build -t truck-configurator:latest ."
        echo "  2. Push to registry and create service"
    fi
}

main "$@"
