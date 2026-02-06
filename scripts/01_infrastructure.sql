-- Digital Twin Truck Configurator - Infrastructure Setup
-- Run this script first to create the required Snowflake objects

-- ============================================
-- STEP 1: Create Database and Schema
-- ============================================
CREATE DATABASE IF NOT EXISTS BOM;
CREATE SCHEMA IF NOT EXISTS BOM.BOM4;
USE SCHEMA BOM.BOM4;

-- ============================================
-- STEP 2: Create Compute Pool for SPCS
-- ============================================
-- Check if you have an existing compute pool you can use
SHOW COMPUTE POOLS;

-- If you need to create one (requires ACCOUNTADMIN or appropriate privileges)
CREATE COMPUTE POOL IF NOT EXISTS TRUCK_CONFIG_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 3600;

-- ============================================
-- STEP 3: Create Image Repository
-- ============================================
CREATE IMAGE REPOSITORY IF NOT EXISTS BOM.BOM4.TRUCK_CONFIG_REPO;

-- Get the repository URL for Docker push
SHOW IMAGE REPOSITORIES IN SCHEMA BOM.BOM4;
-- Note the repository_url - you'll need it for docker push

-- ============================================
-- STEP 4: Create External Access Integration (for Cortex Analyst API)
-- ============================================
CREATE OR REPLACE NETWORK RULE cortex_api_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('*.snowflakecomputing.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
  ALLOWED_NETWORK_RULES = (cortex_api_rule)
  ENABLED = TRUE;

-- ============================================
-- STEP 5: Create Secrets (IMPORTANT: Replace placeholders!)
-- ============================================
-- You need to create a PAT (Personal Access Token) in Snowsight:
-- 1. Go to Snowsight → Your Profile → Security → Personal Access Tokens
-- 2. Create a new token with appropriate permissions
-- 3. Replace <YOUR_PAT_TOKEN> below with the actual token

-- IMPORTANT: Uncomment and update these lines with your actual values
/*
CREATE OR REPLACE SECRET BOM.BOM4.SNOWFLAKE_PAT_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<YOUR_PAT_TOKEN>';
*/

-- Optional: For key-pair authentication (more secure, but more complex)
/*
CREATE OR REPLACE SECRET BOM.BOM4.SNOWFLAKE_PRIVATE_KEY_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '-----BEGIN PRIVATE KEY-----
<YOUR_PRIVATE_KEY_CONTENT>
-----END PRIVATE KEY-----';
*/

-- ============================================
-- Verification
-- ============================================
SHOW COMPUTE POOLS LIKE 'TRUCK_CONFIG%';
SHOW IMAGE REPOSITORIES IN SCHEMA BOM.BOM4;
SHOW SECRETS IN SCHEMA BOM.BOM4;
