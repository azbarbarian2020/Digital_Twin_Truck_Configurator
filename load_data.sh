#!/bin/bash
set -e

echo "========================================="
echo "  Load Demo Data"
echo "========================================="

# Configuration
DATABASE="BOM"
SCHEMA="TRUCK_CONFIG"
WAREHOUSE="DEMO_WH"

if [[ -z "$CONNECTION_NAME" ]]; then
    read -p "Enter connection name: " CONNECTION_NAME
fi

run_sql() {
    snow sql -q "$1" --connection "$CONNECTION_NAME"
}

run_sql_file() {
    snow sql -f "$1" --connection "$CONNECTION_NAME"
}

echo "Using connection: $CONNECTION_NAME"
echo ""

# Get script directory for file references
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load full data from SQL file (includes BOM_TBL, MODEL_TBL, TRUCK_OPTIONS)
echo "Loading all demo data (BOM_TBL, MODEL_TBL, TRUCK_OPTIONS)..."
if [[ -f "$SCRIPT_DIR/deployment/scripts/03_load_data.sql" ]]; then
    snow sql -f "$SCRIPT_DIR/deployment/scripts/03_load_data.sql" --connection "$CONNECTION_NAME"
    echo "Full data loaded."
else
    echo "WARNING: 03_load_data.sql not found, loading minimal data..."
    # Minimal data fallback
    run_sql "INSERT INTO $DATABASE.$SCHEMA.MODEL_TBL (MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS, MAX_PAYLOAD_LBS, MAX_TOWING_LBS, SLEEPER_AVAILABLE, MODEL_TIER)
SELECT * FROM VALUES
('MDL-REGIONAL', 'Regional Hauler RT-500', 'The RT-500 Regional Hauler is a versatile medium-duty box truck designed for efficient urban and regional distribution under 300 miles.', 45000, 12000, 15000, 20000, false, 'ENTRY'),
('MDL-FLEET', 'Fleet Workhorse FW-700', 'The FW-700 Fleet Workhorse is the backbone of commercial trucking operations, designed for maximum uptime and minimal total cost of ownership.', 65000, 15000, 25000, 35000, false, 'FLEET'),
('MDL-LONGHAUL', 'Cross Country Pro CC-900', 'The CC-900 Cross Country Pro is purpose-built for coast-to-coast over-the-road operations.', 85000, 17000, 45000, 60000, true, 'STANDARD'),
('MDL-HEAVYHAUL', 'Heavy Haul Max HH-1200', 'The HH-1200 Heavy Haul Max represents the ultimate in pulling power and durability for specialized heavy-haul operations.', 110000, 19000, 80000, 120000, true, 'HEAVY_DUTY'),
('MDL-PREMIUM', 'Executive Hauler EX-1500', 'The EX-1500 Executive Hauler is the flagship of our lineup, designed for discerning owner-operators.', 125000, 18000, 50000, 70000, true, 'PREMIUM')
AS t(MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS, MAX_PAYLOAD_LBS, MAX_TOWING_LBS, SLEEPER_AVAILABLE, MODEL_TIER)"

echo "Loading VALIDATION_RULES..."
run_sql "INSERT INTO $DATABASE.$SCHEMA.VALIDATION_RULES (RULE_ID, DOC_ID, DOC_TITLE, LINKED_OPTION_ID, COMPONENT_GROUP, SPEC_NAME, MIN_VALUE, MAX_VALUE, UNIT, RAW_REQUIREMENT)
SELECT * FROM VALUES
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Turbocharger', 'boost_psi', 45, NULL, 'PSI', 'minimum boost pressure of 45 PSI'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Turbocharger', 'max_hp_supported', 600, NULL, 'HP', 'rated to support at least 600 horsepower'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Radiator', 'cooling_capacity_btu', 350000, NULL, 'BTU per hour', 'minimum cooling capacity of 350,000 BTU per hour'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Radiator', 'core_rows', 5, NULL, 'rows', 'minimum of 5 core rows'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Transmission Type', 'torque_rating_lb_ft', 1850, NULL, 'lb-ft', 'torque rating of at least 1,850 lb-ft'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Engine Brake Type', 'braking_hp', 500, NULL, 'HP', 'minimum braking horsepower of 500 HP'),
(UUID_STRING(), 'DOC-5492c8c4', '605_HP_Engine_Requirements.pdf', '134', 'Engine Brake Type', 'brake_stages', 3, NULL, 'stages', 'at least 3 stages of modulation')
AS t(RULE_ID, DOC_ID, DOC_TITLE, LINKED_OPTION_ID, COMPONENT_GROUP, SPEC_NAME, MIN_VALUE, MAX_VALUE, UNIT, RAW_REQUIREMENT)"
fi

echo ""

# Create Cortex Search Service
echo "Creating Cortex Search Service..."
run_sql "CREATE CORTEX SEARCH SERVICE IF NOT EXISTS $DATABASE.$SCHEMA.ENGINEERING_DOCS_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX
    WAREHOUSE = $WAREHOUSE
    TARGET_LAG = '1 minute'
    AS (
        SELECT CHUNK_ID, DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_TEXT
        FROM $DATABASE.$SCHEMA.ENGINEERING_DOCS_CHUNKED
    )"

# Upload semantic model YAML to stage
echo "Uploading semantic model YAML..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Process YAML - replace placeholders with actual values
sed "s/\${DATABASE}/$DATABASE/g; s/\${SCHEMA}/$SCHEMA/g" "$SCRIPT_DIR/deployment/data/truck_config_analyst.yaml" > /tmp/truck_config_analyst_processed.yaml

# Upload to stage
snow stage copy /tmp/truck_config_analyst_processed.yaml "@$DATABASE.$SCHEMA.SEMANTIC_MODELS/" --connection "$CONNECTION_NAME" --overwrite

# Create semantic view from YAML
echo "Creating Semantic View from YAML..."
run_sql "CREATE OR REPLACE SEMANTIC VIEW $DATABASE.$SCHEMA.TRUCK_CONFIG_ANALYST
    FROM '@$DATABASE.$SCHEMA.SEMANTIC_MODELS/truck_config_analyst_processed.yaml'"

echo ""
echo "Data loading complete!"
echo ""
echo "Cortex services created:"
echo "  - ENGINEERING_DOCS_SEARCH (Cortex Search)"
echo "  - TRUCK_CONFIG_ANALYST (Semantic View for Cortex Analyst)"
