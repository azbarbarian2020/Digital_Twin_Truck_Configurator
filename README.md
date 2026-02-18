<p align="center">
  <img src="public/Digital_Twin_Truck_Config.png" alt="Digital Twin Truck Configurator" width="600"/>
</p>

# Digital Twin Truck Configurator

[![Watch Demo](https://img.shields.io/badge/Watch%20Demo-YouTube-red?logo=youtube)](https://youtu.be/hfI-tKUpI7U)

An AI-powered truck configuration application built on Snowflake, demonstrating **Snowflake Cortex** capabilities including:
- **Cortex Complete** - Natural language chat assistant and rule extraction from engineering documents
- **Cortex Search** - Semantic search over engineering specification PDFs
- **Cortex Analyst** - Natural language to SQL for configuration optimization
- **Cortex Agent** - Orchestrated AI assistant with tool access
- **SPCS (Snowpark Container Services)** - Containerized Next.js application

## What This Demo Shows

This proof-of-concept demonstrates how Snowflake's unified data platform can revolutionize complex product configuration. Unlike traditional configurators that rely on rigid rule engines, this application uses AI to:

1. **Understand Engineering Specifications** - Upload PDF documents and watch AI extract validation rules
2. **Match Components by Specs, Not Names** - AI compares actual technical specifications (horsepower, torque, weight ratings)
3. **Provide Intelligent Recommendations** - Natural language requests like "Maximize comfort under $100k" translate to optimal configurations
4. **Validate Configurations Automatically** - AI reads specs, identifies mismatches, and proposes fixes

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        User Interface (Next.js)                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐│
│   │ Configurator│  │   Compare   │  │  Chat/AI    │  │  Validate  ││
│   │    Panel    │  │   Configs   │  │  Assistant  │  │   Config   ││
│   └─────────────┘  └─────────────┘  └─────────────┘  └────────────┘│
└───────────────────────────────────────────┬─────────────────────────┘
                                            │
┌───────────────────────────────────────────┼─────────────────────────┐
│                    Snowflake Backend      │                          │
│  ┌────────────────────────────────────────┼────────────────────────┐│
│  │         SPCS Container Service         │                        ││
│  │  ┌─────────────┐  ┌─────────────────┐  │  ┌──────────────────┐ ││
│  │  │ Next.js App │  │  FastAPI Backend│──┼──│  Cortex Services │ ││
│  │  │  (Frontend) │  │  (Python APIs)  │  │  │  (via REST API)  │ ││
│  │  └─────────────┘  └─────────────────┘  │  └──────────────────┘ ││
│  │        │                  │            │           │           ││
│  │        └──────nginx───────┘            │           │           ││
│  └────────────────────────────────────────┼───────────────────────┘│
│                                           │                          │
│  ┌────────────────────────────────────────┴────────────────────────┐│
│  │                      Cortex AI Services                          ││
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐ ││
│  │  │  Cortex Search  │  │ Cortex Analyst  │  │  Cortex Complete │ ││
│  │  │  (Doc Search)   │  │  (Text-to-SQL)  │  │  (Rule Extract)  │ ││
│  │  └─────────────────┘  └─────────────────┘  └──────────────────┘ ││
│  │  ┌─────────────────┐  ┌─────────────────┐                       ││
│  │  │  Cortex Agent   │  │ PARSE_DOCUMENT  │                       ││
│  │  │  (Chat + Tools) │  │  (PDF Extract)  │                       ││
│  │  └─────────────────┘  └─────────────────┘                       ││
│  └──────────────────────────────────────────────────────────────────┘│
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │                         Data Layer                                ││
│  │  ┌──────────┐  ┌───────────┐  ┌──────────────┐  ┌─────────────┐ ││
│  │  │ BOM_TBL  │  │ MODEL_TBL │  │ TRUCK_OPTIONS│  │SAVED_CONFIGS│ ││
│  │  │(253 opts)│  │ (5 models)│  │  (868 maps)  │  │             │ ││
│  │  └──────────┘  └───────────┘  └──────────────┘  └─────────────┘ ││
│  │  ┌────────────────┐  ┌─────────────────────┐  ┌──────────────┐ ││
│  │  │VALIDATION_RULES│  │ENGINEERING_DOCS_    │  │ CHAT_HISTORY │ ││
│  │  │                │  │       CHUNKED       │  │              │ ││
│  │  └────────────────┘  └─────────────────────┘  └──────────────┘ ││
│  └──────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
```

### Container Architecture

The SPCS container runs three services orchestrated by supervisor:

| Service | Port | Description |
|---------|------|-------------|
| **nginx** | 8080 (external) | Reverse proxy routing `/api/*` to backend, all else to frontend |
| **FastAPI Backend** | 8000 | Python APIs for Snowflake/Cortex operations |
| **Next.js Frontend** | 3000 | React UI with TypeScript |

## Demo Flow (2-3 minutes)

### 1. Model Selection (20s)
- View 5 truck models: Regional Hauler, Fleet Workhorse, Cross Country Pro, Heavy Haul Max, Executive Hauler
- Use "Find My Model" wizard - AI recommends best match with percentage score and reasons

### 2. BOM Navigation (25s)
- Navigate hierarchical Bill of Materials: System → Subsystem → Component Group
- View pricing, weight, and performance ratings (Safety, Comfort, Power, Economy)
- Real-time summary shows total price, weight, and performance vs default

### 3. Configuration Assistant (30s)
- Return to main screen and select the **Heavy Haul Max HH-1200** model
- Open AI chat and ask: *"Maximize comfort and safety while minimizing all other costs"*
- AI analyzes all 253 options and recommends optimal configuration
- One-click "Apply" updates configuration instantly

### 4. Engineering Spec Validation (45s) - **KEY FEATURE**
- Select **Engine > Engine Block > Power Rating > 605 HP / 2050 lb-ft Maximum**
- Upload the `605_HP_Engine_Requirements.pdf`
- AI extracts validation rules from document text
- Click "Verify Configuration" - AI compares spec requirements against selected components
- View configuration violations
- Click "Apply Fix Plan" to auto-resolve issues

### 5. Save & Compare (25s)
- Save configuration with AI-generated description
- Compare multiple builds side-by-side
- Export full configuration report to PDF

## Quick Start Deployment

### Prerequisites

- **Snowflake Account** with ACCOUNTADMIN role
- **Docker** installed and running
- **Snowflake CLI** (`snow`) installed: `pip install snowflake-cli`
- **Git** to clone the repository

### One-Command Deployment

```bash
# 1. Clone the repository
git clone https://github.com/azbarbarian2020/Digital_Twin_Truck_Configurator.git
cd Digital_Twin_Truck_Configurator

# 2. Run the automated setup script
./setup.sh
```

### What setup.sh Does

The setup script automates the complete deployment:

| Step | What It Creates |
|------|-----------------|
| **1. Connection** | Configures Snowflake CLI connection (uses existing or creates new with browser auth) |
| **2. Infrastructure** | Creates DATABASE, SCHEMA, WAREHOUSE, COMPUTE_POOL, IMAGE_REPOSITORY, STAGES |
| **3. Tables** | Creates BOM_TBL, MODEL_TBL, TRUCK_OPTIONS, VALIDATION_RULES, ENGINEERING_DOCS_CHUNKED, SAVED_CONFIGS, CHAT_HISTORY |
| **4. Data** | Loads 253 BOM options, 5 truck models, 868 option mappings (all with SPECS) |
| **5. Cortex Search** | Creates ENGINEERING_DOCS_SEARCH service for semantic document search |
| **6. Docker** | Builds multi-stage Docker image and pushes to Snowflake image repository |
| **7. SPCS Service** | Deploys container service with OAuth authentication |
| **8. Output** | Displays endpoint URL for accessing the application |

### Setup Script Options

```bash
./setup.sh                    # Interactive - prompts for connection
./setup.sh -c my_connection   # Use existing connection named "my_connection"
./setup.sh -h                 # Show help
```

### Expected Output

```
========================================
  Digital Twin Truck Configurator Setup
========================================

Checking prerequisites...
✓ Docker is running
✓ snow CLI is installed

Step 1: Connection Setup
Using connection: awsbarbarian_CoCo

Step 2: Creating Infrastructure...
✓ Database BOM created
✓ Schema BOM4 created
✓ Warehouse DEMO_WH created
✓ Compute pool TRUCK_CONFIG_BOM4_POOL created
✓ Image repository created

Step 3: Creating Tables...
✓ All tables created

Step 4: Loading Data...
✓ BOM_TBL loaded (253 rows)
✓ MODEL_TBL loaded (5 rows)
✓ TRUCK_OPTIONS loaded (868 rows)

Step 5: Setting up Cortex Search...
✓ ENGINEERING_DOCS_SEARCH service created

Step 6: Building Docker Image...
✓ Image built and pushed

Step 7: Deploying SPCS Service...
✓ Service TRUCK_CONFIGURATOR_SVC deployed

========================================
  Deployment Complete!
========================================

Application URL: https://xxxxx-sfsenorthamerica-your-account.snowflakecomputing.app

Open this URL in your browser to access the application.
```

## Manual Deployment (Alternative)

If you prefer step-by-step deployment, run the SQL scripts in order:

```bash
cd deployment/scripts
snow sql -f 01_setup_infrastructure.sql -c your_connection
snow sql -f 02_create_tables.sql -c your_connection
snow sql -f 03_load_data.sql -c your_connection
snow sql -f 04_cortex_services.sql -c your_connection
```

Then build and deploy Docker:

```bash
cd ../..
docker build -t truck-configurator .
docker tag truck-configurator <your-image-repo>/truck_configurator:latest
docker push <your-image-repo>/truck_configurator:latest
snow spcs service create TRUCK_CONFIGURATOR_SVC --spec-path spec.yaml -c your_connection
```

## Key Features

### 1. Truck Configuration
- Select from 5 truck models
- Configure 41 component groups across 253 options
- Real-time cost and weight calculations
- Performance category scoring (Safety, Comfort, Power, Economy)

### 2. AI-Powered Validation
- Upload engineering specification PDFs
- **Cortex PARSE_DOCUMENT** extracts text from PDFs
- **Cortex Search** finds relevant document sections
- **Cortex Complete** extracts validation rules with specific thresholds
- Configuration validated against extracted rules instantly

### 3. Natural Language Optimization
- Ask questions like "Optimize for fuel economy under $90,000"
- **Cortex Analyst** via Semantic View converts to SQL
- Returns optimized configurations matching criteria

### 4. Chat Assistant
- **Cortex Agent** with tool access for configuration help
- Context-aware recommendations based on current selections
- Answers questions about component specifications

## Engineering Specification Documents

Two sample engineering specifications are included:

| Document | Purpose |
|----------|---------|
| `deployment/docs/ENG-605-MAX-Technical-Specification.pdf` | Validates turbocharger, radiator, transmission for 605 HP engine |
| `deployment/docs/Elite_Air_Ride_Suspension_Requirements.pdf` | Validates frame rails, axle ratings for Elite Air-Ride suspension |

### Example Validation Flow

1. Navigate to **Engine > Engine Block > Power Rating**
2. Select **605 HP / 2050 lb-ft Maximum** option
3. Click **Attach Engineering Doc** icon
4. Upload `ENG-605-MAX-Technical-Specification.pdf`
5. AI extracts rules:
   - Turbocharger: `boost_psi >= 40`, `max_hp_supported >= 605`
   - Radiator: `cooling_capacity_btu >= 450000`
   - Transmission: `torque_rating_lb_ft >= 2050`
6. Click **Verify Configuration** to validate

## Data Model

| Table | Description | Rows |
|-------|-------------|------|
| **BOM_TBL** | Bill of Materials with SPECS (JSON technical specifications) | 253 |
| **MODEL_TBL** | Truck model definitions | 5 |
| **TRUCK_OPTIONS** | Maps options to models with pricing | 868 |
| **VALIDATION_RULES** | AI-extracted rules from engineering docs | Dynamic |
| **ENGINEERING_DOCS_CHUNKED** | Searchable document chunks for RAG | Dynamic |
| **SAVED_CONFIGS** | User-saved configurations | Dynamic |
| **CHAT_HISTORY** | Chat conversation history | Dynamic |

### SPECS Column Example

Each BOM option has technical specifications stored as JSON:

```json
{
  "boost_psi": 48,
  "max_hp_supported": 650,
  "turbo_type": "twin-vgt"
}
```

## API Routes

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/bom` | GET | Fetch BOM tree for model |
| `/api/configs` | GET/POST/DELETE | Manage saved configurations |
| `/api/validate` | POST | Validate configuration against rules |
| `/api/engineering-docs` | GET/DELETE | List/delete engineering documents |
| `/api/engineering-docs/upload` | POST | Upload and process specification PDF |
| `/api/chat` | POST | Chat with AI assistant |
| `/api/analyst` | POST | Cortex Analyst optimization queries |

## Technology Stack

- **Frontend**: Next.js 14, React, TypeScript, TailwindCSS
- **Backend**: FastAPI (Python)
- **Database**: Snowflake
- **AI Services**: Snowflake Cortex (Complete, Search, Analyst, Agent, PARSE_DOCUMENT)
- **Deployment**: Snowpark Container Services (SPCS)
- **Authentication**: Key-pair authentication via Snowflake secrets
- **Container Orchestration**: Supervisor (nginx + uvicorn + node)

## Project Structure

```
truck-configurator/
├── app/                    # Next.js frontend
│   ├── api/               # API routes (proxied through nginx)
│   ├── layout.tsx         # Root layout
│   └── page.tsx           # Main page
├── backend/               # FastAPI backend
│   └── main.py           # Python API endpoints
├── components/            # React components
│   ├── Configurator.tsx  # Main configurator
│   ├── Compare.tsx       # Config comparison
│   ├── ChatPanel.tsx     # AI chat assistant
│   └── ...
├── deployment/
│   ├── data/             # JSON data files for BOM, models, options
│   ├── docs/             # Sample engineering spec PDFs
│   └── scripts/          # SQL deployment scripts
├── docs/                  # Documentation and requirements
├── setup.sh               # Automated deployment script (run from root)
├── Dockerfile             # Multi-stage build (includes supervisord config)
├── nginx.conf            # Reverse proxy config
├── package.json
└── .gitignore
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Service not starting | Check compute pool has available nodes: `SHOW COMPUTE POOLS` |
| 401 Unauthorized | Ensure you're accessing via the SPCS OAuth URL, not localhost |
| Document upload fails | Verify ENGINEERING_DOCS_STAGE exists and is accessible |
| Validation not working | Check VALIDATION_RULES table has rules for the uploaded document |

## License

MIT License - see LICENSE file for details.

## Support

For questions or issues, please open a GitHub issue at:
https://github.com/azbarbarian2020/Digital_Twin_Truck_Configurator
