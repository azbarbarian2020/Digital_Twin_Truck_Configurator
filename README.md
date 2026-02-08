# Digital Twin Truck Configurator

An interactive truck configuration demo built on Snowflake featuring **Cortex Analyst** for natural language optimization queries, **configuration validation against unstructured engineering specification documents**, and **Snowpark Container Services (SPCS)** for hosting the full-stack application.

> **Platform Requirement: AWS Snowflake Accounts Only**
> 
> This demo currently only works fully on **AWS-hosted Snowflake accounts**. Azure and GCP accounts have authentication limitations that prevent the Cortex Analyst REST API from working inside SPCS containers.
>
> **Why?** The Cortex Analyst API requires REST API calls from inside SPCS. On AWS, Personal Access Tokens (PAT) work for this. On Azure, PAT authentication is blocked (error 395090) and OAuth is required, which needs additional Azure AD configuration not included in this setup.
>
> **To check your cloud platform:**
> ```sql
> SELECT CURRENT_REGION();
> -- AWS regions start with: AWS_US_WEST_2, AWS_US_EAST_1, etc.
> -- Azure regions start with: AZURE_WESTUS2, AZURE_EASTUS2, etc.
> ```

![Demo Screenshot](docs/screenshot.png)

## Overview

This demo showcases a **Digital Twin** approach to truck configuration where:

- **Configure Trucks Interactively** - Select components across 40+ component groups with real-time cost and weight calculations
- **AI-Powered Configuration Assistant** - Powered by Cortex Analyst, ask natural language questions like:
  - "Maximize safety and comfort while minimizing all other costs"
  - "What's the best hauling configuration for regional delivery?"
  - "Show me premium options for the Heavy Haul truck"
- **Validate Configurations Against Engineering Specifications** - Upload unstructured PDF engineering documents (e.g., engine specifications, axle requirements) and validate that your truck configuration meets all documented requirements. The system uses PARSE_DOCUMENT to extract specifications and compares them against selected component attributes.
- **Save and Compare Configurations** - Store configurations and compare them side-by-side
- **RAG-Based Document Search** - Ask questions about uploaded engineering documents using Cortex Search

## Key Features

| Feature | Technology | Description |
|---------|------------|-------------|
| Configuration Assistant | Cortex Analyst + Semantic View | Natural language to SQL for optimization queries |
| Specification Validation | PARSE_DOCUMENT + CORTEX_LLM | Extract requirements from PDFs and validate against component specs |
| Document Search | Cortex Search | RAG-based Q&A over uploaded engineering documents |
| Real-time Updates | React + FastAPI | Instant cost/weight calculations as you configure |
| Configuration Compare | Snowflake Tables | Side-by-side comparison of saved configurations |

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                       SPCS Service (TRUCK_CONFIGURATOR_SVC)                  │
│  ┌───────────┐   ┌───────────┐   ┌────────────────────────────────────────┐ │
│  │   nginx   │───│  Next.js  │   │           FastAPI Backend              │ │
│  │  :8080    │   │   :3000   │   │              :8000                     │ │
│  └───────────┘   └───────────┘   └────────────────────────────────────────┘ │
│         │              │                    │                  │             │
│         │              │                    ▼                  ▼             │
│         │              │    ┌─────────────────────┐  ┌──────────────────┐   │
│         │              │    │ Cortex Analyst API  │  │ Cortex Search    │   │
│         │              │    │ (Semantic View)     │  │ (Engineering     │   │
│         │              │    │                     │  │  Docs RAG)       │   │
│         │              │    └─────────────────────┘  └──────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
                                      │                        │
                                      ▼                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Snowflake Data Layer                                │
│                                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────┐  ┌──────────────────┐  │
│  │  MODEL_TBL  │  │   BOM_TBL   │  │ TRUCK_OPTIONS │  │ ENGINEERING_DOCS │  │
│  │  (5 models) │  │ (253 parts) │  │ (868 mappings)│  │  (uploaded PDFs) │  │
│  └─────────────┘  └─────────────┘  └───────────────┘  └──────────────────┘  │
│         │               │                 │                    │             │
│         ▼               ▼                 ▼                    ▼             │
│  ┌─────────────────────────────────┐           ┌─────────────────────────┐  │
│  │   TRUCK_CONFIG_ANALYST_V2       │           │ ENGINEERING_DOCS_SEARCH │  │
│  │      (Semantic View)            │           │   (Cortex Search Svc)   │  │
│  │  - VQRs for optimization        │           │   - Document chunks     │  │
│  │  - Custom SQL instructions      │           │   - Vector embeddings   │  │
│  └─────────────────────────────────┘           └─────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Snowflake account** on AWS with ACCOUNTADMIN privileges (or equivalent)
- **Docker Desktop** installed and running
- **Snowflake CLI** (`snow`) installed: `pip install snowflake-cli`
- **OpenSSL** for key-pair generation (included on macOS/Linux)

## Quick Start - Automated Setup

The easiest way to deploy is using the automated setup script:

```bash
# Clone the repository
git clone https://github.com/your-org/Digital_Twin_Truck_Configurator.git
cd Digital_Twin_Truck_Configurator

# Run the automated setup
./setup.sh
```

The script will:
1. Prompt for your Snowflake configuration (account, user, warehouse)
2. Create database, schema, compute pool, and image repository
3. Set up external access integration for Cortex Analyst REST API
4. Generate key-pair authentication (required for file uploads in SPCS)
5. Create PAT secret for Cortex Analyst
6. Load all data (5 truck models, 253 BOM options, 868 option mappings)
7. Create the semantic view with VQRs
8. Create stage and Cortex Search service for engineering documents
9. Build and push the Docker image
10. Deploy the SPCS service with correct secrets configuration

**Total time: ~10-15 minutes**

---

## Demo Assets

Sample engineering specification documents are included for demonstrating the validation feature:

```
demo_assets/
├── 605_HP_Engine_Requirements.pdf    ← Primary demo document
└── README.md                         ← Demo instructions
```

**For the demo**: Copy `demo_assets/605_HP_Engine_Requirements.pdf` to your desktop, then upload it through the app's "Engineering Docs" tab.

---

## Manual Setup (Alternative)

If you prefer to run each step manually, see [MANUAL_SETUP.md](MANUAL_SETUP.md).

---

## Configuration Reference

### Account-Specific Values

These values are set automatically by `setup.sh` or must be configured in `scripts/05_service.sql`:

| Variable | Description | Example |
|----------|-------------|---------|
| `SNOWFLAKE_ACCOUNT` | Account locator | `MYORG-MYACCOUNT` |
| `SNOWFLAKE_HOST` | Full hostname | `myorg-myaccount.snowflakecomputing.com` |
| `SNOWFLAKE_USER` | Service user | `ADMIN` |
| `SNOWFLAKE_WAREHOUSE` | Query warehouse | `COMPUTE_WH` |
| `SNOWFLAKE_DATABASE` | Database name | `BOM` |
| `SNOWFLAKE_SCHEMA` | Schema name | `TRUCK_CONFIG` |

### Required Secrets

The service requires two secrets for proper operation:

| Secret | Purpose | Why Required |
|--------|---------|--------------|
| `SNOWFLAKE_PAT_SECRET` | Cortex Analyst REST API | SPCS OAuth tokens only work for SQL connections, not REST APIs |
| `SNOWFLAKE_PRIVATE_KEY_SECRET` | File uploads (PUT commands) | PAT auth doesn't support PUT; key-pair auth required |

### Service Spec Secrets Syntax

**CRITICAL**: The YAML syntax for secrets must be exactly:

```yaml
secrets:
  - snowflakeSecret:
      objectName: DATABASE.SCHEMA.SECRET_NAME
    secretKeyRef: secret_string
    envVarName: ENV_VAR_NAME
```

**NOT** this (will fail with "Cannot deserialize value"):
```yaml
secrets:
  - snowflakeSecret: DATABASE.SCHEMA.SECRET_NAME  # WRONG!
    envVarName: ENV_VAR_NAME
```

---

## Troubleshooting

### Service Won't Start

```sql
-- Check status
CALL SYSTEM$GET_SERVICE_STATUS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC');

-- Check logs
CALL SYSTEM$GET_SERVICE_LOGS('BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC', 0, 'truck-configurator', 100);
```

### Configuration Assistant Shows "Connection Timed Out"

**Cause**: Missing `EXTERNAL_ACCESS_INTEGRATIONS` - the service can't make outbound REST API calls.

**Fix**:
```sql
-- Create network rule and integration
CREATE OR REPLACE NETWORK RULE your_db.your_schema.CORTEX_API_RULE
    TYPE = HOST_PORT MODE = EGRESS
    VALUE_LIST = ('*.snowflakecomputing.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION TRUCK_CONFIG_EXTERNAL_ACCESS
    ALLOWED_NETWORK_RULES = (your_db.your_schema.CORTEX_API_RULE)
    ENABLED = TRUE;

-- Add to service
ALTER SERVICE your_db.your_schema.TRUCK_CONFIGURATOR_SVC 
    SET EXTERNAL_ACCESS_INTEGRATIONS = (TRUCK_CONFIG_EXTERNAL_ACCESS);
```

Note: `networkPolicyConfig.allowInternetEgress: true` alone is NOT sufficient for REST APIs.

### PDF Upload Shows "Failed to Extract Text"

**Cause**: Frontend using PAT auth which doesn't support PUT commands to stages.

**Fix**: The backend handles uploads using key-pair authentication. Ensure `SNOWFLAKE_PRIVATE_KEY_SECRET` is properly configured.

### Delete Configuration Not Working

**Cause**: Frontend route format mismatch (path params vs query params).

**Fix**: Ensure `app/api/configs/[configId]/route.ts` exists and proxies to backend.

### Empty Tooltips on Components

**Cause**: `SPECS` column in `BOM_TBL` is empty.

**Fix**: Verify data was loaded correctly:
```sql
SELECT COUNT(*) FROM BOM.TRUCK_CONFIG.BOM_TBL WHERE SPECS IS NOT NULL;
-- Should return 253
```

### "unauthorized" on Docker Push

```bash
# Re-login to registry
snow spcs image-registry login --connection your_connection
```

### Service Spec "Cannot deserialize value"

**Cause**: Wrong YAML syntax for secrets (see Configuration Reference above).

---

## Updating the Service

**IMPORTANT:** Never DROP and CREATE the service - use ALTER to preserve the endpoint URL.

```bash
# Build new version
docker buildx build --platform linux/amd64 -t truck-config:v2 docker/
docker tag truck-config:v2 <REGISTRY>/truck-config:v2
docker push <REGISTRY>/truck-config:v2

# Update service image (use ALTER, not DROP/CREATE)
snow sql -q "ALTER SERVICE BOM.TRUCK_CONFIG.TRUCK_CONFIGURATOR_SVC FROM SPECIFICATION \$\$
spec:
  containers:
    - name: truck-configurator
      image: <REGISTRY>/truck-config:v2
      ...
\$\$"
```

---

## Demo Scenarios

### 1. Basic Configuration
Select a truck model, explore options across 40+ component groups, and watch real-time cost/weight updates.

### 2. AI-Powered Optimization
Open the **Configuration Assistant** panel and ask:
- "Maximize hauling for this truck"
- "What's the best safety configuration?"
- "Minimize all costs while keeping premium comfort"

Click **"Apply"** to automatically configure the truck with AI recommendations.

### 3. Validate Against Engineering Specifications

This is the key differentiating feature:

1. **Upload a specification document**:
   - Go to **Engineering Docs** tab
   - Click **Upload Document**
   - Select `demo_assets/605_HP_Engine_Requirements.pdf`

2. **Link to components**:
   - The system auto-detects which components the document applies to
   - Or manually link to specific options

3. **Validate your configuration**:
   - Click **Verify Configuration**
   - The system extracts requirements from the PDF using PARSE_DOCUMENT
   - Compares against your selected component's specifications
   - Shows pass/fail for each requirement with recommendations

4. **See validation results**:
   - Green checkmarks for passing requirements
   - Red X for failures with suggested alternatives
   - AI-powered recommendations for compliant components

### 4. Document Q&A
After uploading documents, ask questions in the Configuration Assistant:
- "What are the cooling requirements for the 605 HP engine?"
- "Which transmission is compatible with heavy haul configurations?"

### 5. Compare Configurations
- Save multiple configurations
- Use **Compare** tab for side-by-side analysis of cost, weight, and components

---

## File Structure

```
Digital_Twin_Truck_Configurator/
├── README.md                       # This file
├── setup.sh                        # Automated setup script
├── TROUBLESHOOTING.md              # Detailed troubleshooting guide
├── demo_assets/
│   ├── 605_HP_Engine_Requirements.pdf  # Demo PDF for validation
│   └── README.md                   # Demo instructions
├── scripts/
│   ├── 01_infrastructure.sql       # DB, schema, compute pool, repo
│   ├── 02_data.sql                 # Tables and model data
│   ├── 02b_bom_data.sql            # Full BOM data (253 rows)
│   ├── 02c_truck_options.sql       # Model-option mappings (868 rows)
│   ├── 03_semantic_view.sql        # Semantic view with VQRs
│   ├── 04_additional_objects.sql   # Stages, Cortex Search
│   └── 05_service.sql              # SPCS service template
├── docker/
│   ├── Dockerfile                  # Multi-stage build
│   ├── backend/                    # FastAPI backend
│   │   └── main.py                 # API endpoints
│   ├── app/                        # Next.js frontend
│   ├── components/                 # React components
│   └── public/docs/                # Sample PDFs
└── docs/
    └── screenshot.png
```

---

## Key Implementation Details

### Authentication in SPCS

SPCS provides OAuth tokens automatically, but these have limitations:

| Auth Type | Works For | Doesn't Work For |
|-----------|-----------|------------------|
| SPCS OAuth | SQL connections (snowflake-connector) | REST APIs |
| PAT | REST APIs (Cortex Analyst) | PUT commands to stages |
| Key-Pair | SQL + PUT commands | N/A (most versatile) |

This is why the app uses **both** PAT (for Cortex Analyst REST API) and Key-Pair (for file uploads).

### Stage Encryption for PARSE_DOCUMENT

The engineering docs stage must use specific encryption:
```sql
CREATE STAGE ... ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
-- Or: DIRECTORY = (ENABLE = TRUE) with default encryption
```

Standard encrypted stages (`SNOWFLAKE_FULL`) don't work with PARSE_DOCUMENT.

---

## License

Internal Snowflake demo - not for distribution.

## Credits

Built by the Snowflake Solutions Engineering team demonstrating:
- Cortex Analyst semantic views with VQRs
- PARSE_DOCUMENT for unstructured data extraction
- Cortex Search for RAG
- Snowpark Container Services
- React/Next.js on Snowflake
