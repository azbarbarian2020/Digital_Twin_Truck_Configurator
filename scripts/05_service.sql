-- Digital Twin Truck Configurator - Service Deployment
-- Run after 03_semantic_view.sql and after pushing Docker image

USE SCHEMA BOM.BOM4;

-- ============================================
-- IMPORTANT: Update these placeholders!
-- ============================================
-- <YOUR_ACCOUNT>   - Your Snowflake account (e.g., MYORG-MYACCOUNT)
-- <YOUR_USER>      - Your Snowflake username
-- <YOUR_WAREHOUSE> - Your warehouse name
-- <REGISTRY_URL>   - From: SHOW IMAGE REPOSITORIES IN SCHEMA BOM.BOM4

-- ============================================
-- Create Service
-- ============================================

CREATE SERVICE IF NOT EXISTS BOM.BOM4.TRUCK_CONFIGURATOR_SVC
  IN COMPUTE POOL TRUCK_CONFIG_POOL
  FROM SPECIFICATION $$
spec:
  containers:
    - name: truck-configurator
      image: <REGISTRY_URL>/truck-config:v1
      env:
        SNOWFLAKE_ACCOUNT: <YOUR_ACCOUNT>
        SNOWFLAKE_USER: <YOUR_USER>
        SNOWFLAKE_WAREHOUSE: <YOUR_WAREHOUSE>
        SNOWFLAKE_DATABASE: BOM
        SNOWFLAKE_SCHEMA: BOM4
        SNOWFLAKE_SEMANTIC_VIEW: BOM.BOM4.TRUCK_CONFIG_ANALYST_V2
      secrets:
        - snowflakeName: BOM.BOM4.SNOWFLAKE_PAT_SECRET
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
$$
EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS)
MIN_INSTANCES = 1
MAX_INSTANCES = 1;

-- Wait for service to start (about 30-60 seconds)
-- Check status:
SELECT SYSTEM$GET_SERVICE_STATUS('BOM.BOM4.TRUCK_CONFIGURATOR_SVC');

-- ============================================
-- Get Service URL
-- ============================================
SHOW ENDPOINTS IN SERVICE BOM.BOM4.TRUCK_CONFIGURATOR_SVC;
-- Open the ingress_url in your browser!

-- ============================================
-- Useful Commands
-- ============================================

-- View service logs:
-- CALL SYSTEM$GET_SERVICE_LOGS('BOM.BOM4.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);

-- Suspend service:
-- ALTER SERVICE BOM.BOM4.TRUCK_CONFIGURATOR_SVC SUSPEND;

-- Resume service:
-- ALTER SERVICE BOM.BOM4.TRUCK_CONFIGURATOR_SVC RESUME;

-- Update service (use ALTER, never DROP):
-- ALTER SERVICE BOM.BOM4.TRUCK_CONFIGURATOR_SVC FROM SPECIFICATION $$...$$;
