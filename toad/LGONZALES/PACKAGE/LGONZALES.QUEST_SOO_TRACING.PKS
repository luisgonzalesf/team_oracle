CREATE OR REPLACE PACKAGE LGONZALES.quest_soo_tracing
    AUTHID Current_User
IS

    -- Used to add debug details to a package
    PROCEDURE add_debug(p_package VARCHAR2, p_procedure VARCHAR2, p_location NUMBER, p_debug varchar2);

    -- Process an exception within package
    PROCEDURE process_exception(p_package VARCHAR2, p_procedure VARCHAR2, p_Location NUMBER, p_exception NUMBER, p_exception_text varchar2);

    -- Turn tracing on
    PROCEDURE traceon;

    -- Turn tracing off
    PROCEDURE traceoff;

    -- Flush cached trace data
    PROCEDURE flush_data;

END;
/
