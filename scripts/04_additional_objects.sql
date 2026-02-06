-- Digital Twin Truck Configurator - Additional Objects
-- Run after 03_semantic_view.sql
-- Creates stages, tables for document upload, and Cortex Search Service

-- ============================================
-- Stages for document storage
-- ============================================

CREATE STAGE IF NOT EXISTS BOM.BOM4.ENGINEERING_DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Stage for uploaded engineering documents';

CREATE STAGE IF NOT EXISTS BOM.BOM4.SEMANTIC_MODELS
  COMMENT = 'Stage for semantic model YAML files';

-- ============================================
-- Tables for document processing and app state
-- ============================================

-- Engineering documents chunked for RAG
CREATE TABLE IF NOT EXISTS BOM.BOM4.ENGINEERING_DOCS_CHUNKED (
    DOC_ID VARCHAR(100),
    DOC_TITLE VARCHAR(500),
    DOC_PATH VARCHAR(1000),
    CHUNK_INDEX INT,
    CHUNK_TEXT VARCHAR(16777216),
    CHUNK_ID VARCHAR(200),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Chat history for conversation persistence
CREATE TABLE IF NOT EXISTS BOM.BOM4.CHAT_HISTORY (
    SESSION_ID VARCHAR(100),
    MODEL_ID VARCHAR(50),
    ROLE VARCHAR(20),
    CONTENT VARCHAR(16777216),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Saved truck configurations
CREATE TABLE IF NOT EXISTS BOM.BOM4.SAVED_CONFIGS (
    CONFIG_ID VARCHAR(100),
    MODEL_ID VARCHAR(50),
    CONFIG_NAME VARCHAR(200),
    SELECTED_OPTIONS VARIANT,
    TOTAL_COST NUMBER(12,2),
    TOTAL_WEIGHT NUMBER(12,2),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Validation cache for query results
CREATE TABLE IF NOT EXISTS BOM.BOM4.VALIDATION_CACHE (
    CACHE_KEY VARCHAR(500),
    CACHE_VALUE VARIANT,
    EXPIRES_AT TIMESTAMP_NTZ,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================
-- Cortex Search Service for Engineering Docs RAG
-- ============================================

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS BOM.BOM4.ENGINEERING_DOCS_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_ID
  WAREHOUSE = DEMO_WH
  TARGET_LAG = '1 minute'
  COMMENT = 'RAG search service for engineering documentation'
  AS (
    SELECT 
      DOC_ID,
      DOC_TITLE,
      DOC_PATH,
      CHUNK_INDEX,
      CHUNK_TEXT,
      CHUNK_ID
    FROM BOM.BOM4.ENGINEERING_DOCS_CHUNKED
  );

-- Verify objects created
SHOW STAGES IN SCHEMA BOM.BOM4;
SHOW TABLES IN SCHEMA BOM.BOM4;
SHOW CORTEX SEARCH SERVICES IN SCHEMA BOM.BOM4;
