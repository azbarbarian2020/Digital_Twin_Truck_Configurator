# Digital Twin Truck Configurator - Technical Documentation

**Last Updated:** 2026-02-18
**Current Version:** v74
**Status:** Production Ready

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
| Component | Technology |
|-----------|------------|
| Frontend | Next.js 15.5.11 (React) |
| Backend | FastAPI (Python 3.11) |
| Database | Snowflake |
| AI/ML | Snowflake Cortex (Analyst, Complete, Search) |
| Deployment | Snowpark Container Services (SPCS) |
| Proxy | Nginx (routes between frontend/backend) |

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

### Service Specification
```yaml
spec:
  containers:
  - name: "truck-configurator"
    image: "<registry>/truck-configurator:v74"
    env:
      SNOWFLAKE_WAREHOUSE: "DEMO_WH"
      SNOWFLAKE_DATABASE: "BOM"
      SNOWFLAKE_SCHEMA: "TRUCK_CONFIG"
      SNOWFLAKE_ACCOUNT: "<account-identifier>"
      SNOWFLAKE_HOST: "<account>.snowflakecomputing.com"
      SNOWFLAKE_USER: "<username>"
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
  VALUE_LIST = ('<account>.snowflakecomputing.com:443');

CREATE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
  ALLOWED_NETWORK_RULES = (SNOWFLAKE_API_RULE)
  ENABLED = TRUE;
```

---

## 4. API Endpoints

### Models & Configuration
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/models` | GET | List all truck models |
| `/api/options/{model_id}` | GET | Get options for a model |
| `/api/config/save` | POST | Save configuration |
| `/api/config/list` | GET | List saved configs |
| `/api/config/load/{id}` | GET | Load specific config |

### AI/Optimization
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chat` | POST | AI chat assistant |
| `/api/optimize` | POST | Natural language optimization |
| `/api/analyst` | POST | Cortex Analyst queries |

### Document Management
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/documents/upload` | POST | Upload specification PDF |
| `/api/documents/list` | GET | List uploaded documents |
| `/api/documents/download/{id}` | GET | Get presigned download URL |
| `/api/documents/delete/{id}` | DELETE | Delete document |

### Validation
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/validate` | POST | Validate config against rules |
| `/api/rules/{doc_id}` | GET | Get rules for a document |
| `/api/fix-plan` | POST | Generate fix plan for violations |

---

## 5. Key Code Patterns

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
            ...
        )
    # Priority 2: SPCS OAuth token (fallback)
    elif token:
        _connection = snowflake.connector.connect(
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

## 6. Deployment

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

## 7. Troubleshooting

### Check Service Status
```sql
SELECT SYSTEM$GET_SERVICE_STATUS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC');
```

### Check Service Logs
```sql
CALL SYSTEM$GET_SERVICE_LOGS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);
```

### Common Issues
| Symptom | Cause | Fix |
|---------|-------|-----|
| "Client is unauthorized to use Snowpark Container Services OAuth token" | Missing key-pair auth | Add secrets block to service spec |
| "Could not connect to Snowflake backend" | Wrong network rule | Network rule must include account host |
| 500 on /api/models | Backend can't connect to Snowflake | Check auth, check logs |
| Upload hangs | Sync search refresh timeout | Remove ALTER CORTEX SEARCH SERVICE REFRESH |

---

## 8. File Structure

```
truck-configurator/
├── backend/
│   ├── main.py              # FastAPI backend (all API endpoints)
│   └── requirements.txt
├── components/
│   ├── Configurator.tsx     # Main configurator UI
│   ├── ChatPanel.tsx        # AI assistant chat
│   └── ...
├── app/
│   ├── page.tsx             # Main page
│   └── api/                 # Next.js API routes
├── docs/
│   ├── 605_HP_Engine_Requirements.md
│   ├── Heavy_Haul_Chassis_Requirements.md
│   └── DOCUMENTATION.md     # This file
├── public/
│   └── Digital_Twin_Truck_Config.png
├── deployment/
│   └── setup.sh             # Automated deployment script
├── Dockerfile
├── nginx.conf
└── README.md
```

---

## 9. Snowflake Objects

```
BOM.TRUCK_CONFIG/
├── Tables: MODEL_TBL, BOM_TBL, TRUCK_OPTIONS, SAVED_CONFIGS
├── Tables: ENGINEERING_DOCS_CHUNKED, VALIDATION_RULES
├── Stage: ENGINEERING_DOCS_STAGE
├── Search Service: ENGINEERING_DOCS_SEARCH
├── Semantic View: TRUCK_CONFIG_ANALYST_V2
├── Secret: SNOWFLAKE_PRIVATE_KEY_SECRET
├── Image Repository: TRUCK_CONFIG_REPO
├── Compute Pool: TRUCK_CONFIG_POOL
└── Service: TRUCK_CONFIGURATOR_SVC
```

---

## 10. Lessons Learned

### SPCS Authentication
- SPCS OAuth alone is unreliable; always use key-pair auth via secrets
- Must include SNOWFLAKE_USER env var for key-pair auth to work
- Secrets must use `objectName:` nested under `snowflakeSecret:`

### Document Operations
- Sync search refresh (`ALTER CORTEX SEARCH SERVICE REFRESH`) causes timeouts
- Use `target_lag` auto-refresh instead
- GET command doesn't work in SPCS; use presigned URLs

### Service Deployment
- `CREATE OR REPLACE SERVICE` is NOT supported in SPCS
- Must use `DROP SERVICE IF EXISTS` followed by `CREATE SERVICE`
