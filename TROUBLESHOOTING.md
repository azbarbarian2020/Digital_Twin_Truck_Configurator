# Troubleshooting Guide

Common issues and solutions for the Digital Twin Truck Configurator SPCS deployment.

## Table of Contents
- [Service Won't Start](#service-wont-start)
- [Configuration Assistant Issues](#configuration-assistant-issues)
- [File Upload Issues](#file-upload-issues)
- [Configuration Delete Not Working](#configuration-delete-not-working)
- [Data Issues](#data-issues)
- [Docker/Registry Issues](#dockerregistry-issues)
- [Service Spec Errors](#service-spec-errors)

---

## Service Won't Start

### Check Status and Logs
```sql
-- Check service status
SELECT SYSTEM$GET_SERVICE_STATUS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC');

-- View container logs
CALL SYSTEM$GET_SERVICE_LOGS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);
```

### Common Causes

**1. Compute Pool Not Running**
```sql
-- Check compute pool status
SHOW COMPUTE POOLS;

-- Resume if suspended
ALTER COMPUTE POOL TRUCK_CONFIG_POOL RESUME;
```

**2. Image Not Found**
```sql
-- Verify image exists
SHOW IMAGES IN IMAGE REPOSITORY BOM.TRUCK_CONFIG.TRUCK_CONFIG_REPO;
```

**3. Secret Not Found**
```sql
-- List secrets
SHOW SECRETS IN SCHEMA BOM.TRUCK_CONFIG;

-- Verify both required secrets exist:
-- - SNOWFLAKE_PAT_SECRET
-- - SNOWFLAKE_PRIVATE_KEY_SECRET
```

---

## Configuration Assistant Issues

### "Connection Timed Out" Error

**Symptom**: Configuration Assistant shows "HTTPSConnectionPool... Max retries exceeded... Connection timed out"

**Cause**: Missing `EXTERNAL_ACCESS_INTEGRATIONS`. The `networkPolicyConfig.allowInternetEgress: true` setting in the service spec is **NOT sufficient** for REST API calls.

**Solution**:
```sql
-- 1. Create network rule (if not exists)
CREATE OR REPLACE NETWORK RULE BOM.TRUCK_CONFIG.CORTEX_API_RULE
    TYPE = HOST_PORT
    MODE = EGRESS
    VALUE_LIST = ('*.snowflakecomputing.com:443');

-- 2. Create external access integration (if not exists)
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
    ALLOWED_NETWORK_RULES = (BOM.TRUCK_CONFIG.CORTEX_API_RULE)
    ENABLED = TRUE;

-- 3. Add to service
ALTER SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC 
    SET EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS);
```

### PAT Authentication Failed (Azure/GCP)

**Symptom**: Error 395090 or "unauthorized" when calling Cortex Analyst

**Cause**: On Azure and GCP, PAT authentication is blocked for REST APIs. Only OAuth is supported.

**Solution**: This demo only works on AWS Snowflake accounts. Check your platform:
```sql
SELECT CURRENT_REGION();
-- AWS regions start with AWS_
-- Azure regions start with AZURE_
```

### Configuration Assistant Returns Generic Response

**Symptom**: Assistant gives generic responses instead of using Cortex Analyst

**Cause**: PAT secret not configured or semantic view missing

**Solution**:
```sql
-- Verify PAT secret
SHOW SECRETS LIKE 'SNOWFLAKE_PAT_SECRET' IN SCHEMA BOM.TRUCK_CONFIG;

-- Verify semantic view
SHOW SEMANTIC VIEWS IN SCHEMA BOM.TRUCK_CONFIG;
```

---

## File Upload Issues

### "Failed to Extract Text from PDF"

**Symptom**: Uploading engineering documents fails with extraction error

**Cause**: Frontend PAT authentication doesn't support PUT commands to stages. Only key-pair authentication works for PUT.

**Solution**: Ensure the private key secret is configured:
```sql
-- Check if private key secret exists
SHOW SECRETS LIKE 'SNOWFLAKE_PRIVATE_KEY_SECRET' IN SCHEMA BOM.TRUCK_CONFIG;

-- If missing, create it (with escaped newlines):
-- openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out key.p8
-- Then create secret with the key content
```

### Stage Encryption Error with PARSE_DOCUMENT

**Symptom**: PARSE_DOCUMENT fails on uploaded files

**Cause**: Stage uses incompatible encryption type

**Solution**:
```sql
-- Check stage encryption
DESC STAGE BOM.TRUCK_CONFIG.ENGINEERING_DOCS_STAGE;

-- Recreate with correct encryption
CREATE OR REPLACE STAGE BOM.TRUCK_CONFIG.ENGINEERING_DOCS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

---

## Configuration Delete Not Working

### Delete Button Does Nothing

**Symptom**: Clicking delete on saved configurations has no effect

**Cause**: Frontend route format mismatch. The UI calls `/api/configs/${configId}` (path param) but the original route expected `/api/configs?configId=xxx` (query param).

**Solution**: Ensure the dynamic route exists:
```
docker/app/api/configs/[configId]/route.ts
```

This file should proxy DELETE requests to the backend.

---

## Data Issues

### Validation Always Returns "Valid" (Even When Wrong)

**Symptom**: Verify Configuration always says configuration is valid, even when components don't meet requirements

**Cause**: `SPECS` column in `BOM_TBL` is NULL - the validation has no specification data to check against

**Diagnosis**:
```sql
-- Check SPECS data - look for "? Spec not found" messages in logs
SELECT COUNT(*) FROM BOM.TRUCK_CONFIG.BOM_TBL WHERE SPECS IS NOT NULL;
-- Should return 253

-- If 0, the SPECS data is missing
```

**Solution**:
```sql
-- Re-run the SPECS data script
-- This loads 253 component specifications needed for validation
-- Example: Turbocharger SPECS include boost_psi, max_hp_supported
-- Run scripts/02c_specs_data.sql
```

### Empty Tooltips on Components

**Symptom**: Hovering over components shows no specification tooltips

**Cause**: Same as above - `SPECS` column in `BOM_TBL` is NULL

**Solution**: Run `scripts/02c_specs_data.sql`

### Missing Truck Options

**Symptom**: Some trucks have no configurable options

**Solution**:
```sql
-- Check option mappings
SELECT MODEL_ID, COUNT(*) 
FROM BOM.TRUCK_CONFIG.TRUCK_OPTIONS 
GROUP BY MODEL_ID;
-- Should show ~170+ options per model
```

---

## Docker/Registry Issues

### "unauthorized" on Docker Push

**Symptom**: `docker push` fails with authentication error

**Solution**:
```bash
# Re-login to Snowflake registry
snow spcs image-registry login --connection your_connection
```

### Image Build Fails

**Symptom**: Docker build errors

**Solution**:
```bash
# Ensure building for correct platform (SPCS requires amd64)
docker buildx build --platform linux/amd64 -t truck-config:v1 docker/

# If buildx not available, use:
docker build --platform linux/amd64 -t truck-config:v1 docker/
```

---

## Service Spec Errors

### "Cannot deserialize value" Error

**Symptom**: Service creation fails with JSON deserialization error

**Cause**: Wrong YAML syntax for secrets

**WRONG** (causes error):
```yaml
secrets:
  - snowflakeName: BOM.TRUCK_CONFIG.SECRET_NAME
    envVarName: MY_VAR
```

**CORRECT**:
```yaml
secrets:
  - snowflakeSecret:
      objectName: BOM.TRUCK_CONFIG.SECRET_NAME
    secretKeyRef: secret_string
    envVarName: MY_VAR
```

### Service URL Changed After Update

**Symptom**: Service URL no longer works after update

**Cause**: Service was dropped and recreated instead of altered

**Prevention**: Always use `ALTER SERVICE ... FROM SPECIFICATION` to update. Never DROP and CREATE.

```sql
-- CORRECT way to update
ALTER SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC FROM SPECIFICATION $$
spec:
  containers:
    - name: truck-configurator
      image: <new_image_tag>
      ...
$$;

-- WRONG (changes URL)
DROP SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC;
CREATE SERVICE ...
```

---

## Quick Diagnostic Commands

```sql
-- Full service status
SELECT SYSTEM$GET_SERVICE_STATUS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC');

-- Recent logs
CALL SYSTEM$GET_SERVICE_LOGS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 200);

-- Service endpoints
SHOW ENDPOINTS IN SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC;

-- All secrets
SHOW SECRETS IN SCHEMA BOM.TRUCK_CONFIG;

-- External access integrations
SHOW EXTERNAL ACCESS INTEGRATIONS;

-- Compute pool status
DESCRIBE COMPUTE POOL TRUCK_CONFIG_POOL;
```

---

## Getting Help

If issues persist:
1. Check logs for specific error messages
2. Verify all prerequisites are met
3. Confirm you're on an AWS Snowflake account
4. Review the architecture diagram in README.md

For Snowflake-specific issues, consult:
- [SPCS Documentation](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)
- [Cortex Analyst Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
