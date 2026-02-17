# Digital Twin Truck Configurator

![Digital Twin Truck Configurator](public/Digital_Twin_Truck_Config.png)

An AI-powered truck configuration system that validates engineering specifications in real-time using Snowflake Cortex. Built as a full-stack application running on Snowpark Container Services (SPCS).

**[Watch the Demo Video](https://youtu.be/hfI-tKUpI7U)**

![Architecture](docs/architecture.png)

## Overview

This demo showcases how Snowflake's AI capabilities can be integrated into a digital twin application for manufacturing. Users configure commercial trucks by selecting components, and the system:

1. **Validates configurations** against engineering specifications stored in PDFs
2. **Uses AI (Cortex Analyst + Cortex Search + Cortex Complete)** to understand spec requirements
3. **Provides intelligent fix recommendations** when configurations don't meet specs
4. **Runs entirely on Snowflake** - data, AI, and compute in one platform

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Snowpark Container Services                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                      SPCS Container                         ││
│  │  ┌─────────┐    ┌─────────┐    ┌─────────────────────┐     ││
│  │  │  nginx  │───▶│ Next.js │    │    Python Backend   │     ││
│  │  │  :8080  │    │  :3000  │    │        :8000        │     ││
│  │  └────┬────┘    └─────────┘    └──────────┬──────────┘     ││
│  │       │              │                     │                ││
│  │       │              │                     ▼                ││
│  │       │              │         ┌───────────────────┐        ││
│  │       │              │         │  Key-Pair Auth    │        ││
│  │       │              │         │  (Private Key     │        ││
│  │       │              │         │   from Secret)    │        ││
│  │       │              │         └─────────┬─────────┘        ││
│  └───────│──────────────│───────────────────│──────────────────┘│
│          │              │                   │                   │
└──────────│──────────────│───────────────────│───────────────────┘
           │              │                   │
           ▼              ▼                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Snowflake                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │   Tables     │  │    Cortex    │  │   Cortex Search      │   │
│  │  - BOM_TBL   │  │   Analyst    │  │  ENGINEERING_DOCS_   │   │
│  │  - MODEL_TBL │  │  (Complete)  │  │       SEARCH         │   │
│  │  - RULES     │  │              │  │                      │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Demo Flow

### 1. Navigate to the Heavy Haul Max HH-1200
Select the Heavy Haul Max HH-1200 truck model from the model selector.

### 2. Explore the BOM Hierarchy
Show the different levels of the BOM and how selections change price, weight, and performance metrics in real-time.

### 3. Use the Configuration Assistant
Open the Configuration Assistant chatbot. Tell it: **"Maximize safety and comfort while minimizing all other costs"**. Click **Apply** to let the AI optimize your configuration.

### 4. Select the 605 HP Engine Option
Navigate to **Engine > Engine Block > Power Rating > 605 HP / 2050 lb-ft Maximum**.

### 5. Upload Engineering Specification
Click the upload icon and upload the `605_HP_Engine_Requirements.pdf` document.

### 6. Verify Configuration
Once uploaded, click **Verify Configuration** to validate against the engineering specs.

### 7. Accept the Fixes
Review the validation results and accept the recommended fixes to make the configuration compliant.

### 8. Save Configuration
Click **Save Configuration**, click **Generate with AI** to create a description, give it a name, and click **Save**.

### 9. Create a Second Configuration
If you only have one saved configuration, pick another truck, make some changes, and save a second configuration.

### 10. Compare Configurations
Click the compare icon at the top of the page.

### 11. Side-by-Side Comparison
Compare two models next to each other to see differences in specifications, price, and performance.

### 12. View Configuration Report
Click the document icon at the top of one of the configurations to show the detailed configuration report.

## Key Features

| Feature | Technology | Description |
|---------|------------|-------------|
| Document Upload | PARSE_DOCUMENT + Cortex Complete | Parse PDFs and extract validation rules |
| Document Search | Cortex Search | Semantic search over engineering PDFs |
| Requirement Extraction | Cortex Complete | LLM extracts specs from document chunks |
| Configuration Optimization | Cortex Analyst | AI-powered configuration recommendations |
| Configuration Validation | Python + SQL | Rules engine checks component compatibility |
| Fix Recommendations | AI + Rules | Suggests compliant alternatives |
| Real-time Updates | React + SSE | Live configuration totals |

## Installation

### Prerequisites

- Snowflake account with **Cortex** and **SPCS** enabled
- `snow` CLI installed ([installation guide](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index))
- Docker installed
- A Snowflake user with `ACCOUNTADMIN` or equivalent privileges

### Quick Start

```bash
# Clone the repository
git clone https://github.com/azbarbarian2020/Digital_Twin_Truck_Configurator.git
cd Digital_Twin_Truck_Configurator

# Run the setup script
./setup.sh
```

The setup script will:
1. Prompt for your Snowflake CLI connection name
2. Auto-generate RSA key-pair for SPCS authentication
3. Create all required Snowflake objects
4. Build and deploy the application

### What setup.sh Creates

1. Database (BOM) and schema (TRUCK_CONFIG)
2. Tables (BOM_TBL, MODEL_TBL, VALIDATION_RULES, DOCUMENT_CHUNKS, SAVED_CONFIGURATIONS)
3. Stages with SNOWFLAKE_SSE encryption (required for PARSE_DOCUMENT)
4. Cortex Search Service for document search
5. Semantic View for Cortex Analyst
6. Compute pool and image repository
7. Network rule and external access integration
8. Secret for private key storage
9. SPCS service with the application

### Post-Setup: Load Data

After setup completes, load the demo data:

```bash
./load_data.sh
```

This loads:
- 5 truck models
- 253 configurable options
- 868 model-option mappings

## Configuration

### Environment Variables (in SPCS)

| Variable | Description |
|----------|-------------|
| `SNOWFLAKE_ACCOUNT` | Account identifier (e.g., SFSENORTHAMERICA-JDREW) |
| `SNOWFLAKE_HOST` | Full hostname for API calls |
| `SNOWFLAKE_USER` | Username for authentication |
| `SNOWFLAKE_DATABASE` | Database name (default: BOM) |
| `SNOWFLAKE_SCHEMA` | Schema name (default: TRUCK_CONFIG) |
| `SNOWFLAKE_WAREHOUSE` | Warehouse for Cortex operations |
| `SNOWFLAKE_PRIVATE_KEY` | Injected from secret |

### Network Rule (CRITICAL)

The network rule **must** allow your specific account hostname:

```sql
-- CORRECT
CREATE NETWORK RULE SNOWFLAKE_API_RULE
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('your-account.snowflakecomputing.com:443');

-- WRONG (will fail)
CREATE NETWORK RULE SNOWFLAKE_API_RULE
  VALUE_LIST = ('snowflake.com:443');
```

## Project Structure

```
├── app/                    # Next.js pages
├── backend/                # Python FastAPI backend
│   ├── main.py            # API endpoints
│   └── requirements.txt   # Python dependencies
├── components/            # React components
│   └── Configurator.tsx   # Main configurator UI
├── docs/                  # Engineering spec documents
├── lib/                   # Utility functions
├── public/                # Static assets
├── Dockerfile             # Multi-stage build
├── nginx.conf             # Reverse proxy config
├── setup.sh              # Deployment script
├── load_data.sh          # Data loading script
└── README.md             # This file
```

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Blank page | Wrong port in service spec | Ensure `port: 8080` in endpoints |
| "Could not connect to Snowflake" | Network rule wrong | Use account-specific hostname |
| Auth failures in SPCS | Secret format | Store base64 key without headers |
| Service won't start | Missing objects | Check compute pool, secret, integration exist |
| Document upload fails | Stage encryption | Ensure stage uses SNOWFLAKE_SSE encryption |

### Check Service Logs

```bash
snow spcs service logs TRUCK_CONFIGURATOR_SVC \
    --database BOM \
    --schema TRUCK_CONFIG \
    --connection your_connection
```

## Technologies Used

- **Frontend**: Next.js 15, React, Tailwind CSS
- **Backend**: Python, FastAPI, Uvicorn
- **AI/ML**: Snowflake Cortex (Complete, Search, Analyst)
- **Infrastructure**: Snowpark Container Services, Docker
- **Data**: Snowflake tables, stages, secrets

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Support

For issues or questions:
- Open a GitHub issue
- Watch the [Demo Video](https://youtu.be/hfI-tKUpI7U) for guidance
