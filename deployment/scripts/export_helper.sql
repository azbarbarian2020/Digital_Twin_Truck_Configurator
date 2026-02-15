-- =============================================================================
-- Export Helper Script: Run this in Snowsight to generate INSERT statements
-- Copy the output to 03_load_data.sql
-- =============================================================================

-- Export BOM_TBL as INSERT statements
SELECT CONCAT(
    '(''', OPTION_ID, ''', ''', SYSTEM_NM, ''', ''', SUBSYSTEM_NM, ''', ''', 
    COMPONENT_GROUP, ''', ''', REPLACE(OPTION_NM, '''', ''''''), ''', ', 
    COST_USD, ', ', WEIGHT_LBS, ', ''', SOURCE_COUNTRY, ''', ''', 
    PERFORMANCE_CATEGORY, ''', ', PERFORMANCE_SCORE, ', ''', 
    REPLACE(COALESCE(DESCRIPTION, ''), '''', ''''''), ''', ''', OPTION_TIER, ''', ''',
    COALESCE(REPLACE(SPECS::VARCHAR, '''', ''''''), ''), ''')'
) as BOM_INSERT
FROM BOM.BOM4.BOM_TBL
ORDER BY CAST(OPTION_ID AS INT);

-- Export TRUCK_OPTIONS as INSERT statements
SELECT CONCAT('(''', MODEL_ID, ''', ''', OPTION_ID, ''', ', 
    CASE WHEN IS_DEFAULT THEN 'true' ELSE 'false' END, ')') as TRUCK_OPT_INSERT
FROM BOM.BOM4.TRUCK_OPTIONS
ORDER BY MODEL_ID, CAST(OPTION_ID AS INT);
