CREATE OR REPLACE PACKAGE LGONZALES.QUEST_SOO_SQLTRACE
    AUTHID Current_User
IS
   /*-------------------------------------------------------------------------
   ** Package for loading a SQL trace file in the USER_DUMP_DEST into spotlight
   ** tables
   ** Default usage:
   **   load_trace(file_name=>'Sid_Pid.trc')
   **
   ** Revision History:
   **
   **    Guy Harrison    July 2007   Initial
   *--------------------------------------------------------------------------*/

   /*-------------------------------------------------------------------------
   ** Load the nominated trace file
   **   The named file must exist in the USER_DUMP_DEST
   **   File name is case sensitive on UNIX
   **
   ** Revision History:
   **
   **    Guy Harrison    July 2007   Initial
   *--------------------------------------------------------------------------*/

   -- Return text description for a given Oracle error code
   FUNCTION ERROR_TEXT (ERROR_CODE NUMBER)
      RETURN VARCHAR2;

   --
   -- Set tracing on for the nominated session and take a guess at the
   -- trace name (might be wrong if tracefile_identifier set)
   --
   FUNCTION set_trace (p_sid NUMBER, p_serial NUMBER, p_level NUMBER)
      RETURN VARCHAR2;

   --
   -- Run load trace as a background (DBMS_JOB) job
   --
   FUNCTION background_load_trace (
      file_name        VARCHAR2,
      process_waits    INTEGER := 1 /*process wait lines*/,
      process_binds    INTEGER := 1 /* process bind info*/,
      load_recursive   INTEGER := 1 /* load/process recursive SQL*/,
      line_limit       INTEGER := NULL /* # of lines to read: -1 for all */,
      comment_text     VARCHAR2 := NULL,
      debug_level      INTEGER := 0,
      pga_limit        NUMBER := NULL
   )
      RETURN NUMBER;

   --
   -- Process every row scheduled for background processing
   --
   PROCEDURE background_loadjob;

   --
   -- Foreground load trace
   --
   PROCEDURE load_trace (
      file_name        VARCHAR2,
      load_all_lines   BOOLEAN
            := TRUE /*load individual FETCH and WAIT lines */,
      process_waits    INTEGER := 1 /*process wait lines*/,
      process_binds    INTEGER := 1 /* process bind info*/,
      load_recursive   INTEGER := 1 /* load/process recursive SQL*/,
      line_limit       INTEGER := NULL /* # of lines to read: -1 for all */,
      comment_text     VARCHAR2 := NULL,
      debug_level      INTEGER := 0,
      pga_limit        NUMBER := NULL
   );
END;
/
