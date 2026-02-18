# Digital Twin Truck Configurator - Complete Documentation

**Last Updated:** 2026-02-18
**Current Version:** v74
**Status:** Fully Working on awsbarbarian (BOM.TRUCK_CONFIG)

---

## 1. Application Overview

### Purpose
An interactive truck configuration application that allows users to:
- Select from 5 truck models (Regional Hauler, Fleet Workhorse, Cross Country Pro, Heavy Haul Max, Executive Hauler)
- Customize components (engine, transmission, suspension, etc.)
- Optimize configurations using AI (Cortex Analyst via semantic view)
- Upload engineering specification documents
- Validate configurations against document-based requirements
- Save, compare, and export configurations

### Key Features
1. **AI-Powered Optimization** - Natural language queries like "optimize for fuel efficiency" via Cortex Analyst
2. **Document-Based Validation** - Upload PDFs with component requirements, automatically extract rules
3. **Real-time Spec Comparison** - Verify configurations meet engineering requirements
4. **Configuration Management** - Save, load, compare configurations
5. **BOM Reports** - Generate detailed Bill of Materials reports

---

## 2. Architecture

### Technology Stack
- **Frontend:** Next.js 15.5.11 (React)
- **Backend:** FastAPI (Python 3.11)
- **Database:** Snowflake
- **AI/ML:** Snowflake Cortex (Analyst, Complete, Search)
- **Deployment:** Snowpark Container Services (SPCS)
- **Proxy:** Nginx (routes between frontend/backend)

### Container Architecture
```
┌─────────────────────────────────────────┐
│           SPCS Container                │
│  ┌─────────────────────────────────┐    │
│  │         Supervisord             │    │
│  │  (Process Manager - PID 1)      │    │
│  └─────────────────────────────────┘    │
│       │           │           │         │
│  ┌────▼───┐  ┌────▼───┐  ┌────▼───┐    │
│  │ Nginx  │  │Backend │  │Frontend│    │
│  │ :8080  │  │ :8000  │  │ :3000  │    │
│  └────────┘  └────────┘  └────────┘    │
│       │                                 │
│       ▼ Routes:                         │
│  /api/* → Backend (FastAPI)             │
│  /*     → Frontend (Next.js)            │
└─────────────────────────────────────────┘
```

### Database Schema (BOM.TRUCK_CONFIG)

#### Core Tables
| Table | Purpose |
|-------|---------|
| MODEL_TBL | 5 truck models with base specs |
| BOM_TBL | All component options with specs, costs, weights |
| TRUCK_OPTIONS | Model-to-option mappings with defaults |
| SAVED_CONFIGS | User-saved configurations |

#### Document/Validation Tables
| Table | Purpose |
|-------|---------|
| ENGINEERING_DOCS_CHUNKED | Document chunks for search (DOC_ID, CHUNK_TEXT, etc.) |
| VALIDATION_RULES | Extracted rules (COMPONENT_GROUP, SPEC_NAME, MIN_VALUE, MAX_VALUE) |

#### Supporting Objects
| Object | Type | Purpose |
|--------|------|---------|
| ENGINEERING_DOCS_STAGE | Stage | Stores uploaded PDFs |
| ENGINEERING_DOCS_SEARCH | Cortex Search Service | Semantic search over documents |
| TRUCK_CONFIG_ANALYST_V2 | Semantic View | Powers AI optimization queries |
| UPLOAD_AND_PARSE_DOCUMENT | Procedure | Parses PDFs via Cortex |

---

## 3. SPCS Deployment Configuration

### Working Service Spec (v74)
```yaml
spec:
  containers:
  - name: "truck-configurator"
    image: "sfsenorthamerica-awsbarbarian.registry.snowflakecomputing.com/bom/truck_config/truck_config_repo/truck-configurator:v74"
    env:
      SNOWFLAKE_WAREHOUSE: "DEMO_WH"
      SNOWFLAKE_DATABASE: "BOM"
      SNOWFLAKE_SCHEMA: "TRUCK_CONFIG"
      SNOWFLAKE_ACCOUNT: "SFSENORTHAMERICA-AWSBARBARIAN"
      SNOWFLAKE_HOST: "sfsenorthamerica-awsbarbarian.snowflakecomputing.com"
      SNOWFLAKE_USER: "HORIZONADMIN"
      NODE_ENV: "production"
    resources:
      limits:
        memory: "4G"
        cpu: "1"
      requests:
        memory: "2G"
        cpu: "1"
    secrets:
    - snowflakeSecret:
        objectName: "BOM.TRUCK_CONFIG.SNOWFLAKE_PRIVATE_KEY_SECRET"
      secretKeyRef: "secret_string"
      envVarName: "SNOWFLAKE_PRIVATE_KEY"
  endpoints:
  - name: "app"
    port: 8080
    public: true
  networkPolicyConfig:
    allowInternetEgress: true
```

### Critical SPCS Requirements
1. **Key-pair authentication via secret** - SPCS OAuth alone is unreliable
2. **networkPolicyConfig.allowInternetEgress: true** - Required for external calls
3. **EXTERNAL_ACCESS_INTEGRATIONS** - Must include network rule for Snowflake host
4. **SNOWFLAKE_USER env var** - Required for key-pair auth

### Network Rule Pattern
```sql
CREATE NETWORK RULE SNOWFLAKE_API_RULE
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('sfsenorthamerica-awsbarbarian.snowflakecomputing.com:443');

CREATE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
  ALLOWED_NETWORK_RULES = (SNOWFLAKE_API_RULE)
  ENABLED = TRUE;
```

---

## 4. Key Code Patterns

### Snowflake Connection (backend/main.py)
```python
def get_connection():
    global _connection
    if _connection is not None:
        return _connection
    
    # Priority 1: Key-pair auth (SPCS with secret)
    private_key = os.getenv("SNOWFLAKE_PRIVATE_KEY")
    if private_key:
        # Decode and use RSA key
        _connection = snowflake.connector.connect(
            account=SNOWFLAKE_ACCOUNT,
            user=os.getenv("SNOWFLAKE_USER"),
            private_key=p_key,
            warehouse=SNOWFLAKE_WAREHOUSE,
            database=SNOWFLAKE_DATABASE,
            schema=SNOWFLAKE_SCHEMA,
        )
    # Priority 2: SPCS OAuth token (fallback, less reliable)
    elif token:
        _connection = snowflake.connector.connect(
            host=SNOWFLAKE_HOST,
            account=SNOWFLAKE_ACCOUNT,
            authenticator="oauth",
            token=token,
            ...
        )
    # Priority 3: Local dev connection
    else:
        _connection = snowflake.connector.connect(
            connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME"),
            ...
        )
```

### Document Upload Flow
1. Upload file to stage (via stored procedure for PDFs)
2. Chunk text into 1500-char segments with 200-char overlap
3. INSERT chunks into ENGINEERING_DOCS_CHUNKED table
4. Search service auto-refreshes via target_lag (NO sync refresh)
5. Extract validation rules using Cortex Complete
6. INSERT rules into VALIDATION_RULES table

### Document Download Flow
1. Backend returns presigned URL via GET_PRESIGNED_URL()
2. Frontend fetches JSON response, extracts URL
3. Frontend opens presigned URL in new tab

---

## 5. Lessons Learned

### SPCS Authentication
| Issue | Symptom | Solution |
|-------|---------|----------|
| SPCS OAuth unauthorized | `Client is unauthorized to use Snowpark Container Services OAuth token` | Use key-pair auth via secret instead |
| Missing SNOWFLAKE_USER | Connection fails silently | Add SNOWFLAKE_USER env var to service spec |
| Missing secrets block | Falls back to OAuth which fails | Add secrets section with SNOWFLAKE_PRIVATE_KEY_SECRET |

### Document Operations
| Issue | Symptom | Solution |
|-------|---------|----------|
| Sync search refresh timeout | Upload hangs at "Indexing..." | Remove ALTER CORTEX SEARCH SERVICE REFRESH, let target_lag handle it |
| GET command in SPCS | SQL syntax errors or no file | GET is client-side only; use presigned URLs instead |
| Download shows JSON | Raw JSON displayed in browser | Frontend must fetch JSON, extract URL, then window.open(url) |

### Format String Errors
| Issue | Symptom | Solution |
|-------|---------|----------|
| Decimal formatting | `Unknown format code ',' for object of type 'Decimal'` | Wrap in try/except, use safe formatting |

### Service Spec Patterns
| Pattern | Wrong | Correct |
|---------|-------|---------|
| Secret reference | `snowflakeName:` | `snowflakeSecret: objectName:` |
| Secret key ref | `secretKeyRef: password` | `secretKeyRef: secret_string` (for GENERIC_STRING) |
| Container name | Must match supervisor config | `truck-configurator` or `main` |

---

## 6. File Locations

### Local Development
```
/Users/jdrew/coco_projects/BOM/truck-configurator/
├── backend/
│   ├── main.py              # FastAPI backend (all API endpoints)
│   └── requirements.txt
├── components/
│   ├── Configurator.tsx     # Main configurator UI
│   ├── ChatPanel.tsx        # AI assistant chat
│   └── ...
├── app/
│   ├── page.tsx             # Main page
│   └── api/                  # Next.js API routes (some validation)
├── Dockerfile
├── nginx.conf
└── deployment/
    └── setup.sh             # Automated deployment script
```

### Snowflake Objects
```
BOM.TRUCK_CONFIG/
├── Tables: MODEL_TBL, BOM_TBL, TRUCK_OPTIONS, SAVED_CONFIGS
├── Tables: ENGINEERING_DOCS_CHUNKED, VALIDATION_RULES
├── Stage: ENGINEERING_DOCS_STAGE
├── Search: ENGINEERING_DOCS_SEARCH
├── View: TRUCK_CONFIG_ANALYST_V2 (semantic)
├── Secret: SNOWFLAKE_PRIVATE_KEY_SECRET
├── Repo: TRUCK_CONFIG_REPO
└── Service: TRUCK_CONFIGURATOR_SVC
```

---

## 7. Deployment Checklist

### Fresh Deployment
1. Run `deployment/setup.sh`
2. Select or create connection
3. Script creates: database, schema, tables, stage, search service, compute pool, image repo
4. Script generates RSA key-pair and creates secret
5. Script builds and pushes Docker image
6. Script creates service with proper spec

### Updating Existing Deployment
```bash
# 1. Build new image
docker build --platform linux/amd64 -t <registry>/truck-configurator:vXX .

# 2. Login and push
snow spcs image-registry login --connection <conn>
docker push <registry>/truck-configurator:vXX

# 3. Update service
ALTER SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC FROM SPECIFICATION $$
spec:
  containers:
  - name: "truck-configurator"
    image: "<registry>/truck-configurator:vXX"
    ...
$$;
```

---

## 8. Troubleshooting

### Check Service Status
```sql
SELECT SYSTEM$GET_SERVICE_STATUS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC');
```

### Check Service Logs
```sql
CALL SYSTEM$GET_SERVICE_LOGS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);
```

### Common Issues
| Log Message | Cause | Fix |
|-------------|-------|-----|
| "Client is unauthorized to use Snowpark Container Services OAuth token" | Missing key-pair auth | Add secrets block to service spec |
| "Could not connect to Snowflake backend" | Wrong network rule | Network rule must include account host |
| 500 on /api/models | Backend can't connect to Snowflake | Check auth, check logs |
| Upload hangs | Sync search refresh timeout | Remove ALTER CORTEX SEARCH SERVICE REFRESH |

---

## 9. Version History

| Version | Date | Changes |
|---------|------|---------|
| v74 | 2026-02-18 | Fixed download: frontend fetches presigned URL from JSON response |
| v73 | 2026-02-18 | Fixed download: backend returns presigned URL (GET doesn't work in SPCS) |
| v72 | 2026-02-18 | Attempted GET command fix (didn't work) |
| v71 | 2026-02-18 | Removed sync search refresh from upload/delete |
| v70 | 2026-02-18 | Various validation fixes |
| Earlier | Various | Initial development |

---

## 10. Accounts

| Account | Schema | Status | Endpoint |
|---------|--------|--------|----------|
| awsbarbarian | BOM.TRUCK_CONFIG | ✅ Working (v74) | nfd4536c-sfsenorthamerica-awsbarbarian.snowflakecomputing.app |
| jdrew | BOM.TRUCK_CONFIG | ✅ Working | i4vf4-sfsenorthamerica-jdrew.snowflakecomputing.app |
