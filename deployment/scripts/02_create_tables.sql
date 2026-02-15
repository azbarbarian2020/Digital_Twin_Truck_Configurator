-- =============================================================================
-- Digital Twin Truck Configurator - Table Creation
-- =============================================================================
-- Part 2 of 4: Creates all tables required by the application
-- Customize ${DATABASE} and ${SCHEMA} before running
-- =============================================================================

USE DATABASE ${DATABASE};
USE SCHEMA ${SCHEMA};

-- =============================================================================
-- 1. BOM_TBL - Bill of Materials (core options catalog)
-- =============================================================================
CREATE TABLE IF NOT EXISTS BOM_TBL (
    OPTION_ID VARCHAR(20) NOT NULL,
    SYSTEM_NM VARCHAR(100) NOT NULL,
    SUBSYSTEM_NM VARCHAR(100),
    COMPONENT_GROUP VARCHAR(100),
    OPTION_NM VARCHAR(200) NOT NULL,
    COST_USD NUMBER(10,2) DEFAULT 0,
    WEIGHT_LBS NUMBER(10,2) DEFAULT 0,
    SOURCE_COUNTRY VARCHAR(50) DEFAULT 'USA',
    PERFORMANCE_CATEGORY VARCHAR(50) DEFAULT 'Balanced',
    PERFORMANCE_SCORE NUMBER(3,1) DEFAULT 3,
    DESCRIPTION VARCHAR(1000),
    OPTION_TIER VARCHAR(20) DEFAULT 'STANDARD',
    SPECS VARIANT,
    PRIMARY KEY (OPTION_ID)
);

COMMENT ON TABLE BOM_TBL IS 'Bill of Materials - contains all configurable truck options with their technical specifications';

-- =============================================================================
-- 2. MODEL_TBL - Truck Model Definitions
-- =============================================================================
CREATE TABLE IF NOT EXISTS MODEL_TBL (
    MODEL_ID VARCHAR(20) NOT NULL,
    MODEL_NM VARCHAR(100) NOT NULL,
    TRUCK_DESCRIPTION VARCHAR(4000),
    BASE_MSRP NUMBER(10,2) DEFAULT 0,
    BASE_WEIGHT_LBS NUMBER(10,2) DEFAULT 0,
    MAX_PAYLOAD_LBS NUMBER(10,2) DEFAULT 0,
    MAX_TOWING_LBS NUMBER(10,2) DEFAULT 0,
    SLEEPER_AVAILABLE BOOLEAN DEFAULT FALSE,
    MODEL_TIER VARCHAR(20) DEFAULT 'STANDARD',
    PRIMARY KEY (MODEL_ID)
);

COMMENT ON TABLE MODEL_TBL IS 'Truck model definitions with base specs and descriptions';

-- =============================================================================
-- 3. TRUCK_OPTIONS - Model-to-Option Mapping
-- =============================================================================
CREATE TABLE IF NOT EXISTS TRUCK_OPTIONS (
    MODEL_ID VARCHAR(20) NOT NULL,
    OPTION_ID VARCHAR(20) NOT NULL,
    IS_DEFAULT BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (MODEL_ID, OPTION_ID),
    FOREIGN KEY (MODEL_ID) REFERENCES MODEL_TBL(MODEL_ID),
    FOREIGN KEY (OPTION_ID) REFERENCES BOM_TBL(OPTION_ID)
);

COMMENT ON TABLE TRUCK_OPTIONS IS 'Maps which options are available for each truck model';

-- =============================================================================
-- 4. VALIDATION_RULES - AI-Extracted Engineering Requirements
-- =============================================================================
CREATE TABLE IF NOT EXISTS VALIDATION_RULES (
    RULE_ID VARCHAR(100) NOT NULL,
    LINKED_OPTION_ID VARCHAR(20) NOT NULL,
    DOC_ID VARCHAR(200) NOT NULL,
    DOC_TITLE VARCHAR(500),
    TARGET_COMPONENT_GROUP VARCHAR(100) NOT NULL,
    REQUIREMENT_TYPE VARCHAR(50) NOT NULL,
    SPEC_NAME VARCHAR(100) NOT NULL,
    OPERATOR VARCHAR(10) NOT NULL,
    THRESHOLD_VALUE NUMBER(20,4) NOT NULL,
    DESCRIPTION VARCHAR(1000),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (RULE_ID)
);

COMMENT ON TABLE VALIDATION_RULES IS 'AI-extracted validation rules from engineering documents, linked to specific options';

-- =============================================================================
-- 5. ENGINEERING_DOCS_CHUNKED - Document Chunks for Cortex Search
-- =============================================================================
CREATE TABLE IF NOT EXISTS ENGINEERING_DOCS_CHUNKED (
    CHUNK_ID VARCHAR(200) NOT NULL,
    DOC_ID VARCHAR(200) NOT NULL,
    DOC_TITLE VARCHAR(500),
    DOC_PATH VARCHAR(1000),
    CHUNK_INDEX NUMBER(10,0),
    CHUNK_TEXT VARCHAR(16777216),
    PRIMARY KEY (CHUNK_ID)
);

ALTER TABLE ENGINEERING_DOCS_CHUNKED SET CHANGE_TRACKING = ON;

COMMENT ON TABLE ENGINEERING_DOCS_CHUNKED IS 'Chunked engineering documents for semantic search';

-- =============================================================================
-- 6. CHAT_HISTORY - Conversation History for AI Assistant
-- =============================================================================
CREATE TABLE IF NOT EXISTS CHAT_HISTORY (
    SESSION_ID VARCHAR(100) NOT NULL,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    ROLE VARCHAR(20) NOT NULL,
    CONTENT VARCHAR(16777216) NOT NULL,
    CONTEXT_DATA VARIANT
);

COMMENT ON TABLE CHAT_HISTORY IS 'Chat history for AI assistant conversations';

-- =============================================================================
-- 7. SAVED_CONFIGS - User Saved Configurations
-- =============================================================================
CREATE TABLE IF NOT EXISTS SAVED_CONFIGS (
    CONFIG_ID VARCHAR(100) NOT NULL,
    MODEL_ID VARCHAR(20) NOT NULL,
    CONFIG_NAME VARCHAR(200),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    TOTAL_COST NUMBER(12,2) DEFAULT 0,
    TOTAL_WEIGHT NUMBER(12,2) DEFAULT 0,
    SELECTIONS VARIANT NOT NULL,
    NOTES VARCHAR(4000),
    PRIMARY KEY (CONFIG_ID)
);

COMMENT ON TABLE SAVED_CONFIGS IS 'User-saved truck configurations';

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================
-- SHOW TABLES IN SCHEMA ${DATABASE}.${SCHEMA};
