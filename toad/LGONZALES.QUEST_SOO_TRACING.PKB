CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_tracing
AS
   -- Array type definitions I use
   TYPE typ_name IS TABLE OF VARCHAR2 (50)
      INDEX BY BINARY_INTEGER;

   TYPE typ_excp IS TABLE OF VARCHAR2 (15)
      INDEX BY BINARY_INTEGER;

   TYPE typ_text IS TABLE OF VARCHAR2 (500)
      INDEX BY BINARY_INTEGER;

   TYPE typ_loc IS TABLE OF NUMBER
      INDEX BY BINARY_INTEGER;

   TYPE typ_date IS TABLE OF DATE
      INDEX BY BINARY_INTEGER;

   -- Arrays used to store entries
   arr_package     typ_name;
   arr_procedure   typ_name;
   arr_exception   typ_excp;
   arr_text        typ_text;
   arr_location    typ_loc;
   arr_date        typ_date;
   -- Global variables
   gv_user         VARCHAR2 (50);
   gv_instance     VARCHAR2 (50);
   gv_idx          PLS_INTEGER   := 1;
   gv_sid          NUMBER;
   gv_version      PLS_INTEGER;
   gv_traceon      BOOLEAN       := FALSE;

   -- Constants
   GC_PACKAGE_NAME CONSTANT VARCHAR2(50) := 'QUEST_SOO_TRACING';

   -- Add a debug line with location and text about location
   PROCEDURE add_debug (
      p_package     VARCHAR2,
      p_procedure   VARCHAR2,
      p_location    NUMBER,
      p_debug       VARCHAR2
   )
   IS
   BEGIN
      -- Only add debug if tracing has been turned on
      IF gv_traceon
      THEN
         arr_package (gv_idx) := p_package;
         arr_procedure (gv_idx) := p_procedure;
         arr_exception (gv_idx) := NULL;
         arr_location (gv_idx) := p_location;
         arr_text (gv_idx) := SUBSTR (p_debug, 1, 500);
         arr_date (gv_idx) := SYSDATE;
         gv_idx := gv_idx + 1;

         -- Don't cache too many entries at once. Flush after each 10
         IF gv_idx > 10
         THEN
            flush_data;
         END IF;
      END IF;
   END add_debug;

   -- Process an exception clause
   PROCEDURE process_exception (
      p_package          VARCHAR2,
      p_procedure        VARCHAR2,
      p_location         NUMBER,
      p_exception        NUMBER,
      p_exception_text   VARCHAR2
   )
   IS
   BEGIN
      arr_package (gv_idx) := p_package;
      arr_procedure (gv_idx) := p_procedure;
      arr_exception (gv_idx) := p_exception;
      arr_location (gv_idx) := p_location;
      arr_text (gv_idx) := SUBSTR (p_exception_text, 1, 500);
      arr_date (gv_idx) := SYSDATE;

      -- Flush immediately just in case disconnection occurs
      flush_data;
   END;

   -- Purge old data from trace TABLE
   -- More than a day old we consider no longer relevant
   PROCEDURE purge_table
   IS
   BEGIN
      DELETE FROM quest_soo_trace_entries
            WHERE entry_date <= (SYSDATE - 1);

      COMMIT;
   END purge_table;

   -- Allow tracing and purge any old data
   PROCEDURE traceon
   IS
     LC_PROC_NAME 	CONSTANT VARCHAR2(50) := 'TRACEON';
   BEGIN
      IF quest_soo_pkg.is_schema_writable = 1 THEN
         add_debug(gc_package_name, lc_proc_name, 100, 'Tracing turned on');
         purge_table;
         gv_traceon := TRUE;
      END IF;
   END;

   -- Turn tracing off. Flush existing cached data
   PROCEDURE traceoff
   IS
     LC_PROC_NAME 	CONSTANT VARCHAR2(50) := 'TRACEOFF';
   BEGIN
      add_debug(gc_package_name, lc_proc_name, 100, 'Tracing turned off');
      IF gv_traceon
      THEN
         flush_data;
      END IF;

      gv_traceon := FALSE;
   END;

   -- Flush cache and store in physical table. Autonomous transaction so doesn't affect any other transactions occuring currently
   PROCEDURE flush_data
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
      FORALL idx IN 1 .. arr_package.COUNT
         INSERT INTO quest_soo_trace_entries
                     (trace_id, package_name,
                      procedure_name, line_location,
                      sql_exception, trace_text, spotlight_user,
                      spotlight_sid, instance_name, entry_date
                     )
              VALUES (quest_soo_trace_id.NEXTVAL, arr_package (idx),
                      arr_procedure (idx), arr_location (idx),
                      arr_exception (idx), arr_text (idx), gv_user,
                      gv_sid, gv_instance, arr_date (idx)
                     );
      arr_package.DELETE;
      arr_procedure.DELETE;
      arr_exception.DELETE;
      arr_text.DELETE;
      arr_location.DELETE;
      gv_idx := 1;
      COMMIT;
   END flush_data;

-- Initial setup variables used when storing cached data
BEGIN
   SELECT username
     INTO gv_user
     FROM user_users;

   execute immediate 'SELECT instance_name
                      FROM v$instance' INTO gv_instance;

   execute immediate 'SELECT TO_NUMBER (SUBSTR (VERSION, 1, INSTR (VERSION, ''.'') - 1), ''99.99'')
                      FROM v$instance' INTO gv_version;

   IF gv_version = 9
   THEN
      SELECT SYS_CONTEXT ('userenv', 'SESSIONID')
        INTO gv_sid
        FROM DUAL;
   ELSE
      SELECT SYS_CONTEXT ('userenv', 'sid')
        INTO gv_sid
        FROM DUAL;
   END IF;
EXCEPTION
    when others THEN
        process_exception(gc_package_name, 'INIT', 100, sqlcode, sqlerrm);
END quest_soo_tracing;
/
