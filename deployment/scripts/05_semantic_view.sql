-- =============================================================================
-- Digital Twin Truck Configurator - Semantic Model Setup
-- =============================================================================
-- Part 5 of 5: Semantic model for Cortex Analyst optimization queries
-- This enables natural language queries like "Maximize safety and comfort"
-- 
-- NOTE: We use a YAML semantic model file instead of a DDL Semantic View
-- because YAML supports verified_queries (VQRs) which DDL does not.
-- The YAML file is uploaded to @${DATABASE}.${SCHEMA}.SEMANTIC_MODELS/truck_config_analyst.yaml
-- and referenced by the backend using the semantic_model_file parameter.
-- =============================================================================

-- This script is intentionally empty.
-- The YAML semantic model is uploaded by setup.sh directly to the SEMANTIC_MODELS stage.
-- See: deployment/data/truck_config_analyst.yaml

-- To manually verify the YAML was uploaded:
-- LIST @${DATABASE}.${SCHEMA}.SEMANTIC_MODELS/ PATTERN='.*truck_config_analyst.yaml';
