-- Digital Twin Truck Configurator - Service Deployment
-- Run after 04_additional_objects.sql and after pushing Docker image
--
-- IMPORTANT: This template uses the CORRECT secrets syntax.
-- The wrong syntax causes "Cannot deserialize value" errors.

-- ============================================
-- PLACEHOLDERS TO UPDATE
-- ============================================
-- Replace these before running:
--   <YOUR_ACCOUNT>   - Snowflake account (e.g., MYORG-MYACCOUNT)
--   <YOUR_HOST>      - Full hostname (e.g., myorg-myaccount.snowflakecomputing.com)
--   <YOUR_USER>      - Snowflake username
--   <YOUR_WAREHOUSE> - Warehouse name
--   <YOUR_DATABASE>  - Database name (default: BOM)
--   <YOUR_SCHEMA>    - Schema name (default: TRUCK_CONFIG)
--   <REGISTRY_URL>   - From: SHOW IMAGE REPOSITORIES IN SCHEMA <db>.<schema>

USE SCHEMA <YOUR_DATABASE>.<YOUR_SCHEMA>;

-- ============================================
-- Create Service
-- ============================================
-- CRITICAL NOTES:
-- 1. Secrets use snowflakeSecret.objectName + secretKeyRef syntax (NOT snowflakeName)
-- 2. EXTERNAL_ACCESS_INTEGRATIONS is REQUIRED for Cortex Analyst REST API
--    (networkPolicyConfig.allowInternetEgress alone is NOT sufficient)
-- 3. Two secrets are required:
--    - SNOWFLAKE_PAT_SECRET: For Cortex Analyst REST API calls
--    - SNOWFLAKE_PRIVATE_KEY_SECRET: For PUT commands (file uploads)

CREATE SERVICE IF NOT EXISTS <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC
  IN COMPUTE POOL TRUCK_CONFIG_POOL
  FROM SPECIFICATION $$
spec:
  containers:
    - name: truck-configurator
      image: <REGISTRY_URL>/truck-config:v1
      env:
        SNOWFLAKE_ACCOUNT: <YOUR_ACCOUNT>
        SNOWFLAKE_HOST: <YOUR_HOST>
        SNOWFLAKE_USER: <YOUR_USER>
        SNOWFLAKE_WAREHOUSE: <YOUR_WAREHOUSE>
        SNOWFLAKE_DATABASE: <YOUR_DATABASE>
        SNOWFLAKE_SCHEMA: <YOUR_SCHEMA>
        SNOWFLAKE_SEMANTIC_VIEW: <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIG_ANALYST_V2
      secrets:
        - snowflakeSecret:
            objectName: <YOUR_DATABASE>.<YOUR_SCHEMA>.SNOWFLAKE_PAT_SECRET
          secretKeyRef: secret_string
          envVarName: SNOWFLAKE_PAT
        - snowflakeSecret:
            objectName: <YOUR_DATABASE>.<YOUR_SCHEMA>.SNOWFLAKE_PRIVATE_KEY_SECRET
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
$$
EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS)
MIN_INSTANCES = 1
MAX_INSTANCES = 1;

-- ============================================
-- Check Service Status
-- ============================================
-- Wait 60-90 seconds for service to start
SELECT SYSTEM$GET_SERVICE_STATUS('<YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC');

-- ============================================
-- Get Service URL
-- ============================================
SHOW ENDPOINTS IN SERVICE <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC;
-- Open the ingress_url in your browser!

-- ============================================
-- Useful Commands
-- ============================================

-- View logs:
-- CALL SYSTEM$GET_SERVICE_LOGS('<YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);

-- Suspend (save costs):
-- ALTER SERVICE <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC SUSPEND;

-- Resume:
-- ALTER SERVICE <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC RESUME;

-- Update image (IMPORTANT: use ALTER, never DROP - preserves URL):
-- ALTER SERVICE <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC FROM SPECIFICATION $$...$$;

-- ============================================
-- Troubleshooting
-- ============================================

-- If Configuration Assistant shows "Connection timed out":
-- The EXTERNAL_ACCESS_INTEGRATIONS may be missing. Run:
-- ALTER SERVICE <YOUR_DATABASE>.<YOUR_SCHEMA>.TRUCK_CONFIGURATOR_SVC 
--   SET EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS);

-- If secrets error "Cannot deserialize value":
-- Check the YAML syntax - must use snowflakeSecret.objectName (not snowflakeName)

-- If file uploads fail:
-- Ensure SNOWFLAKE_PRIVATE_KEY_SECRET is configured with escaped newlines
