# Digital Twin Truck Configurator

An AI-powered truck configuration system that validates engineering specifications in real-time using Snowflake Cortex. Built as a full-stack application running on Snowpark Container Services (SPCS).

![Architecture](docs/architecture.png)

## Overview

This demo showcases how Snowflake's AI capabilities can be integrated into a digital twin application for manufacturing. Users configure commercial trucks by selecting components, and the system:

1. **Validates configurations** against engineering specifications stored in PDFs
2. **Uses AI (Cortex Analyst + Cortex Search)** to understand spec requirements
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

### 1. Select a Truck Model
Choose from 5 truck models ranging from regional delivery to premium heavy-haul.

### 2. Configure Components
Select options across multiple systems:
- **Powertrain**: Engine, transmission, turbocharger
- **Chassis**: Frame, suspension, brakes
- **Cab**: Interior, climate, sleeper options
- **Safety**: ADAS, stability control, lighting

### 3. Verify Configuration
Click "Verify Configuration" to validate against engineering specs. The system will:
- Search engineering documents using **Cortex Search**
- Extract requirements using **Cortex Complete (LLM)**
- Compare selected components against requirements
- Show grouped issues with intelligent fix recommendations

### 4. Apply Recommended Fixes
If issues are found, the system provides a one-click fix plan that swaps non-compliant components with compliant alternatives.

## Key Features

| Feature | Technology | Description |
|---------|------------|-------------|
| Document Search | Cortex Search | Semantic search over engineering PDFs |
| Requirement Extraction | Cortex Complete | LLM extracts specs from document chunks |
| Configuration Validation | Python + SQL | Rules engine checks component compatibility |
| Fix Recommendations | AI + Rules | Suggests compliant alternatives |
| Real-time Updates | React + WebSocket | Live configuration totals |

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

The setup script will prompt you for:
1. **Connection name**: Your Snowflake CLI connection
2. **Private key**: For key-pair authentication from SPCS

### What setup.sh Does

1. Creates database, schema, and tables
2. Creates compute pool and image repository
3. Creates network rule (for Cortex API access)
4. Creates external access integration
5. Creates secret for private key
6. Builds and pushes Docker image
7. Creates SPCS service
8. Outputs the endpoint URL

### Post-Setup: Load Data

After setup completes, load the demo data:

```bash
export CONNECTION_NAME=your_connection
./load_data.sh
```

This loads:
- 5 truck models
- 253 configurable options
- 868 model-option mappings
- Engineering validation rules

### Upload Engineering Documents

Upload PDFs to the stage for Cortex Search:

```bash
snow stage copy docs/605_HP_Engine_Requirements.pdf \
    @BOM.TRUCK_CONFIG.ENGINEERING_DOCS_STAGE \
    --connection your_connection
```

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
- Contact: [your-email]
