#!/bin/bash
# Digital Twin Truck Configurator - Automated Setup Script
# This script helps you deploy the demo to your Snowflake account

set -e

echo "=================================================="
echo "  Digital Twin Truck Configurator Setup"
echo "=================================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    
    echo -e "${GREEN}✓ Prerequisites satisfied${NC}"
    echo ""
}

# Gather configuration
gather_config() {
    echo "Please provide your Snowflake configuration:"
    echo ""
    
    # Check for existing connection
    CURRENT_CONN=$(snow connection list --format json 2>/dev/null | grep -o '"default": true' || echo "")
    
    read -p "Snowflake Account (e.g., MYORG-MYACCOUNT): " SNOWFLAKE_ACCOUNT
    read -p "Snowflake Username: " SNOWFLAKE_USER
    read -p "Snowflake Warehouse [COMPUTE_WH]: " SNOWFLAKE_WAREHOUSE
    SNOWFLAKE_WAREHOUSE=${SNOWFLAKE_WAREHOUSE:-COMPUTE_WH}
    
    read -p "Database name [BOM]: " DATABASE
    DATABASE=${DATABASE:-BOM}
    
    read -p "Schema name [TRUCK_CONFIG]: " SCHEMA
    SCHEMA=${SCHEMA:-TRUCK_CONFIG}
    
    read -p "Compute Pool name [TRUCK_CONFIG_POOL]: " COMPUTE_POOL
    COMPUTE_POOL=${COMPUTE_POOL:-TRUCK_CONFIG_POOL}
    
    echo ""
    echo "Configuration:"
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

# Create database and schema
setup_infrastructure() {
    echo ""
    echo -e "${YELLOW}Step 1: Creating infrastructure...${NC}"
    
    snow sql -q "CREATE DATABASE IF NOT EXISTS $DATABASE;"
    snow sql -q "CREATE SCHEMA IF NOT EXISTS $DATABASE.$SCHEMA;"
    snow sql -q "USE SCHEMA $DATABASE.$SCHEMA;"
    
    # Create compute pool
    echo "Creating compute pool..."
    snow sql -q "CREATE COMPUTE POOL IF NOT EXISTS $COMPUTE_POOL
        MIN_NODES = 1
        MAX_NODES = 1
        INSTANCE_FAMILY = CPU_X64_XS
        AUTO_RESUME = TRUE
        AUTO_SUSPEND_SECS = 3600;" || echo "Compute pool may already exist"
    
    # Create image repository
    echo "Creating image repository..."
    snow sql -q "CREATE IMAGE REPOSITORY IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIG_REPO;"
    
    # Get repository URL
    REPO_URL=$(snow sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    echo -e "${GREEN}Image Repository URL: $REPO_URL${NC}"
    
    # Create network rule and external access
    echo "Creating external access integration..."
    snow sql -q "CREATE OR REPLACE NETWORK RULE cortex_api_rule
        TYPE = HOST_PORT
        MODE = EGRESS
        VALUE_LIST = ('*.snowflakecomputing.com:443');"
    
    snow sql -q "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
        ALLOWED_NETWORK_RULES = (cortex_api_rule)
        ENABLED = TRUE;"
    
    echo -e "${GREEN}✓ Infrastructure created${NC}"
}

# Load data
load_data() {
    echo ""
    echo -e "${YELLOW}Step 2: Loading data...${NC}"
    
    # Update scripts with user's schema
    sed -i.bak "s/BOM\.BOM4/$DATABASE.$SCHEMA/g" scripts/02_data.sql
    sed -i.bak "s/BOM\.BOM4/$DATABASE.$SCHEMA/g" scripts/02b_bom_data.sql
    sed -i.bak "s/BOM\.BOM4/$DATABASE.$SCHEMA/g" scripts/02c_truck_options.sql
    sed -i.bak "s/BOM\.BOM4/$DATABASE.$SCHEMA/g" scripts/03_semantic_view.sql
    
    snow sql -f scripts/02_data.sql
    snow sql -f scripts/02b_bom_data.sql
    snow sql -f scripts/02c_truck_options.sql
    
    echo -e "${GREEN}✓ Data loaded${NC}"
}

# Create semantic view
create_semantic_view() {
    echo ""
    echo -e "${YELLOW}Step 3: Creating semantic view...${NC}"
    
    snow sql -f scripts/03_semantic_view.sql
    
    echo -e "${GREEN}✓ Semantic view created${NC}"
}

# Setup PAT secret
setup_secrets() {
    echo ""
    echo -e "${YELLOW}Step 4: Setting up authentication...${NC}"
    echo ""
    echo "You need a Personal Access Token (PAT) for Cortex Analyst API."
    echo "Create one at: Snowsight → Profile → Security → Personal Access Tokens"
    echo ""
    read -p "Enter your PAT (or press Enter to skip for now): " PAT_TOKEN
    
    if [[ -n "$PAT_TOKEN" ]]; then
        snow sql -q "CREATE OR REPLACE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET
            TYPE = GENERIC_STRING
            SECRET_STRING = '$PAT_TOKEN';"
        echo -e "${GREEN}✓ PAT secret created${NC}"
    else
        echo -e "${YELLOW}⚠ Skipped PAT setup - you'll need to create the secret manually${NC}"
        echo "Run: CREATE SECRET $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET TYPE = GENERIC_STRING SECRET_STRING = '<your-pat>';"
    fi
}

# Build and push Docker image
build_docker() {
    echo ""
    echo -e "${YELLOW}Step 5: Building Docker image...${NC}"
    
    # Login to Snowflake registry
    echo "Logging into Snowflake image registry..."
    snow spcs image-registry login
    
    # Get repository URL
    REPO_URL=$(snow sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    echo "Building Docker image (this may take a few minutes)..."
    cd docker
    docker buildx build --platform linux/amd64 -t truck-config:v1 .
    
    echo "Tagging image..."
    docker tag truck-config:v1 "$REPO_URL/truck-config:v1"
    
    echo "Pushing to Snowflake registry..."
    docker push "$REPO_URL/truck-config:v1"
    
    cd ..
    echo -e "${GREEN}✓ Docker image pushed to $REPO_URL/truck-config:v1${NC}"
}

# Deploy service
deploy_service() {
    echo ""
    echo -e "${YELLOW}Step 6: Deploying SPCS service...${NC}"
    
    # Get repository URL
    REPO_URL=$(snow sql -q "SHOW IMAGE REPOSITORIES IN SCHEMA $DATABASE.$SCHEMA;" --format json | grep -o '"repository_url": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    snow sql -q "CREATE SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC
      IN COMPUTE POOL $COMPUTE_POOL
      FROM SPECIFICATION \$\$
spec:
  containers:
    - name: truck-configurator
      image: $REPO_URL/truck-config:v1
      env:
        SNOWFLAKE_ACCOUNT: $SNOWFLAKE_ACCOUNT
        SNOWFLAKE_USER: $SNOWFLAKE_USER
        SNOWFLAKE_WAREHOUSE: $SNOWFLAKE_WAREHOUSE
        SNOWFLAKE_DATABASE: $DATABASE
        SNOWFLAKE_SCHEMA: $SCHEMA
        SNOWFLAKE_SEMANTIC_VIEW: $DATABASE.$SCHEMA.TRUCK_CONFIG_ANALYST_V2
      secrets:
        - snowflakeName: $DATABASE.$SCHEMA.SNOWFLAKE_PAT_SECRET
          secretKeyRef: token
          envVarName: SNOWFLAKE_PAT
      resources:
        requests:
          cpu: 0.5
          memory: 1Gi
        limits:
          cpu: 2
          memory: 4Gi
  endpoints:
    - name: web
      port: 8080
      public: true
  networkPolicyConfig:
    allowInternetEgress: true
\$\$
EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS)
MIN_INSTANCES = 1
MAX_INSTANCES = 1;"
    
    echo ""
    echo "Waiting for service to start (this may take 60-90 seconds)..."
    sleep 30
    
    # Check status
    STATUS=$(snow sql -q "SELECT SYSTEM\$GET_SERVICE_STATUS('$DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC');" --format json | grep -o '"status": "[^"]*"' | head -1 | cut -d'"' -f4 || echo "PENDING")
    
    if [[ "$STATUS" == *"RUNNING"* ]]; then
        echo -e "${GREEN}✓ Service is running!${NC}"
    else
        echo -e "${YELLOW}Service status: $STATUS - may still be starting${NC}"
    fi
}

# Get service URL
get_service_url() {
    echo ""
    echo -e "${YELLOW}Step 7: Getting service URL...${NC}"
    
    sleep 10
    
    snow sql -q "SHOW ENDPOINTS IN SERVICE $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC;"
    
    echo ""
    echo -e "${GREEN}=================================================="
    echo "  Setup Complete!"
    echo "==================================================${NC}"
    echo ""
    echo "Your Digital Twin Truck Configurator is deploying."
    echo "Run this to check status:"
    echo "  snow sql -q \"SELECT SYSTEM\\\$GET_SERVICE_STATUS('$DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC');\""
    echo ""
    echo "Run this to get the URL:"
    echo "  snow sql -q \"SHOW ENDPOINTS IN SERVICE $DATABASE.$SCHEMA.TRUCK_CONFIGURATOR_SVC;\""
    echo ""
}

# Main execution
main() {
    check_prereqs
    gather_config
    setup_infrastructure
    load_data
    create_semantic_view
    setup_secrets
    
    echo ""
    read -p "Build and push Docker image? (y/n): " BUILD_DOCKER
    if [[ "$BUILD_DOCKER" == "y" || "$BUILD_DOCKER" == "Y" ]]; then
        build_docker
        deploy_service
        get_service_url
    else
        echo ""
        echo "To complete setup manually:"
        echo "1. Build Docker: cd docker && docker buildx build --platform linux/amd64 -t truck-config:v1 ."
        echo "2. Push to registry (get URL from SHOW IMAGE REPOSITORIES)"
        echo "3. Create service using scripts/05_service.sql"
    fi
}

# Run main
main
