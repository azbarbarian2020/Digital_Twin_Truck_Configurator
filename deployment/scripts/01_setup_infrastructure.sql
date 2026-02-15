-- =============================================================================
-- Digital Twin Truck Configurator - Infrastructure Setup
-- =============================================================================
-- Part 1 of 4: Creates compute pool, image repository, stages, and integrations
-- Customize ${DATABASE} and ${SCHEMA} before running
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- 1. CREATE DATABASE AND SCHEMA (if needed)
-- =============================================================================
CREATE DATABASE IF NOT EXISTS ${DATABASE};
CREATE SCHEMA IF NOT EXISTS ${DATABASE}.${SCHEMA};
USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};

-- =============================================================================
-- 2. CREATE WAREHOUSE (if needed)
-- =============================================================================
CREATE WAREHOUSE IF NOT EXISTS ${WAREHOUSE}
    WITH WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE;

-- =============================================================================
-- 3. CREATE COMPUTE POOL FOR SPCS
-- =============================================================================
CREATE COMPUTE POOL IF NOT EXISTS ${DATABASE}_${SCHEMA}_POOL
    MIN_NODES = 1
    MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300
    COMMENT = 'Compute pool for Digital Twin Truck Configurator';

-- =============================================================================
-- 4. CREATE IMAGE REPOSITORY
-- =============================================================================
CREATE IMAGE REPOSITORY IF NOT EXISTS ${DATABASE}.${SCHEMA}.TRUCK_CONFIG_REPO
    COMMENT = 'Container images for Truck Configurator';

-- Get repository URL for later use
SHOW IMAGE REPOSITORIES IN SCHEMA ${DATABASE}.${SCHEMA};
-- Note: Copy the repository_url from output for Docker image push

-- =============================================================================
-- 5. CREATE INTERNAL STAGES
-- =============================================================================
CREATE STAGE IF NOT EXISTS ${DATABASE}.${SCHEMA}.ENGINEERING_DOCS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Stage for engineering specification PDFs';

CREATE STAGE IF NOT EXISTS ${DATABASE}.${SCHEMA}.SEMANTIC_MODELS
    COMMENT = 'Stage for semantic model YAML files';

-- =============================================================================
-- 6. CREATE EXTERNAL ACCESS INTEGRATION
-- =============================================================================
-- Required for SPCS services to access Snowflake Cortex APIs

-- First create network rule
CREATE OR REPLACE NETWORK RULE cortex_network_rule
    TYPE = HOST_PORT
    VALUE_LIST = ('snowflake.com:443', 'api.snowflake.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
    ALLOWED_NETWORK_RULES = (cortex_network_rule)
    ENABLED = TRUE
    COMMENT = 'Allow truck configurator to access Snowflake Cortex APIs';

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================
-- Run these to verify infrastructure setup

-- Check compute pool
-- DESCRIBE COMPUTE POOL ${DATABASE}_${SCHEMA}_POOL;

-- Check image repository  
-- SHOW IMAGE REPOSITORIES IN SCHEMA ${DATABASE}.${SCHEMA};

-- Check stages
-- SHOW STAGES IN SCHEMA ${DATABASE}.${SCHEMA};

-- Check external access integration
-- SHOW EXTERNAL ACCESS INTEGRATIONS LIKE '%TRUCK%';
