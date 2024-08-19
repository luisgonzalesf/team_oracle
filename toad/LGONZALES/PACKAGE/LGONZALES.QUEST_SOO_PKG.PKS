CREATE OR REPLACE PACKAGE LGONZALES.QUEST_SOO_PKG
    AUTHID Current_User
IS
--
-- This package contains routines to support Spotlight On Oracle
--

    -- Global indicating that the object cache is initialized
    g_object_cache_initialized     NUMBER:=0;
    g_debug                        NUMBER:=0;

    -- And make them global accessible
    /* -------------------------------------------------------------
    || The following statements define the "segment cache".  This
    || comprises a number of PL/SQL tables which contain details
    || of file/block ranges for all existing segments.
    ||
    || get_segname uses a binary chop to find the appropriate entry
    */ -------------------------------------------------------------
    TYPE object_cache_numtype       IS TABLE OF NUMBER      INDEX BY BINARY_INTEGER;
    TYPE object_cache_tabtype       IS TABLE OF VARCHAR(61) INDEX BY BINARY_INTEGER;

    object_cache_fileno             object_cache_numtype;
    object_cache_extno              object_cache_numtype;
    object_cache_blockno            object_cache_numtype;
    object_cache_length             object_cache_numtype;
    object_cache_segname            object_cache_tabtype;
    object_cache_count              NUMBER := 0;

    object_cache                    object_cache_tabtype;

    --
    -- Function to format SQL
    --
    Function format_sql ( p_sql_text IN varchar2,
                          p_max_len  IN number:=256) RETURN  varchar2;

    --

    FUNCTION latch_category(p_latch_name varchar2) RETURN varchar2;

    -- Procedure initialize to initialize PL/SQL tables , etc
    --
    PROCEDURE initialize;

    -- Quick but essential initialize
    PROCEDURE initialize_fast;

    -- Slower initialize which can be defered until main screen collected
    PROCEDURE initialize_objects;

    -- Set a normal trace on for the session
    PROCEDURE set_trace(p_sid NUMBER, p_serial NUMBER, p_level NUMBER);

    -- overload for backward compatibility
    PROCEDURE set_trace(p_sid NUMBER, p_serial NUMBER, p_mode boolean);

    FUNCTION TRANSLATE_PARAMETER( p_value VARCHAR2) RETURN  varchar2;


    FUNCTION stringToDigit(str in varchar2) return number;

    FUNCTION sga_cat(p_pool VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2;

    FUNCTION sga_cat2(p_pool VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2;

    FUNCTION get_long_sqltext(p_hash_value NUMBER,
                              p_address RAW)
             RETURN VARCHAR2;

    -- Decode lock details: TYPE, MODE, REQUEST
    FUNCTION lock_type_decode(type_p VARCHAR2, id2_p NUMBER default -1)
             RETURN VARCHAR2;


    FUNCTION lock_mode_decode(mode_p NUMBER) RETURN VARCHAR2;

    FUNCTION wait_detail ( event_p  IN VARCHAR2,
                           p1text_p IN VARCHAR2, p1_p IN NUMBER,
                           p2text_p IN VARCHAR2 DEFAULT '',
                           p2_p IN NUMBER DEFAULT 0,
                           p3text_p IN VARCHAR2 DEFAULT '',
                           p3_p IN NUMBER DEFAULT 0) RETURN VARCHAR2;

    FUNCTION job_interval(next_date_p DATE, interval_p VARCHAR2) RETURN DATE;

    FUNCTION show_locked_row_41(lsid in number)
        RETURN varchar2;

    FUNCTION get_seg_name_41 (p_fileno NUMBER, p_blockno NUMBER)
        RETURN VARCHAR2;


    FUNCTION is_schema_writable
        RETURN NUMBER;

    -- Function to get version number as a number
    FUNCTION get_db_version
        RETURN NUMBER;
END;
/
