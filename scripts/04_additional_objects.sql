-- Digital Twin Truck Configurator - Additional Objects
-- Run after 03_semantic_view.sql
-- Creates stages, tables, stored procedures, and Cortex Search Service
--
-- NOTE: This script uses BOM.TRUCK_CONFIG as the default schema.
-- setup.sh will sed-replace this with the user's chosen database/schema.

-- ============================================
-- Stages for document storage
-- ============================================

CREATE STAGE IF NOT EXISTS BOM.TRUCK_CONFIG.ENGINEERING_DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Stage for uploaded engineering documents';

CREATE STAGE IF NOT EXISTS BOM.TRUCK_CONFIG.SEMANTIC_MODELS
  COMMENT = 'Stage for semantic model YAML files';

-- ============================================
-- Tables for document processing and app state
-- ============================================

-- Engineering documents chunked for RAG
CREATE TABLE IF NOT EXISTS BOM.TRUCK_CONFIG.ENGINEERING_DOCS_CHUNKED (
    DOC_ID VARCHAR(100),
    DOC_TITLE VARCHAR(500),
    DOC_PATH VARCHAR(1000),
    CHUNK_INDEX INT,
    CHUNK_TEXT VARCHAR(16777216),
    CHUNK_ID VARCHAR(200),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Chat history for conversation persistence
CREATE TABLE IF NOT EXISTS BOM.TRUCK_CONFIG.CHAT_HISTORY (
    SESSION_ID VARCHAR(100),
    MODEL_ID VARCHAR(50),
    ROLE VARCHAR(20),
    CONTENT VARCHAR(16777216),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Saved truck configurations
CREATE TABLE IF NOT EXISTS BOM.TRUCK_CONFIG.SAVED_CONFIGS (
    CONFIG_ID VARCHAR(50) PRIMARY KEY,
    CONFIG_NAME VARCHAR(200) NOT NULL,
    MODEL_ID VARCHAR(50) NOT NULL,
    CREATED_BY VARCHAR(100),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    TOTAL_COST_USD NUMBER(12,2),
    TOTAL_WEIGHT_LBS NUMBER(12,2),
    PERFORMANCE_SUMMARY VARIANT,
    CONFIG_OPTIONS VARIANT,
    NOTES VARCHAR(2000),
    IS_BASELINE BOOLEAN DEFAULT FALSE,
    IS_VALIDATED BOOLEAN DEFAULT FALSE
);

-- Validation cache for query results
CREATE TABLE IF NOT EXISTS BOM.TRUCK_CONFIG.VALIDATION_CACHE (
    CACHE_KEY VARCHAR(500),
    CACHE_VALUE VARIANT,
    EXPIRES_AT TIMESTAMP_NTZ,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================
-- Stored Procedure for Document Upload & Parsing
-- ============================================
-- This procedure:
-- 1. Decodes base64 file content
-- 2. Uploads to the engineering docs stage
-- 3. Parses PDFs/docs using PARSE_DOCUMENT
-- 4. Chunks text and inserts into ENGINEERING_DOCS_CHUNKED
-- 5. Refreshes the Cortex Search service

CREATE OR REPLACE PROCEDURE BOM.TRUCK_CONFIG.UPLOAD_AND_PARSE_DOCUMENT(
    FILE_CONTENT_BASE64 VARCHAR,
    FILE_NAME VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS $$
import base64
import tempfile
import os
import json
import re

def main(session, file_content_base64: str, file_name: str):
    result = {
        "success": False,
        "file_name": file_name,
        "stage_path": None,
        "parsed_text": None,
        "chunks_inserted": 0,
        "error": None
    }
    
    try:
        # Decode and write to temp file
        file_bytes = base64.b64decode(file_content_base64)
        suffix = '.' + file_name.split('.')[-1] if '.' in file_name else ''
        temp_dir = tempfile.gettempdir()
        temp_path = os.path.join(temp_dir, file_name)
        
        with open(temp_path, 'wb') as f:
            f.write(file_bytes)
        
        # Upload to stage - use current database/schema context
        db_schema = session.sql("SELECT CURRENT_DATABASE() || '.' || CURRENT_SCHEMA()").collect()[0][0]
        stage_path = f"@{db_schema}.ENGINEERING_DOCS_STAGE"
        
        put_result = session.file.put(
            temp_path,
            stage_path,
            auto_compress=False,
            overwrite=True
        )
        
        result["stage_path"] = f"{stage_path}/{file_name}"
        
        # Parse document if supported type
        if suffix.lower() in ['.pdf', '.docx', '.doc', '.pptx', '.ppt']:
            # Parse the document using PARSE_DOCUMENT
            parse_sql = f"""
                SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
                    '{stage_path}',
                    '{file_name}',
                    {{'mode': 'LAYOUT'}}
                ):content::VARCHAR as content
            """
            parse_result = session.sql(parse_sql).collect()
            
            if parse_result and parse_result[0]['CONTENT']:
                content = parse_result[0]['CONTENT']
                # Return first 500 chars as preview
                result["parsed_text"] = content[:500] + "..." if len(content) > 500 else content
                
                # Generate doc ID and title
                doc_id = f"doc_{abs(hash(file_name)) % 10000000}"
                doc_title = file_name.replace('.pdf', '').replace('.docx', '').replace('_', ' ')
                
                # Chunk and insert into table
                chunk_insert_sql = f"""
                    INSERT INTO {db_schema}.ENGINEERING_DOCS_CHUNKED (DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_TEXT)
                    SELECT
                        '{doc_id}',
                        '{doc_title}',
                        '{stage_path}/{file_name}',
                        c.INDEX,
                        c.VALUE::VARCHAR
                    FROM TABLE(FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                        (SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
                            '{stage_path}',
                            '{file_name}',
                            {{'mode': 'LAYOUT'}}
                        ):content::VARCHAR),
                        'markdown',
                        1500,
                        200
                    ))) c
                """
                session.sql(chunk_insert_sql).collect()
                
                # Count inserted chunks
                count_result = session.sql(f"SELECT COUNT(*) as cnt FROM {db_schema}.ENGINEERING_DOCS_CHUNKED WHERE DOC_ID = '{doc_id}'").collect()
                result["chunks_inserted"] = count_result[0]['CNT'] if count_result else 0
                
                # Refresh search service
                try:
                    session.sql(f"ALTER CORTEX SEARCH SERVICE {db_schema}.ENGINEERING_DOCS_SEARCH REFRESH").collect()
                except:
                    pass  # Search service may not exist yet
        else:
            # Plain text file
            result["parsed_text"] = file_bytes.decode('utf-8', errors='ignore')
        
        result["success"] = True
        
    except Exception as e:
        result["error"] = str(e)
    finally:
        if 'temp_path' in dir() and os.path.exists(temp_path):
            os.unlink(temp_path)
    
    return result
$$;

-- ============================================
-- Cortex Search Service for Engineering Docs RAG
-- ============================================

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS BOM.TRUCK_CONFIG.ENGINEERING_DOCS_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_ID, DOC_TITLE, DOC_PATH, CHUNK_INDEX, CHUNK_ID
  WAREHOUSE = COMPUTE_WH
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
    FROM BOM.TRUCK_CONFIG.ENGINEERING_DOCS_CHUNKED
  );

-- Verify objects created
SHOW STAGES IN SCHEMA BOM.TRUCK_CONFIG;
SHOW TABLES IN SCHEMA BOM.TRUCK_CONFIG;
SHOW PROCEDURES IN SCHEMA BOM.TRUCK_CONFIG;
SHOW CORTEX SEARCH SERVICES IN SCHEMA BOM.TRUCK_CONFIG;
