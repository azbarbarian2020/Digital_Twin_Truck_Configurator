#!/usr/bin/env python3
"""Generate complete 03_load_data.sql from Snowflake data"""
import os
import snowflake.connector

conn = snowflake.connector.connect(
    connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "awsbarbarian_CoCo"
)

output_path = "/Users/jdrew/coco_projects/BOM/truck-configurator/deployment/scripts/03_load_data.sql"

header = '''-- =============================================================================
-- Digital Twin Truck Configurator - Data Load Script
-- =============================================================================
-- Part 3 of 4: Loads BOM_TBL, MODEL_TBL, and TRUCK_OPTIONS with SPECS included
-- SPECS are included in the INSERT, not updated separately (fast deployment)
-- Customize ${DATABASE} and ${SCHEMA} before running
-- =============================================================================

USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};
USE WAREHOUSE ${WAREHOUSE};

-- =============================================================================
-- 1. INSERT MODEL_TBL (5 truck models)
-- =============================================================================
'''

cursor = conn.cursor()

# Get MODEL data
cursor.execute("""
    SELECT MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS, MAX_PAYLOAD_LBS, MAX_TOWING_LBS, SLEEPER_AVAILABLE, MODEL_TIER
    FROM BOM.BOM4.MODEL_TBL
    ORDER BY MODEL_ID
""")
models = cursor.fetchall()

model_inserts = []
for m in models:
    model_id, model_nm, desc, msrp, weight, payload, towing, sleeper, tier = m
    desc_escaped = desc.replace("'", "''") if desc else ''
    sleeper_str = 'true' if sleeper else 'false'
    model_inserts.append(
        f"('{model_id}', '{model_nm}', '{desc_escaped}', {msrp}, {weight}, {payload}, {towing}, {sleeper_str}, '{tier}')"
    )

model_values = ',\n'.join(model_inserts)
model_section = f'''INSERT INTO MODEL_TBL (MODEL_ID, MODEL_NM, TRUCK_DESCRIPTION, BASE_MSRP, BASE_WEIGHT_LBS, MAX_PAYLOAD_LBS, MAX_TOWING_LBS, SLEEPER_AVAILABLE, MODEL_TIER)
VALUES
{model_values};

-- =============================================================================
-- 2. INSERT BOM_TBL (253 options with SPECS included)
-- =============================================================================
'''

# Get BOM data
cursor.execute("""
    SELECT OPTION_ID, SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP, OPTION_NM, COST_USD, WEIGHT_LBS, 
           SOURCE_COUNTRY, PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, DESCRIPTION, OPTION_TIER, SPECS::VARCHAR
    FROM BOM.BOM4.BOM_TBL
    ORDER BY CAST(OPTION_ID AS INT)
""")
bom_rows = cursor.fetchall()

bom_inserts = []
for row in bom_rows:
    option_id, sys, subsys, cg, name, cost, weight, country, perf_cat, perf_score, desc, tier, specs = row
    name_escaped = name.replace("'", "''") if name else ''
    desc_escaped = desc.replace("'", "''") if desc else ''
    specs_escaped = specs.replace("'", "''") if specs else 'null'
    specs_part = f"PARSE_JSON('{specs_escaped}')" if specs else 'NULL'
    bom_inserts.append(
        f"('{option_id}', '{sys}', '{subsys}', '{cg}', '{name_escaped}', {cost:.2f}, {weight:.2f}, '{country}', '{perf_cat}', {perf_score}, '{desc_escaped}', '{tier}', {specs_part})"
    )

bom_values = ',\n'.join(bom_inserts)
bom_section = f'''INSERT INTO BOM_TBL (OPTION_ID, SYSTEM_NM, SUBSYSTEM_NM, COMPONENT_GROUP, OPTION_NM, COST_USD, WEIGHT_LBS, SOURCE_COUNTRY, PERFORMANCE_CATEGORY, PERFORMANCE_SCORE, DESCRIPTION, OPTION_TIER, SPECS)
VALUES
{bom_values};

-- =============================================================================
-- 3. INSERT TRUCK_OPTIONS (868 model-option mappings)
-- =============================================================================
'''

# Get TRUCK_OPTIONS data
cursor.execute("""
    SELECT MODEL_ID, OPTION_ID, IS_DEFAULT
    FROM BOM.BOM4.TRUCK_OPTIONS
    ORDER BY MODEL_ID, CAST(OPTION_ID AS INT)
""")
truck_opts = cursor.fetchall()

truck_inserts = []
for row in truck_opts:
    model_id, option_id, is_default = row
    default_str = 'true' if is_default else 'false'
    truck_inserts.append(f"('{model_id}', '{option_id}', {default_str})")

truck_values = ',\n'.join(truck_inserts)
truck_section = f'''INSERT INTO TRUCK_OPTIONS (MODEL_ID, OPTION_ID, IS_DEFAULT)
VALUES
{truck_values};

-- =============================================================================
-- Data load complete!
-- Total: 5 models, 253 BOM options, 868 truck-option mappings
-- =============================================================================
'''

# Write the file
with open(output_path, 'w') as f:
    f.write(header)
    f.write(model_section)
    f.write(bom_section)
    f.write(truck_section)

print(f"Generated {output_path}")
print(f"  - {len(models)} MODEL rows")
print(f"  - {len(bom_rows)} BOM rows")
print(f"  - {len(truck_opts)} TRUCK_OPTIONS rows")

cursor.close()
conn.close()
