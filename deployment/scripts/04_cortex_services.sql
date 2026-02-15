-- =============================================================================
-- Digital Twin Truck Configurator - Cortex Services Setup
-- =============================================================================
-- Part 4 of 4: Creates Cortex Search service for engineering documents
-- Customize ${DATABASE}, ${SCHEMA}, and ${WAREHOUSE} before running
-- =============================================================================

USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};

-- =============================================================================
-- 1. CREATE CORTEX SEARCH SERVICE
-- =============================================================================
-- This service enables semantic search over engineering document chunks

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS ENGINEERING_DOCS_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX
    WAREHOUSE = ${WAREHOUSE}
    TARGET_LAG = '1 minute'
    AS (
        SELECT 
            CHUNK_ID, 
            DOC_ID, 
            DOC_TITLE, 
            DOC_PATH, 
            CHUNK_INDEX, 
            CHUNK_TEXT 
        FROM ENGINEERING_DOCS_CHUNKED
    );

-- =============================================================================
-- 2. VERIFICATION
-- =============================================================================
-- Check service status
-- SHOW CORTEX SEARCH SERVICES IN SCHEMA ${DATABASE}.${SCHEMA};

-- Test search (after uploading documents)
-- SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
--     'ENGINEERING_DOCS_SEARCH',
--     '{"query": "turbocharger requirements", "columns": ["CHUNK_TEXT", "DOC_TITLE"], "limit": 5}'
-- );
