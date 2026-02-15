-- =============================================================================
-- Digital Twin Truck Configurator - Semantic View Setup
-- =============================================================================
-- Part 5 of 5: Creates Semantic View for Cortex Analyst optimization queries
-- This enables natural language queries like "Maximize safety and comfort"
-- =============================================================================

USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};

-- =============================================================================
-- CREATE SEMANTIC VIEW FOR CORTEX ANALYST
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW TRUCK_CONFIG_ANALYST
    TABLES (
        BOM_OPTIONS AS ${DATABASE}.${SCHEMA}.BOM_TBL PRIMARY KEY (OPTION_ID),
        MODEL_VALID_OPTIONS AS ${DATABASE}.${SCHEMA}.TRUCK_OPTIONS,
        TRUCK_MODELS AS ${DATABASE}.${SCHEMA}.MODEL_TBL PRIMARY KEY (MODEL_ID)
    )
    RELATIONSHIPS (
        OPTIONS_TO_BOM AS MODEL_VALID_OPTIONS(OPTION_ID) REFERENCES BOM_OPTIONS(OPTION_ID),
        MODEL_TO_OPTIONS AS MODEL_VALID_OPTIONS(MODEL_ID) REFERENCES TRUCK_MODELS(MODEL_ID)
    )
    FACTS (
        BOM_OPTIONS.COST_USD AS COST_USD COMMENT='Cost of the option in US dollars',
        BOM_OPTIONS.PERFORMANCE_SCORE AS PERFORMANCE_SCORE COMMENT='Performance rating from 0-10 for the option''s performance category',
        BOM_OPTIONS.WEIGHT_LBS AS WEIGHT_LBS COMMENT='Weight of the option in pounds',
        TRUCK_MODELS.BASE_MSRP AS BASE_MSRP COMMENT='Base manufacturer suggested retail price',
        TRUCK_MODELS.BASE_WEIGHT AS BASE_WEIGHT_LBS COMMENT='Base weight of the truck model in pounds'
    )
    DIMENSIONS (
        BOM_OPTIONS.COMPONENT_GROUP AS COMPONENT_GROUP COMMENT='The functional group this option belongs to (e.g., Cab, Chassis, Engine, Transmission)',
        BOM_OPTIONS.OPTION_ID AS OPTION_ID COMMENT='Unique identifier for each option',
        BOM_OPTIONS.OPTION_NAME AS OPTION_NM COMMENT='Human-readable name of the option',
        BOM_OPTIONS.PERFORMANCE_CATEGORY AS PERFORMANCE_CATEGORY COMMENT='Which performance attribute this option excels at. Values: Safety, Comfort, Power, Economy, Hauling, Durability, Cooling, Emissions',
        MODEL_VALID_OPTIONS.IS_DEFAULT AS IS_DEFAULT COMMENT='Whether this option is the default for this model',
        MODEL_VALID_OPTIONS.MODEL_ID AS MODEL_ID COMMENT='Truck model identifier. Valid values: MDL-REGIONAL, MDL-FLEET, MDL-LONGHAUL, MDL-HEAVYHAUL, MDL-PREMIUM',
        MODEL_VALID_OPTIONS.OPTION_ID AS OPTION_ID COMMENT='References BOM_OPTIONS.OPTION_ID',
        TRUCK_MODELS.MODEL_ID AS MODEL_ID COMMENT='Truck model identifier. Values: MDL-REGIONAL, MDL-FLEET, MDL-LONGHAUL, MDL-HEAVYHAUL, MDL-PREMIUM',
        TRUCK_MODELS.MODEL_NAME AS MODEL_NM COMMENT='Human-readable model name'
    )
    COMMENT='Truck configuration optimization assistant. Helps users optimize truck builds by finding the best options for each component group based on performance categories (Safety, Comfort, Power, Economy, Hauling, Durability, Cooling, Emissions) and cost/weight constraints.'
    AI_SQL_GENERATION 'CRITICAL SQL GENERATION RULES:

1. MODEL_ID EXTRACTION: When the question starts with "For MODEL_ID:" or "For MDL-", extract
   the MODEL_ID value and use it in WHERE clause: mvo.model_id = ''<extracted_value>''
   Valid MODEL_IDs: MDL-REGIONAL, MDL-FLEET, MDL-LONGHAUL, MDL-HEAVYHAUL, MDL-PREMIUM

2. OPTIMIZATION QUERY PATTERN: For ANY query mentioning "maximize" or "minimize", follow this pattern:
   SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs,
          bo.performance_category, bo.performance_score
   FROM __MODEL_VALID_OPTIONS AS mvo
   JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id
   WHERE mvo.model_id = ''<MODEL_ID>''
   QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY <ordering_logic>) = 1

3. ORDERING LOGIC:
   a) SINGLE MINIMIZE (costs/weight): ORDER BY bo.cost_usd ASC or bo.weight_lbs ASC
   b) SINGLE MAXIMIZE (one category): Add WHERE bo.performance_category = ''CategoryName'', ORDER BY bo.performance_score DESC
   c) MULTI-MAXIMIZE: Add WHERE bo.performance_category IN (''Cat1'', ''Cat2''), ORDER BY bo.performance_score DESC
   d) HYBRID (maximize X while minimizing costs): ORDER BY CASE WHEN bo.performance_category IN (''X'') THEN bo.performance_score ELSE 0 END DESC, bo.cost_usd ASC

4. PERFORMANCE_CATEGORY VALUES: Safety, Comfort, Power, Economy, Hauling, Durability, Cooling, Emissions'
    WITH EXTENSION (CA='{"tables":[{"name":"BOM_OPTIONS","dimensions":[{"name":"COMPONENT_GROUP"},{"name":"OPTION_ID"},{"name":"OPTION_NAME"},{"name":"PERFORMANCE_CATEGORY","sample_values":["Safety","Comfort","Power","Economy","Hauling","Durability","Cooling","Emissions"],"is_enum":true}],"facts":[{"name":"COST_USD"},{"name":"PERFORMANCE_SCORE"},{"name":"WEIGHT_LBS"}]},{"name":"MODEL_VALID_OPTIONS","dimensions":[{"name":"IS_DEFAULT"},{"name":"MODEL_ID"},{"name":"OPTION_ID"}]},{"name":"TRUCK_MODELS","dimensions":[{"name":"MODEL_ID"},{"name":"MODEL_NAME"}],"facts":[{"name":"BASE_MSRP"},{"name":"BASE_WEIGHT"}]}],"relationships":[{"name":"MODEL_TO_OPTIONS"},{"name":"OPTIONS_TO_BOM"}],"verified_queries":[{"name":"minimize_costs","sql":"SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs, bo.performance_category, bo.performance_score FROM __MODEL_VALID_OPTIONS AS mvo JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id WHERE mvo.model_id = ''MODEL_ID_PLACEHOLDER'' QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY bo.cost_usd ASC) = 1","question":"Minimize all costs"},{"name":"minimize_weight","sql":"SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs, bo.performance_category, bo.performance_score FROM __MODEL_VALID_OPTIONS AS mvo JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id WHERE mvo.model_id = ''MODEL_ID_PLACEHOLDER'' QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY bo.weight_lbs ASC) = 1","question":"Minimize weight"},{"name":"maximize_safety","sql":"SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs, bo.performance_category, bo.performance_score FROM __MODEL_VALID_OPTIONS AS mvo JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id WHERE mvo.model_id = ''MODEL_ID_PLACEHOLDER'' AND bo.performance_category = ''Safety'' QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY bo.performance_score DESC) = 1","question":"Maximize Safety"},{"name":"maximize_comfort","sql":"SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs, bo.performance_category, bo.performance_score FROM __MODEL_VALID_OPTIONS AS mvo JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id WHERE mvo.model_id = ''MODEL_ID_PLACEHOLDER'' AND bo.performance_category = ''Comfort'' QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY bo.performance_score DESC) = 1","question":"Maximize Comfort"},{"name":"maximize_safety_comfort_minimize_costs","sql":"SELECT mvo.option_id, bo.option_name, bo.component_group, bo.cost_usd, bo.weight_lbs, bo.performance_category, bo.performance_score FROM __MODEL_VALID_OPTIONS AS mvo JOIN __BOM_OPTIONS AS bo ON mvo.option_id = bo.option_id WHERE mvo.model_id = ''MODEL_ID_PLACEHOLDER'' QUALIFY ROW_NUMBER() OVER (PARTITION BY bo.component_group ORDER BY CASE WHEN bo.performance_category IN (''Safety'', ''Comfort'') THEN bo.performance_score ELSE 0 END DESC, bo.cost_usd ASC) = 1","question":"Maximize safety and comfort while minimizing all other costs"},{"name":"list_all_models","sql":"SELECT model_id, model_name, base_msrp, base_weight FROM __TRUCK_MODELS ORDER BY base_msrp","question":"What truck models are available?"}]}');

-- =============================================================================
-- VERIFICATION
-- =============================================================================
-- Check semantic view was created
-- SHOW SEMANTIC VIEWS IN SCHEMA ${DATABASE}.${SCHEMA};
