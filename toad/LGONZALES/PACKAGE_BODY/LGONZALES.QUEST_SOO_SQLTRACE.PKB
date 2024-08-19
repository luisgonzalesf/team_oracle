CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_sqltrace
IS
    /* TODO:

        What happens if the trace file starts in mid-execution?
        Module and action processing


    */
   /* --------------------------------------------------------
   ** Package global variables.  These hold the current state
   ** of the trace file being read
   ** ---------------------------------------------------------*/
   g_debug                      NUMBER                            := 0;
   g_fetch_bunching_time        NUMBER                            := 5000000;
                                  -- determines how close together fetch
                                  -- lines should be to be aggregated (micro)
   -- current SQL identifier within the file
   g_sql_id                     NUMBER                            := -1;
   g_sql_zero                   NUMBER;       --Special id for cursor# 0 ,etc
   g_trace_file_id              NUMBER;
   g_session_id                 NUMBER                            := 0;
   g_serial                     NUMBER                            := 0;
   g_currently_binding_sql      NUMBER;
                                       -- The sql_id context for a bind block
   --
   --
   g_load_all_lines             BOOLEAN
                             := TRUE /*load individual FETCH and WAIT lines */;
   g_process_waits              BOOLEAN         := TRUE /*process wait lines*/;
   g_process_binds              BOOLEAN         := TRUE /* process bind info*/;
   g_load_recursive             BOOLEAN                           := TRUE;
   -- keep trace of previous line type
   g_previous_line_type         VARCHAR2 (20);
   g_major_oracle_version       NUMBER;
   g_minor_oracle_version       NUMBER;
   g_last_debug_message         VARCHAR2 (32767);
   -- statistic# for session pga
   g_session_pga_memory_stat#   NUMBER;
   g_pga_limit                  NUMBER;    -- max amount of pga memory to use
   bulk_errors                  EXCEPTION;
   PRAGMA EXCEPTION_INIT (bulk_errors, -24381);

   -- Generic varchar array
   TYPE varchar_tab_typ IS TABLE OF VARCHAR2 (200)
      INDEX BY BINARY_INTEGER;

   --Generic number array
   TYPE number_tab_typ IS TABLE OF NUMBER
      INDEX BY BINARY_INTEGER;

   TYPE sql_exec_typ IS RECORD (
      sql_id     NUMBER,
      parse_id   NUMBER
   );

   -- This contains a mapping of cursors to our internal sql id
   -- eg, look in here to see which sql_id corresponds to a particular
   -- cursor reference while we are reading the trace file.
   -- cursor_to_stmt_map        number_tab_typ;
   TYPE cursor_to_stmt_map_typ IS TABLE OF sql_exec_typ
      INDEX BY VARCHAR2(38);

   cursor_to_stmt_map           cursor_to_stmt_map_typ;

   -- List of all SQL parses
   TYPE parse_typ IS TABLE OF quest_soo_at_parse_cursor%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_parse_list                 parse_typ;

   -- List of all SQL execs
   TYPE exec_typ IS TABLE OF quest_soo_at_sql_executions%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_exec_list                  exec_typ;

   -- List of all fetches
   TYPE fetch_typ IS TABLE OF quest_soo_at_sql_fetch%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_fetch_list                 fetch_typ;

   -- List of all SQL statements
   TYPE sql_statement_typ IS TABLE OF quest_soo_at_sql_statement%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_sql_statement_list         sql_statement_typ;

   --Structure for the wait name look up
   TYPE wait_nam_typ IS TABLE OF quest_soo_at_wait_names%ROWTYPE
      INDEX BY BINARY_INTEGER;

   TYPE wait_nam_idx IS TABLE OF INTEGER
      INDEX BY VARCHAR2 (256);

   g_wait_names                 wait_nam_typ;
   g_wait_nam_idx               wait_nam_idx;

   -- structure for wait data
   TYPE sql_wait_typ IS TABLE OF quest_soo_at_sql_waits%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_wait_list                  sql_wait_typ;
   --
   -- This holds waits that are recorded before the first execution
   --
   g_pending_waits              sql_wait_typ;

   TYPE nested_num_typ IS TABLE OF number_tab_typ
      INDEX BY BINARY_INTEGER;

   -- index of all pending waits for a specific SQL
   g_pending_waits_sql_idx      nested_num_typ;

   -- Structure for SQL text
   TYPE sql_text_typ IS TABLE OF quest_soo_at_sql_stmt_pieces%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_sql_stmt_pieces            sql_text_typ;

   -- Structure for STAT entries
   TYPE stat_typ IS TABLE OF quest_soo_at_execution_plan%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_stat_list                  stat_typ;

   -- Structure for ERROR entries
   TYPE exec_error_typ IS TABLE OF quest_soo_at_sql_exec_error%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_error_list                 exec_error_typ;

   --
   -- associative array indexed by wait name||object#.  There is one of
   -- these for each execution of an sql and entries for each distinct
   -- wait type for a distinct object id
   --
   TYPE exec_wait_typ IS TABLE OF NUMBER
      INDEX BY VARCHAR (30);

   TYPE exec_wait_list_typ IS TABLE OF exec_wait_typ
      INDEX BY BINARY_INTEGER;

   --
   -- Bind variable structure
   --

   -- THis is the temporary structure to hold the bind values prior
   -- to the sql statement execution
   TYPE bind_set_typ IS TABLE OF VARCHAR2 (4000)
      INDEX BY BINARY_INTEGER;

   TYPE sql_binds_typ IS TABLE OF bind_set_typ
      INDEX BY BINARY_INTEGER;

   g_sql_binds                  sql_binds_typ;

   --
   -- List of bind variable values
   --
   TYPE bind_typ IS TABLE OF quest_soo_at_sql_binds%ROWTYPE
      INDEX BY BINARY_INTEGER;

   g_bind_list                  bind_typ;

   -- Structure which holds a single SQL instance
   -- This functions like an index into all the tables
   -- that contain data relevent to our current SQL as well as
   -- some working areas and flags
   --
   TYPE sql_stmt_typ IS RECORD (
      sql_stmt         NUMBER,              -- points to g_sql_statement_list
      parse_list       number_tab_typ,      -- points to g_parse_list entries
      sql_text_list    number_tab_typ,         -- points to g_sql_stmt_pieces
      exec_list        number_tab_typ,       -- points to g_exec_list entries
      exec_wait_list   exec_wait_list_typ,
      -- for each exec, points to wait by category
      fetch_list       number_tab_typ,      -- points to g_fetch_list entries
      stat_list        number_tab_typ,       -- points to g_stat_list entries
      sql_known        BOOLEAN            := FALSE
   -- True when we've got all the SQL text
   );

   TYPE sql_list_typ IS TABLE OF sql_stmt_typ
      INDEX BY BINARY_INTEGER;

   g_sql_list                   sql_list_typ;

    /*
   -- Structure to hold SQL addresses and ids, indexed by hash value
   -- used to determine if we have seen SQL before
   */
   TYPE sql_address_list IS TABLE OF NUMBER
      INDEX BY VARCHAR2 (40);

   -- This table is indexed by hash value points to the SQL entry with
   -- SQLS with the same hash
   g_sql_lookup                 sql_address_list;
   --
   --
   -- Name of our Oracle directory;
   g_directory_name             VARCHAR2 (60);
   g_trace_file                 quest_soo_at_trace_file%ROWTYPE;
   --
   -- Global structures for tracing PGA usage
   --
   g_pga_size                   NUMBER                            := 0;

   -- track pga size
   TYPE pga_typ IS TABLE OF NUMBER
      INDEX BY VARCHAR2 (20);

   g_pga_usage                  pga_typ;

   -- Maintain index of operations from STAT lines (reduce memory)
   TYPE operations_typ IS TABLE OF quest_soo_at_operations%ROWTYPE
      INDEX BY BINARY_INTEGER;

   TYPE operations_idx_typ IS TABLE OF INTEGER
      INDEX BY quest_soo_at_operations.operation_string%TYPE;

   g_operations_list            operations_typ;
   g_operations_idx             operations_idx_typ;

   --
   -- Forward declarations
   --
   PROCEDURE process_pending_waits (p_sql_id NUMBER);

   PROCEDURE reset_package;

   --
   -- Print the text via DBMS_OUTPUT if debug is on
   --
   PROCEDURE DEBUG (p_level NUMBER, p_text VARCHAR2)
   IS
   BEGIN
      IF g_debug = 1 AND p_level >= g_debug
      THEN
         DBMS_OUTPUT.put_line (p_text);
      END IF;

      g_last_debug_message := p_text;
   END;

   --
   -- Load g_wait_names
   --
   PROCEDURE load_wait_lookup
   IS
   BEGIN
      g_wait_names.DELETE;

      SELECT event_id,
             nam
      BULK COLLECT INTO g_wait_names
        FROM quest_soo_at_wait_names;
   END;

   --
   -- If the wait lookup table is empty (first run after install)
   -- load it from v$event_name
   --
   PROCEDURE populate_wait_lookup
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
      execute immediate 'INSERT INTO quest_soo_at_wait_names
                            (event_id, nam)
                            SELECT event#, NAME
                            FROM v$event_name';

      COMMIT;
      load_wait_lookup;
   END;

   --
   -- Initialize the wait names tables
   --
   PROCEDURE initialize_wait_lookup
   IS
      v_wait_name   quest_soo_at_wait_names.nam%TYPE;
      v_event_id    quest_soo_at_wait_names.event_id%TYPE;
   BEGIN
      load_wait_lookup;
      DEBUG (0, g_wait_names.COUNT || ' events loaded');

      -- In case the table hasn't been populated yet.
      IF g_wait_names.COUNT = 0
      THEN
         populate_wait_lookup;
      END IF;

      -- Associative array to get event_id from name
      FOR i IN 1 .. g_wait_names.COUNT
      LOOP
         v_wait_name := g_wait_names (i).nam;
         v_event_id := g_wait_names (i).event_id;
         DEBUG (0,
                'Creatining index for ' || v_wait_name || ' to id '
                || v_event_id
               );
         g_wait_nam_idx (v_wait_name) := v_event_id;
      END LOOP;
   END;

   -- If we see a wait we've never seen before, add it to our table of waits
   FUNCTION new_wait_id (p_wait_name quest_soo_at_wait_names.nam%TYPE)
      RETURN INTEGER
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      v_wait_id   INTEGER;
   BEGIN
      LOCK TABLE quest_soo_at_wait_names IN EXCLUSIVE MODE;

      SELECT NVL (MAX (event_id), 0) + 1
        INTO v_wait_id
        FROM quest_soo_at_wait_names;

      INSERT INTO quest_soo_at_wait_names
                  (event_id, nam
                  )
           VALUES (v_wait_id, p_wait_name
                  );

      COMMIT;
      initialize_wait_lookup;
      RETURN (v_wait_id);
   END;

   FUNCTION get_wait_id (p_wait_name quest_soo_at_wait_names.nam%TYPE)
      RETURN INTEGER
   IS
      v_wait_id   INTEGER;
   BEGIN
      BEGIN
         v_wait_id := g_wait_nam_idx (p_wait_name);
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            -- This shouldn't happen unless we see a wait not held in v$event_name
            v_wait_id := new_wait_id (p_wait_name);
      END;

      RETURN (v_wait_id);
   END;

   --
   -- return current size of session_pga_memory
   --
   FUNCTION session_pga_memory
      RETURN NUMBER
   IS
      l_pga_size   NUMBER;
   BEGIN
      IF g_session_pga_memory_stat# IS NULL
      THEN
        execute immediate 'SELECT statistic#
                           FROM v$statname
                           WHERE NAME = ''session pga memory'''
                           INTO g_session_pga_memory_stat#
           ;
      END IF;

      execute immediate 'SELECT VALUE
                         FROM v$mystat
                         WHERE statistic# = :g_session_pga_memory_stat#' INTO l_pga_size USING IN g_session_pga_memory_stat#;

      RETURN (l_pga_size);
   END;

   --
   -- Keep track of Pga allocations
   --
   PROCEDURE track_pga (
      p_category    VARCHAR2,
      l_start_pga   NUMBER,
      l_end_pga     NUMBER
   )
   IS
      l_pga_delta   NUMBER;
   BEGIN
      IF g_debug > 0
      THEN
         l_pga_delta := l_end_pga - l_start_pga;

         IF g_pga_usage.EXISTS (p_category)
         THEN
            g_pga_usage (p_category) := g_pga_usage (p_category)
                                        + l_pga_delta;
         ELSE
            g_pga_usage (p_category) := l_pga_delta;
         END IF;
      END IF;
   END;

   PROCEDURE print_pga
   IS
      l_category   VARCHAR2 (20);
   BEGIN
      l_category := g_pga_usage.FIRST;

      LOOP
         EXIT WHEN l_category IS NULL;
         DEBUG (2, l_category || ':' || g_pga_usage (l_category));
         l_category := g_pga_usage.NEXT (l_category);
      END LOOP;
   END;

   PROCEDURE mystat (p_statname VARCHAR2)
   IS
      l_value   NUMBER;
   BEGIN
      IF g_debug > 0
      THEN
         execute immediate 'SELECT VALUE
                            FROM v$mystat JOIN v$statname USING (statistic#)
                            WHERE NAME = :p_statname' INTO l_value USING IN p_statname;

         DBMS_OUTPUT.put_line (p_statname || ' = ' || l_value);
      END IF;
   END;

   --
   -- Return a string between the nominated substring and the EOL
   --
   FUNCTION get_string (p_line VARCHAR2, start_string VARCHAR2)
      RETURN VARCHAR2
   IS
      returnvalue   VARCHAR2 (1000) := -1;
      start_pos     NUMBER;
      tmp           VARCHAR2 (1000);
   BEGIN
      start_pos := INSTR (p_line, start_string);

      IF (start_pos > 0)
      THEN
         start_pos := start_pos + LENGTH (start_string);
         tmp := SUBSTR (p_line, start_pos);
      ELSE
         tmp := NULL;
      END IF;

      RETURN (tmp);
   END;

   --
   -- Return a substring between two other substrings
   --
   FUNCTION get_string (
      p_line         VARCHAR2,
      start_string   VARCHAR2,
      end_string     VARCHAR2
   )
      RETURN VARCHAR2
   IS
      returnvalue   VARCHAR2 (1000) := -1;
      start_pos     NUMBER;
      end_pos       NUMBER;
   BEGIN
      -- dbms_output.put_line('start= '||start_string||', end='||end_string||' '||p_line);
      start_pos := INSTR (p_line, start_string);

      --DBMS_OUTPUT.put_line (p_line);

      --DBMS_OUTPUT.put_line (start_pos);
      IF (start_pos > 0)
      THEN
         start_pos := start_pos + LENGTH (start_string);
         end_pos := INSTR (p_line, end_string, start_pos);

         IF (end_pos > 0)
         THEN
            returnvalue := SUBSTR (p_line, start_pos, end_pos - start_pos);
         ELSE                              -- Probably hit the end of the line
            returnvalue := SUBSTR (p_line, start_pos);
         END IF;
      END IF;

      --dbms_output.put_line(substr('Value of returnvalue='||returnvalue,1,255));
      RETURN (returnvalue);
   END;

   PROCEDURE log_error (
      p_file_name       VARCHAR2,
      p_error_stack     VARCHAR2,
      p_call_stack      VARCHAR2,
      p_error_line_no   NUMBER
   )
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
      DBMS_OUTPUT.put_line (p_error_stack);
      DBMS_OUTPUT.put_line (p_call_stack);
      DBMS_OUTPUT.put_line (g_last_debug_message);

      -- dbms_output.put_line(dbms_utility.format_error_backtrace);
      UPDATE quest_soo_at_trace_file
         SET load_status = 'FAILED',
             ERROR_TEXT = SUBSTR (p_error_stack, 1, 4000),
             error_line_no = p_error_line_no,
             last_debug_message = SUBSTR (g_last_debug_message, 1, 4000)
       WHERE trace_file_id = g_trace_file_id;

      COMMIT;
      reset_package;
   END;

   -- Start tracing the session
   FUNCTION set_trace (p_sid NUMBER, p_serial NUMBER, p_level NUMBER)
      RETURN VARCHAR2
   IS
      v_instance    VARCHAR2 (60);
      v_spid        NUMBER;
      v_tracename   VARCHAR2 (200);
      v_WaitsBinds  VARCHAR2 (100);
   BEGIN
      EXECUTE IMMEDIATE 'SELECT instance_name
                         FROM v$instance' INTO v_instance;

      EXECUTE IMMEDIATE 'SELECT spid
                         FROM v$process
                         WHERE addr = (SELECT paddr
                                       FROM v$session
                                       WHERE SID = :p_sid AND serial# = :p_serial)'
                         INTO v_spid USING IN p_sid, p_serial;

      --Translate the p_level to a dbms_monitor parameter equivalent
      CASE
        WHEN p_level = 1  THEN v_WaitsBinds := 'WAITS=>FALSE, BINDS=>FALSE';
        WHEN p_level = 4  THEN v_WaitsBinds := 'WAITS=>FALSE, BINDS=>TRUE';
        WHEN p_level = 8  THEN v_WaitsBinds := 'WAITS=>TRUE, BINDS=>FALSE';
        WHEN p_level = 12 THEN v_WaitsBinds := 'WAITS=>TRUE, BINDS=>TRUE';
        ELSE
            v_WaitsBinds := 'WAITS=>TRUE, BINDS=>TRUE';
      END CASE;

      EXECUTE IMMEDIATE 'BEGIN SYS.DBMS_MONITOR.session_trace_enable(:p_sid, :p_serial,' || v_WaitsBinds || '); END;' USING p_sid, p_serial;

      RETURN (v_instance || '_ora_' || v_spid || '.trc');
   EXCEPTION
      WHEN NO_DATA_FOUND
      THEN
         raise_application_error (-20006,
                                     'No Session '
                                  || p_sid
                                  || ','
                                  || p_serial
                                  || ' found for tracing'
                                 );
   END;

   --
     -- Return a numeric value found between two substrings
     --
   FUNCTION get_stat (
      p_line         VARCHAR2,
      start_string   VARCHAR2,
      end_string     VARCHAR2
   )
      RETURN NUMBER
   IS
      returnvalue   NUMBER          := -1;
      start_pos     NUMBER;
      tmp           VARCHAR2 (1000);
      end_pos       NUMBER;
   BEGIN
      BEGIN
         returnvalue :=
                    TO_NUMBER (get_string (p_line, start_string, end_string));
      EXCEPTION
         WHEN VALUE_ERROR
         THEN
            DBMS_OUTPUT.put_line (   'Warning:  '
                                  || SQLERRM
                                  || ' on conversion of '
                                  || SUBSTR (p_line, 1, 256)
                                 );
            DBMS_OUTPUT.put_line (   'Start string= '
                                  || start_string
                                  || 'End string= '
                                  || end_string
                                 );
            DBMS_OUTPUT.put_line (   'get_string= '
                                  || get_string (p_line,
                                                 start_string,
                                                 end_string
                                                )
                                 );
      END;

      RETURN (returnvalue);
   END;

   PROCEDURE get_oracle_version
   IS
      CURSOR c_ver
      IS
         SELECT banner, RTRIM (VERSION) full_version,
                RTRIM (version_bit) version_bit,
                SUBSTR (VERSION, 1, INSTR (VERSION, '.', 1, 1) - 1) major,
                SUBSTR (VERSION,
                        INSTR (VERSION, '.', 1, 1) + 1,
                          INSTR (VERSION, '.', 1, 2)
                        - INSTR (VERSION, '.', 1, 1)
                        - 1
                       ) minor,
                SUBSTR (VERSION,
                        INSTR (VERSION, '.', 1, 2) + 1,
                          INSTR (VERSION, '.', 1, 3)
                        - INSTR (VERSION, '.', 1, 2)
                        - 1
                       ) VERSION,
                SUBSTR (VERSION,
                        INSTR (VERSION, '.', 1, 3) + 1,
                          INSTR (VERSION, '.', 1, 4)
                        - INSTR (VERSION, '.', 1, 3)
                        - 1
                       ) patch
           FROM (SELECT ROWNUM row_num, banner,
                        SUBSTR (SUBSTR (banner, INSTR (banner, 'Release ') + 8),
                                1
                               ) version_bit,
                        SUBSTR (SUBSTR (banner, INSTR (banner, 'Release ') + 8),
                                1,
                                INSTR (SUBSTR (banner,
                                               INSTR (banner, 'Release ') + 8
                                              ),
                                       ' '
                                      )
                               ) VERSION
                   FROM v$version
                  WHERE banner LIKE 'Oracle%'
                        OR banner LIKE 'Personal Oracle%') v
          WHERE v.row_num = 1;

      rec   c_ver%ROWTYPE;
   BEGIN
      OPEN c_ver;

      FETCH c_ver
       INTO rec;

      g_major_oracle_version := rec.major;
      g_minor_oracle_version := rec.minor;

      CLOSE c_ver;
   END;

   --
   -- Get numeric stat from substring to EOL
   --
   FUNCTION get_stat (p_line VARCHAR2, start_string VARCHAR2)
      RETURN NUMBER
   IS
      returnvalue   NUMBER          := -1;
      start_pos     NUMBER;
      tmp           VARCHAR2 (2000);
      lastchar      CHAR (1);
   BEGIN
      BEGIN
         start_pos := INSTR (p_line, start_string) + LENGTH (start_string);
         tmp := SUBSTR (p_line, start_pos);
         lastchar := SUBSTR (tmp, LENGTH (tmp));

         IF ASCII (lastchar) = 13
         THEN                                          -- ^M at end of string
            tmp := SUBSTR (tmp, 1, LENGTH (tmp) - 1);
         END IF;

         --DEBUG(2,'lastchar='|| substr(tmp,length(tmp))||'.');
         --DEBUG(2,'.'||tmp||'.');
         --DEBUG(2,ascii(substr(tmp,length(tmp))));
         returnvalue := TO_NUMBER (RTRIM (tmp));
      EXCEPTION
         WHEN VALUE_ERROR
         THEN
            DBMS_OUTPUT.put_line (   'Warning:  '
                                  || SQLERRM
                                  || ' on conversion of '
                                  || SUBSTR (p_line, 1, 256)
                                 );
            DBMS_OUTPUT.put_line ('Start string= ' || start_string);
      END;

      RETURN (returnvalue);
   END;

   --
   -- Get the sql_id corresponding to a particular cursor#
   --
   FUNCTION get_sqlid_for_csr (p_csr_id NUMBER)
      RETURN NUMBER
   IS
      v_sql_id   NUMBER;
   BEGIN
      BEGIN
         v_sql_id := cursor_to_stmt_map (TO_CHAR(p_csr_id)).sql_id;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            v_sql_id := g_sql_zero;
      END;

      RETURN (v_sql_id);
   END;

   -- Get the current parse_id for a cursor;
   /*
   ** TODO:  There's a lot of spots where we accumulate
   ** Totals against the last execution of a SQL statement
   ** This will be wrong if there are two open cursors for the same
   ** SQL (which is silly, but can happen).  Use this function
   ** to accumulate against the correct parse_id
   */
   FUNCTION get_parseid_for_csr (p_csr_id NUMBER)
      RETURN NUMBER
   IS
      v_parse_id   NUMBER;
   BEGIN
      BEGIN
         v_parse_id := cursor_to_stmt_map (TO_CHAR(p_csr_id)).parse_id;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            v_parse_id := 1;
      END;

      RETURN (v_parse_id);
   END;

   -- Get a sequence number
   FUNCTION get_seq_no
      RETURN NUMBER
   IS
      v_number   NUMBER;
   BEGIN
      SELECT quest_soo_at_sequence.NEXTVAL
        INTO v_number
        FROM DUAL;

      RETURN (v_number);
   END;

   --
   -- Process a BINDING line.  This line contains the cursor ID,
   -- but nothing else, so just clear the bind area ready for further data
   --
   /* Oracle9i example:

      BINDS #2:
        bind 0: dty=11 mxl=16(16) mal=00 scl=00 pre=00 oacflg=18 oacfl2=1 size=16 offset=0
        bfp=b7a11ca8 bln=16 avl=16 flg=05
        value=000001CD.0013.0001

      Oracle10g idea:

      BINDS #2:
        kkscoacd
        Bind#0
        oacdty=02 mxl=22(22) mxlc=00 mal=00 scl=00 pre=00
        oacflg=08 fl2=0001 frm=00 csi=00 siz=24 off=0
        kxsbbbfp=0819aed4  bln=22  avl=03  flg=05
        value=1442
        */
   --
   PROCEDURE process_bind (p_line IN OUT NOCOPY VARCHAR2)
   IS
      v_csr_id        NUMBER;
      v_sql_id        NUMBER;
      v_parse_id      NUMBER;
      v_empty_binds   bind_set_typ;
   BEGIN
      -- When we see a Bind line, we just clear the bind
      -- data structure for that sql statement/execution
      DEBUG (0, p_line);
      v_csr_id := get_stat (p_line, '#', ':');           -- Get cursor number
      DEBUG (0, SUBSTR ('Value of v_csr_id=' || v_csr_id, 1, 255));
      v_sql_id := get_sqlid_for_csr (v_csr_id);
      g_currently_binding_sql := v_sql_id;
      g_sql_binds (v_sql_id) := v_empty_binds;
   END;

   --
   -- Add new bind entry (value not known yet)
   --
   PROCEDURE add_new_bind (p_sql_id NUMBER, v_bind_id NUMBER)
   IS
      v_sql_binds   bind_set_typ;
   BEGIN
      IF g_sql_binds.EXISTS (p_sql_id)
      THEN
         -- update and existing entry
         g_sql_binds (p_sql_id) (v_bind_id) := NULL;
      ELSE
         -- add a new entry
         v_sql_binds (v_bind_id) := NULL;
         g_sql_binds (p_sql_id) := v_sql_binds;
      END IF;
   END;

   --
   -- Process bind data
   --
   /*
      BINDS #2:
        bind 0: dty=11 mxl=16(16) mal=00 scl=00 pre=00 oacflg=18 oacfl2=1 size=16 offset=0
        bfp=b7a11ca8 bln=16 avl=16 flg=05
        value=000001CD.0013.0001

      Oracle10g idea:

      BINDS #2:
        kkscoacd
        Bind#0
        oacdty=02 mxl=22(22) mxlc=00 mal=00 scl=00 pre=00
        oacflg=08 fl2=0001 frm=00 csi=00 siz=24 off=0
        kxsbbbfp=0819aed4  bln=22  avl=03  flg=05
        value=1442   */
   PROCEDURE process_binddata (p_line IN OUT NOCOPY VARCHAR2)
   IS
      v_bind_id     NUMBER;
      v_value       VARCHAR2 (2000);
      v_sql_binds   bind_set_typ;
   BEGIN
      DEBUG (0, 'Bind: ' || p_line);

      IF p_line LIKE '%Bind#%'                                -- 10g bind row
      THEN
         -- Oracle indexes bind ids starting at 0!
         v_bind_id := get_stat (p_line, 'Bind#') + 1;
         add_new_bind (g_currently_binding_sql, v_bind_id);
         DEBUG (0, 'Bind variable# ' || v_bind_id);
      ELSIF p_line LIKE '%bind%dty%'                            -- 9i bind row
      THEN
         v_bind_id := get_stat (p_line, 'bind', ':') + 1;
         add_new_bind (g_currently_binding_sql, v_bind_id);
         DEBUG (0, 'Bind variable# ' || v_bind_id);
      ELSIF p_line LIKE '%value=%'
      THEN
         v_value := get_string (p_line, 'value=');
         -- This should have been created already (assertion?)
         v_bind_id := g_sql_binds (g_currently_binding_sql).COUNT;
         g_sql_binds (g_currently_binding_sql) (v_bind_id) := v_value;
         DEBUG (0, v_value);
      END IF;
   END;

   --
   -- Return the text of an Oracle error code
   -- Had some intention of doing additional processing in here
   -- but looks like this is redundent for now
   --
   FUNCTION ERROR_TEXT (ERROR_CODE NUMBER)
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN (SQLERRM (ERROR_CODE));
   END;

   --
   -- Return the type of SQL trace line being processed
   --
   FUNCTION get_line_type (p_line IN OUT NOCOPY VARCHAR2)
      RETURN VARCHAR2
   IS
      v_linetype       VARCHAR2 (20) := 'UNKNOWN';
      v_parsing_st     VARCHAR2 (30) := 'PARSING IN CURSOR #';
      v_parse_st       VARCHAR2 (30) := 'PARSE #';
      v_exec_st        VARCHAR2 (30) := 'EXEC #';
      v_fetch_st       VARCHAR2 (30) := 'FETCH #';
      v_wait_st        VARCHAR2 (30) := 'WAIT #';
      v_stat_st        VARCHAR2 (30) := 'STAT #';
      v_bind_st        VARCHAR2 (30) := 'BINDS #';
      v_parse_err_st   VARCHAR2 (30) := 'PARSE ERROR #';
      v_error_st       VARCHAR2 (30) := 'ERROR #';
      v_end_of_st      VARCHAR2 (30) := 'END OF STMT';
   BEGIN
      v_linetype :=
         CASE
            WHEN    g_previous_line_type = 'PARSING'
                 OR g_previous_line_type = 'SQLTEXT'
               THEN CASE
                      WHEN p_line LIKE v_end_of_st || '%'
                         THEN 'END OF STMT'
                      ELSE 'SQLTEXT'
                   END
            WHEN p_line LIKE v_fetch_st || '%'
               THEN 'FETCH'
            WHEN p_line LIKE v_wait_st || '%'
               THEN 'WAIT'
            WHEN p_line LIKE v_exec_st || '%'
               THEN 'EXEC'
            WHEN p_line LIKE v_parsing_st || '%'
               THEN 'PARSING'
            WHEN p_line LIKE v_parse_st || '%'
               THEN 'PARSE'
            WHEN p_line LIKE v_bind_st || '%'
               THEN 'BIND'
            WHEN p_line LIKE v_stat_st || '%'
               THEN 'STAT'
            WHEN p_line LIKE 'Oracle Database %Release%'
               THEN 'HEADER'
            WHEN p_line LIKE '*** SESSION ID:%'
               THEN 'SESSIONID'
            WHEN    g_previous_line_type = 'BIND'
                 OR g_previous_line_type = 'BINDDATA'
               THEN 'BINDDATA'
            WHEN p_line LIKE v_error_st || '%'
               THEN 'ERROR'
            WHEN p_line LIKE v_parse_err_st || '%'
               THEN 'PARSE_ERROR'
            /* Error parse text continues until we see something else */
         WHEN g_previous_line_type IN ('PARSE_ERROR', 'PARSE_ERRORTEXT')
               THEN 'PARSE_ERRORTEXT'
            ELSE 'UNKNOWN'
         END;

      IF v_linetype = 'HEADER' AND p_line LIKE 'Oracle Database %Release%'
      THEN
         g_trace_file.oracle_version := p_line;
      END IF;

      DEBUG (0, g_previous_line_type || '-' || v_linetype || ' : ' || p_line);
      g_previous_line_type := v_linetype;
      RETURN (v_linetype);
   END;

   --
   -- Open the tracefile and return file handle
   --
   FUNCTION open_tracefile (p_filename VARCHAR2)
      RETURN UTL_FILE.file_type
   IS
   BEGIN
      RETURN (UTL_FILE.fopen (LOCATION          => g_directory_name,
                              filename          => p_filename,
                              open_mode         => 'R',
                              max_linesize      => 32767
                             )
             );
   EXCEPTION
      WHEN OTHERS
      THEN
         raise_application_error (-20001,
                                     'Error '
                                  || SQLCODE
                                  || ' when opening file '
                                  || p_filename
                                  || ' (does file exist?) '
                                  || SQLERRM (SQLCODE)
                                 );
   END;

   --
   -- Read a line return EOF indicator at EOF
   --
   PROCEDURE read_line (
      p_file_hdl         UTL_FILE.file_type,
      p_line       OUT   VARCHAR2,
      p_eof        OUT   BOOLEAN
   )
   IS
   BEGIN
      p_eof := FALSE;
      UTL_FILE.get_line (p_file_hdl, p_line);
   EXCEPTION
      WHEN NO_DATA_FOUND
      THEN
         p_eof := TRUE;
   END;

   -- Get the string value of a parameter
   FUNCTION get_parameter (p_parameter_name VARCHAR2)
      RETURN VARCHAR2
   IS
      v_parameter_value   VARCHAR2 (32767);
      v_instance_name     VARCHAR2 (16);
   BEGIN
      execute immediate 'SELECT instance_name
                         FROM v$instance
                         WHERE  ROWNUM < 2' INTO v_instance_name;

      execute immediate 'SELECT REPLACE(VALUE, ''@'', :v_instance_name)
                         FROM v$parameter
                         WHERE UPPER (NAME) = UPPER (:p_parameter_name )' INTO v_parameter_value USING IN v_instance_name, p_parameter_name;

      RETURN (v_parameter_value);
   END;

   ---
   -- Check if there is directory of the given name
   --
   FUNCTION is_directory (p_dirname VARCHAR2)
      RETURN BOOLEAN
   IS
      v_count   NUMBER := 0;
   BEGIN
      SELECT COUNT (*)
        INTO v_count
        FROM all_directories
       WHERE directory_name = p_dirname;

      RETURN (CASE
                 WHEN v_count = 0
                    THEN FALSE
                 ELSE TRUE
              END);
   END;

   --
   -- Create a directory to read trace file.
   --
   PROCEDURE create_directory (p_dirname VARCHAR2, p_dirpath VARCHAR2)
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      v_sql_text   VARCHAR2 (4000);
   BEGIN
      v_sql_text :=
            'CREATE OR REPLACE DIRECTORY '
         || p_dirname
         || ' AS '''
         || p_dirpath
         || '''';

--      v_sql_text := q'# CREATE OR REPLACE DIRECTORY '|| p_dirname || ' AS ' ||p_dirpath || '#';
      EXECUTE IMMEDIATE v_sql_text;
   EXCEPTION
      WHEN OTHERS
      THEN
         raise_application_error
            (-20003,
                'Error '
             || SQLCODE
             || ' when creating directory.  Your account probably lacks CREATE ANY DIRECTORY privilege.'
            );
   END create_directory;

   --
   -- Add execution statistics to the SQL statement summary data
   --
   PROCEDURE add_exec_stats (
      p_exec_line /*IN OUT NOCOPY */  quest_soo_at_sql_executions%ROWTYPE
   )
   IS
      v_sql_id   NUMBER;
   BEGIN
      v_sql_id := p_exec_line.sql_id;
      g_sql_statement_list (v_sql_id).execute_count :=
                            g_sql_statement_list (v_sql_id).execute_count + 1;
      g_sql_statement_list (v_sql_id).execute_elapsed :=
         g_sql_statement_list (v_sql_id).execute_elapsed
         + p_exec_line.elapsed;
      g_sql_statement_list (v_sql_id).execute_cpu :=
                g_sql_statement_list (v_sql_id).execute_cpu + p_exec_line.cpu;
      g_sql_statement_list (v_sql_id).execute_physical_reads :=
           g_sql_statement_list (v_sql_id).execute_physical_reads
         + p_exec_line.physical_reads;
      g_sql_statement_list (v_sql_id).execute_current_reads :=
           g_sql_statement_list (v_sql_id).execute_current_reads
         + p_exec_line.current_reads;
      g_sql_statement_list (v_sql_id).execute_consistent_reads :=
           g_sql_statement_list (v_sql_id).execute_consistent_reads
         + p_exec_line.consistent_reads;
      g_sql_statement_list (v_sql_id).execute_rows :=
          g_sql_statement_list (v_sql_id).execute_rows + p_exec_line.row_count;
   END;

   --
   -- Add fetch statistics to the SQL statement summary data
   --
   PROCEDURE add_fetch_stats (
      p_fetch_line   IN OUT NOCOPY   quest_soo_at_sql_fetch%ROWTYPE
   )
   IS
      v_sql_id   NUMBER;
   BEGIN
      v_sql_id := p_fetch_line.sql_id;
      g_sql_statement_list (v_sql_id).fetch_count :=
           g_sql_statement_list (v_sql_id).fetch_count
         + p_fetch_line.fetch_count;
      g_sql_statement_list (v_sql_id).fetch_elapsed :=
          g_sql_statement_list (v_sql_id).fetch_elapsed + p_fetch_line.elapsed;
      g_sql_statement_list (v_sql_id).fetch_cpu :=
                  g_sql_statement_list (v_sql_id).fetch_cpu + p_fetch_line.cpu;
      g_sql_statement_list (v_sql_id).fetch_physical_reads :=
           g_sql_statement_list (v_sql_id).fetch_physical_reads
         + p_fetch_line.physical_reads;
      g_sql_statement_list (v_sql_id).fetch_current_reads :=
           g_sql_statement_list (v_sql_id).fetch_current_reads
         + p_fetch_line.current_reads;
      g_sql_statement_list (v_sql_id).fetch_consistent_reads :=
           g_sql_statement_list (v_sql_id).fetch_consistent_reads
         + p_fetch_line.consistent_reads;
      g_sql_statement_list (v_sql_id).fetch_rows :=
           g_sql_statement_list (v_sql_id).fetch_rows + p_fetch_line.row_count;
   END;

   --
   -- New parse for an existing SQL statement
   --
   PROCEDURE new_parse (
      p_sql_id                          NUMBER,
      p_csr_id                          NUMBER,
      p_sql_statement   IN OUT NOCOPY   quest_soo_at_sql_statement%ROWTYPE,
      p_parsing_line    IN OUT NOCOPY   quest_soo_at_parse_cursor%ROWTYPE
   )
   IS
      v_parse_id       NUMBER;
      v_sql_parse_id   NUMBER;
   BEGIN
      -- This cursor number now "belongs" to this SQL
      cursor_to_stmt_map (TO_CHAR(p_csr_id)).sql_id := p_sql_id;
      v_parse_id := g_parse_list.COUNT + 1;              -- absolute parse id
      v_sql_parse_id := g_sql_list (p_sql_id).parse_list.COUNT + 1;
      cursor_to_stmt_map (TO_CHAR(p_csr_id)).parse_id := v_sql_parse_id;
      p_parsing_line.trace_file_id := g_trace_file_id;
      p_parsing_line.sql_id := p_sql_id;
      p_parsing_line.parse_id := v_sql_parse_id;
      p_parsing_line.session_id := g_session_id;
      p_parsing_line.serial_number := g_serial;
      p_parsing_line.cursor_no := p_csr_id;
      g_parse_list (v_parse_id) := p_parsing_line;
      g_sql_list (p_sql_id).parse_list (v_sql_parse_id) := v_parse_id;

      --
      -- Set the base "tim" for the tracefile if not already set
      --
      IF g_trace_file.base_tim_value IS NULL
      THEN
         -- This is the first "tim" value, save it to use as an offset
         -- when calculating real times later
         g_trace_file.base_tim_value := p_parsing_line.tim;
      END IF;
   -- pointer to parse record
   END;

   --
   -- Get the SQL text (max 2000 bytes)
   --
   FUNCTION get_sql_text (p_sql_id NUMBER)
      RETURN VARCHAR2
   IS
      v_sqltext       VARCHAR2 (4000) := '';
      v_sqlpiece      VARCHAR2 (4000);
      v_sql_text_id   NUMBER;
   BEGIN
      FOR i IN 1 .. g_sql_list (p_sql_id).sql_text_list.COUNT
      LOOP
         v_sql_text_id := g_sql_list (p_sql_id).sql_text_list (i);
         v_sqlpiece := g_sql_stmt_pieces (v_sql_text_id).sql_text;

         IF (LENGTH (v_sqltext) + LENGTH (v_sqlpiece)) > 1998
         THEN
            EXIT;
         ELSE
            v_sqltext := v_sqltext || v_sqlpiece;
         END IF;
      END LOOP;

      IF (LENGTH (v_sqltext) > 2000)
      THEN
         v_sqltext := SUBSTR (v_sqltext, 1, 2000);
      END IF;

      RETURN (v_sqltext);
   END;

   --
   -- Brand new SQL statement
   --
   FUNCTION new_sql (
      p_csr_id                          NUMBER,
      p_sql_statement   IN OUT NOCOPY   quest_soo_at_sql_statement%ROWTYPE,
      p_parsing_line    IN OUT NOCOPY   quest_soo_at_parse_cursor%ROWTYPE,
      p_hashaddr                        VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      g_sql_id := g_sql_id + 1;
      p_sql_statement.sql_id := g_sql_id;
      p_sql_statement.trace_file_id := g_trace_file_id;
      -- Hash value lookup
      p_sql_statement.parse_count := 0;
      p_sql_statement.parse_elapsed := 0;
      p_sql_statement.parse_cpu := 0;
      p_sql_statement.parse_physical_reads := 0;
      p_sql_statement.parse_current_reads := 0;
      p_sql_statement.parse_consistent_reads := 0;
      p_sql_statement.parse_rows := 0;
      p_sql_statement.execute_count := 0;
      p_sql_statement.execute_elapsed := 0;
      p_sql_statement.execute_cpu := 0;
      p_sql_statement.execute_physical_reads := 0;
      p_sql_statement.execute_current_reads := 0;
      p_sql_statement.execute_consistent_reads := 0;
      p_sql_statement.execute_rows := 0;
      p_sql_statement.fetch_count := 0;
      p_sql_statement.fetch_elapsed := 0;
      p_sql_statement.fetch_cpu := 0;
      p_sql_statement.fetch_physical_reads := 0;
      p_sql_statement.fetch_current_reads := 0;
      p_sql_statement.fetch_consistent_reads := 0;
      p_sql_statement.fetch_rows := 0;
      g_sql_statement_list (g_sql_id) := p_sql_statement;
      g_sql_list (g_sql_id).sql_stmt := g_sql_id;
      g_sql_lookup (p_hashaddr) := g_sql_id;
      new_parse (g_sql_id, p_csr_id, p_sql_statement, p_parsing_line);
      RETURN (g_sql_id);
   END;

   --
   -- Initialize a new SQL instance (we may or may not have an entry
   --  for an identical SQL)
   --
   FUNCTION initialize_sql (
      p_csr_id                          NUMBER,
      p_sql_statement   IN OUT NOCOPY   quest_soo_at_sql_statement%ROWTYPE,
      p_parsing_line    IN OUT NOCOPY   quest_soo_at_parse_cursor%ROWTYPE
   )
      RETURN NUMBER
   IS
      v_sql_id     NUMBER;
      v_hashaddr   VARCHAR2 (40);
   BEGIN
      v_hashaddr :=
                 p_sql_statement.address || '-' || p_sql_statement.hash_value;

      IF g_sql_lookup.EXISTS (v_hashaddr)        -- we've seen this hv before
      THEN
         v_sql_id := g_sql_lookup (v_hashaddr);
         new_parse (v_sql_id, p_csr_id, p_sql_statement, p_parsing_line);
         DEBUG (0,
                'hashaddr ' || v_hashaddr || ' already allocated to '
                || v_sql_id
               );
      ELSE
         v_sql_id :=
              new_sql (p_csr_id, p_sql_statement, p_parsing_line, v_hashaddr);
      END IF;

      RETURN (v_sql_id);
   END;

   --
   -- Sometimes waits are listed against cursor "0".  This SQL record
   -- holds those statistics
   --
   PROCEDURE initialize_sqlzero
   IS
      v_csr_id          NUMBER                                := 0;
      v_sql_id          NUMBER;
      v_exec_id         NUMBER;
      v_sql_statement   quest_soo_at_sql_statement%ROWTYPE;
      v_parsing_line    quest_soo_at_parse_cursor%ROWTYPE;
      v_exec_line       quest_soo_at_sql_executions%ROWTYPE;
   BEGIN
      v_sql_statement.trace_file_id := g_trace_file_id;
      v_sql_statement.address := '000000';
      v_sql_statement.hash_value := '0';
      v_sql_id := initialize_sql (v_csr_id, v_sql_statement, v_parsing_line);
      -- Dummy exec line to pick up waits on cursor "0"
      v_exec_line.sql_id := v_sql_id;
      v_exec_line.parse_id := 1;
      v_exec_line.execution_id := 1;
      v_exec_line.trace_file_id := g_trace_file_id;
      v_exec_id := g_exec_list.COUNT + 1;
      g_exec_list (v_exec_id) := v_exec_line;
      g_sql_list (v_sql_id).exec_list (1) := 1;

      g_sql_zero := v_sql_id;
   END;

   --
   -- Processing a "PARSING" line in the SQL trace file
   --
   PROCEDURE process_parsing (p_line VARCHAR2)
   IS
      v_parsing_line    quest_soo_at_parse_cursor%ROWTYPE;
      v_sql_statement   quest_soo_at_sql_statement%ROWTYPE;
      v_csr_id          NUMBER;
      v_sql_id          NUMBER;
      v_ad_start        NUMBER;
      v_ad_end          NUMBER;
      v_sql_list        sql_address_list;
      v_hashaddr        VARCHAR2 (40);
      v_idx             NUMBER;
   BEGIN
      -- break down the parsing line.
      v_csr_id := get_stat (p_line, '#', 'len=');
      v_parsing_line.len := get_stat (p_line, 'len=', 'dep=');
      v_parsing_line.dep := get_stat (p_line, 'dep=', 'uid=');
      v_parsing_line.userid := get_stat (p_line, 'uid=', 'oct=');
      v_parsing_line.oct := get_stat (p_line, 'oct=', 'lid=');
      v_parsing_line.lid := get_stat (p_line, 'lid=', 'tim=');
      v_parsing_line.tim := get_stat (p_line, 'tim=', 'hv=');
      v_sql_statement.hash_value := get_stat (p_line, 'hv=', 'ad=');
      -- The address (ad) is single quoted
      v_ad_start := INSTR (p_line, 'ad=') + 4;
      v_ad_end := INSTR (p_line, '''', v_ad_start);
      v_sql_statement.address :=
                           SUBSTR (p_line, v_ad_start, v_ad_end - v_ad_start);
                           --v_parsing_line.session_id:=g_session_id;
      --
      -- Create the new sql entry
      --
      v_sql_id := initialize_sql (v_csr_id, v_sql_statement, v_parsing_line);
   --g_trace_sql (v_sql_id).parsing_data := v_parsing_line;
   --
   END;

   --
   -- process a change of session identifier
   --
   PROCEDURE process_sessionid (p_line IN OUT NOCOPY VARCHAR2)
   IS
      v_string_date   VARCHAR2 (20);
      v_sessionid     NUMBER;
      v_serial        NUMBER;
   BEGIN
      g_session_id := get_stat (p_line, '(', '.');
      g_serial := get_stat (p_line, '.', ')');

      -- If not already set, set base date here  (since this is often the first)
      IF g_trace_file.base_datetime_value IS NULL
      THEN
         v_string_date := get_string (p_line, ')', '.');
         v_string_date := replace(v_string_date,'T',' ');
         g_trace_file.base_datetime_value :=
                            TO_DATE (v_string_date, ' YYYY-MM-DD HH24:MI:SS');
      END IF;
   END;

   --
   -- Save bind variable data (if any) for an execution
   --
   FUNCTION add_exec_binds (
      p_exec   IN OUT NOCOPY   quest_soo_at_sql_executions%ROWTYPE
   )
      RETURN VARCHAR2
   IS
      v_sql_id      NUMBER;
      v_binds       bind_set_typ;
      v_bind_row    quest_soo_at_sql_binds%ROWTYPE;
      v_bind_vals   VARCHAR2 (32767)                 := '';
   BEGIN
      -- get the current binds recorded against this sql_id
      v_sql_id := p_exec.sql_id;

      IF g_sql_binds.EXISTS (p_exec.sql_id)
      THEN
         v_binds := g_sql_binds (p_exec.sql_id);

         IF v_binds.COUNT > 0
         THEN
            FOR i IN 1 .. v_binds.COUNT
            LOOP
               --DEBUG(2,'bind# '||i);
               v_bind_row.trace_file_id := g_trace_file_id;
               v_bind_row.sql_id := p_exec.sql_id;
               v_bind_row.parse_id := p_exec.parse_id;
               v_bind_row.execution_id := p_exec.execution_id;
               v_bind_row.bind_var_id := i;

               BEGIN
                  v_bind_row.VALUE := v_binds (i);
               EXCEPTION
                  WHEN NO_DATA_FOUND
                  THEN
                     v_bind_row.VALUE := 'NULL';
               END;

               g_bind_list (g_bind_list.COUNT + 1) := v_bind_row;
               v_bind_vals :=
                  v_bind_vals || 'Bind#' || i || '= "' || v_bind_row.VALUE
                  || '" ';
            END LOOP;
         END IF;
      END IF;

      IF LENGTH (v_bind_vals) > 400
      THEN
         v_bind_vals := SUBSTR (v_bind_vals, 1, 3999);
      END IF;

      RETURN (v_bind_vals);
   END;

   --
   -- Process an EXEC line
   --
   PROCEDURE process_exec (p_line IN OUT NOCOPY VARCHAR2)
   IS
      v_sql_id        NUMBER;
      v_csr_id        NUMBER;
      v_exec_id       NUMBER;                          -- global execution id
      v_sql_exec_id   NUMBER;                      -- exec within SQL stmt id
      v_parse_id      NUMBER;
   BEGIN
      v_csr_id := get_stat (p_line, '#', ':c=');         -- Get cursor number
      v_sql_id := get_sqlid_for_csr (v_csr_id);
      -- retrieve our sql for this csr
      v_exec_id := g_exec_list.COUNT + 1;
      v_sql_exec_id := g_sql_list (v_sql_id).exec_list.COUNT + 1;
      g_exec_list (v_exec_id).trace_file_id := g_trace_file_id;
      g_exec_list (v_exec_id).sql_id := v_sql_id;
      g_exec_list (v_exec_id).parse_id :=
                                       g_sql_list (v_sql_id).parse_list.COUNT;
      g_exec_list (v_exec_id).execution_id := v_sql_exec_id;
      --
      -- Parse the trace line
      --
      g_exec_list (v_exec_id).cpu := get_stat (p_line, ':c=', ',e=');
      g_exec_list (v_exec_id).elapsed := get_stat (p_line, ',e=', ',p=');
      g_exec_list (v_exec_id).physical_reads :=
                                             get_stat (p_line, ',p=', ',cr=');
      g_exec_list (v_exec_id).consistent_reads :=
                                            get_stat (p_line, ',cr=', ',cu=');
      g_exec_list (v_exec_id).current_reads :=
                                           get_stat (p_line, ',cu=', ',mis=');
      g_exec_list (v_exec_id).libcache_misses :=
                                            get_stat (p_line, ',mis=', ',r=');
      g_exec_list (v_exec_id).row_count := get_stat (p_line, ',r=', ',dep=');
      g_exec_list (v_exec_id).DEPTH := get_stat (p_line, ',dep=', ',og=');
      g_exec_list (v_exec_id).tim := get_stat (p_line, ',tim=');

      IF g_process_binds
      THEN
         g_exec_list (v_exec_id).bind_vals :=
                                     add_exec_binds (g_exec_list (v_exec_id));
      END IF;

      --
      -- Add the parsed line to our SQL structure
      --
      add_exec_stats (g_exec_list (v_exec_id));
      g_sql_list (v_sql_id).exec_list (v_sql_exec_id) := v_exec_id;

      --
      -- If this is the first execution, add any waits that may have occured
      -- between the PARSE and EXEC entries
      --
      IF v_sql_exec_id = 1
      THEN
         process_pending_waits (v_sql_id);
      END IF;
   END;

   --
   -- Add parse statistics to the summary statistics
   --
   PROCEDURE add_parse_stats (
      p_parse_line   IN OUT NOCOPY   quest_soo_at_parse_cursor%ROWTYPE
   )
   IS
      v_sql_id   NUMBER;
   BEGIN
      v_sql_id := p_parse_line.sql_id;
      g_sql_statement_list (v_sql_id).parse_count :=
                              g_sql_statement_list (v_sql_id).parse_count + 1;
      g_sql_statement_list (v_sql_id).parse_elapsed :=
         g_sql_statement_list (v_sql_id).parse_elapsed + p_parse_line.elapsed;
      g_sql_statement_list (v_sql_id).parse_cpu :=
                 g_sql_statement_list (v_sql_id).parse_cpu + p_parse_line.cpu;
      g_sql_statement_list (v_sql_id).parse_physical_reads :=
           g_sql_statement_list (v_sql_id).parse_physical_reads
         + p_parse_line.physical_reads;
      g_sql_statement_list (v_sql_id).parse_current_reads :=
           g_sql_statement_list (v_sql_id).parse_current_reads
         + p_parse_line.current_reads;
      g_sql_statement_list (v_sql_id).parse_consistent_reads :=
           g_sql_statement_list (v_sql_id).parse_consistent_reads
         + p_parse_line.consistent_reads;
      g_sql_statement_list (v_sql_id).parse_rows :=
           g_sql_statement_list (v_sql_id).parse_rows + p_parse_line.row_count;
   END;

   --
   -- process a PARSE line (which is always preceded by a PARSING line)
   --
   PROCEDURE process_parse (p_line VARCHAR2)
   IS
      v_sql_id         NUMBER;
      v_csr_id         NUMBER;
      v_sql_parse_id   NUMBER;
      v_parse_id       NUMBER;
   BEGIN
      v_csr_id := get_stat (p_line, '#', ':c=');         -- Get cursor number
      v_sql_id := get_sqlid_for_csr (v_csr_id);
                                             -- retrieve our sql for this csr
      -- A PARSE line follows a PARSING line, so get the details for that line
      -- First get pointer to the parse entry from the sql entry
      v_sql_parse_id := g_sql_list (v_sql_id).parse_list.COUNT;
      v_parse_id := g_sql_list (v_sql_id).parse_list (v_sql_parse_id);
      --
      -- Parse the trace line
      --
      g_parse_list (v_parse_id).cpu := get_stat (p_line, ':c=', ',e=');
      g_parse_list (v_parse_id).elapsed := get_stat (p_line, ',e=', ',p=');
      g_parse_list (v_parse_id).physical_reads :=
                                             get_stat (p_line, ',p=', ',cr=');
      g_parse_list (v_parse_id).consistent_reads :=
                                            get_stat (p_line, ',cr=', ',cu=');
      g_parse_list (v_parse_id).current_reads :=
                                           get_stat (p_line, ',cu=', ',mis=');
      g_parse_list (v_parse_id).libcache_misses :=
                                            get_stat (p_line, ',mis=', ',r=');
      g_parse_list (v_parse_id).row_count :=
                                            get_stat (p_line, ',r=', ',dep=');
      g_parse_list (v_parse_id).dep := get_stat (p_line, ',dep=', ',og=');
      add_parse_stats (g_parse_list (v_parse_id));
   END;

   --
   -- Get an operation id for an operation ring
   --
   FUNCTION get_operation_id (
      p_op_string   quest_soo_at_operations.operation_string%TYPE
   )
      RETURN INTEGER
   IS
      v_op_id   NUMBER;
   BEGIN
      IF g_operations_idx.EXISTS (p_op_string)
      THEN
         v_op_id := g_operations_idx (p_op_string);
      ELSE
         v_op_id := g_operations_list.COUNT + 1;
         g_operations_list (v_op_id).operation_string := p_op_string;
         g_operations_list (v_op_id).operation_id := v_op_id;
         g_operations_list (v_op_id).trace_file_id := g_trace_file_id;
         g_operations_idx (p_op_string) := v_op_id;
      END IF;

      RETURN (v_op_id);
   END;

   --
   -- Process STAT (explain plan) lines
   --
   --  10g: 'STAT #(\d+) id=(\d+) cnt=(\d+) pid=(\d+) pos=(\d+) obj=(\d+) op=''(.*) \(cr=(\d+) pr=(\d+) pw=(\d+) time=(\d+) us\)''(.*)';*/
   -- 9i: STAT #1 id=1 cnt=1 pid=0 pos=1 obj=222 op='TABLE ACCESS FULL DUAL (cr=3 r=0 w=0 time=91 us)'
   PROCEDURE process_stat (p_line VARCHAR2)
   IS
      v_stat_line      quest_soo_at_execution_plan%ROWTYPE;
      v_op             quest_soo_at_operations.operation_string%TYPE;
      v_csr_id         NUMBER;
      v_sql_id         NUMBER;
      v_parse_id       NUMBER;
      v_sql_parse_id   NUMBER;
      v_stat_id        NUMBER;
      v_sql_stat_id    NUMBER;
   BEGIN
      v_csr_id := get_stat (p_line, '#', 'id=');         -- Get cursor number
      v_sql_id := get_sqlid_for_csr (v_csr_id);

      IF v_sql_id <> g_sql_zero
      THEN            -- only process stat lines for sqls we have seen parsed
         -- retrieve our sql for this csr
         v_sql_parse_id := get_parseid_for_csr (v_csr_id);
         -- the most recent parse for this sql
         v_stat_line.trace_file_id := g_trace_file_id;
         v_stat_line.sql_id := v_sql_id;
         v_stat_line.parse_id := v_sql_parse_id;
         v_stat_line.ID := get_stat (p_line, 'id=', 'cnt=');
         v_stat_line.cnt := get_stat (p_line, 'cnt=', 'pid=');
         v_stat_line.pid := get_stat (p_line, 'pid=', 'pos=');
         v_stat_line.pos := get_stat (p_line, 'pos=', 'obj=');
         v_stat_line.obj := get_stat (p_line, 'obj=', 'op=');
         v_op := get_string (p_line, 'op=''', '(cr=');
         v_stat_line.operation_id := get_operation_id (v_op);

         IF (g_major_oracle_version = 9)
         THEN
            v_stat_line.cr := get_stat (p_line, 'cr=', 'r=');
            v_stat_line.pr := get_stat (p_line, ' r=', 'w=');
            v_stat_line.pw := get_stat (p_line, ' w=', 'time=');
         ELSE
            v_stat_line.cr := get_stat (p_line, 'cr=', 'pr=');
            v_stat_line.pr := get_stat (p_line, 'pr=', 'pw=');
            v_stat_line.pw := get_stat (p_line, 'pw=', 'time=');
         END IF;

         v_stat_line.time_us := get_stat (p_line, 'time=', 'us');
         -- at stat to global stat array
         v_stat_id := g_stat_list.COUNT + 1;
         g_stat_list (v_stat_id) := v_stat_line;
      END IF;
   -- add reference to stat in sql structure list
   -- TODO:  this might not be neccessary unless we tally plan step data pre-insert
   -- Uncomment to create the entries in the sql structure
   /*v_sql_stat_id:=g_sql_list(v_sql_id).stat_list.count+1;
   g_sql_list(v_sql_id).stat_list(v_sql_stat_id):=v_stat_id; */
   END;

   --
   -- Process SQL text lines, chopping them if neccessary into smaller
   -- fragments
   --
   PROCEDURE process_sqltext (p_line VARCHAR2)
   IS
      v_sqlline_count    NUMBER           := 0;
      v_sql_text         VARCHAR2 (32767);
      v_sql_text_frag    VARCHAR2 (1000);
      v_max_line_len     NUMBER           := 256;
      v_all_sql_loaded   BOOLEAN          := FALSE;
      v_counter          INTEGER          := 0;
      v_sql_text_id      NUMBER;               -- id within the sql structure
      v_text_id          NUMBER;           -- id within the global text array
   BEGIN
      IF g_sql_list (g_sql_id).sql_known = FALSE
      THEN
         v_sql_text := p_line;

         WHILE (NOT v_all_sql_loaded)
         LOOP
            -- Break the SQL up so each chunk is no bigger than max
            -- line legth
            v_sql_text_frag := SUBSTR (v_sql_text, 1, v_max_line_len);
            -- Add the piece to the global SQL array
            v_text_id := g_sql_stmt_pieces.COUNT + 1;
            v_sql_text_id := g_sql_list (g_sql_id).sql_text_list.COUNT + 1;
            g_sql_stmt_pieces (v_text_id).trace_file_id := g_trace_file_id;
            g_sql_stmt_pieces (v_text_id).sql_id := g_sql_id;
            g_sql_stmt_pieces (v_text_id).piece_no := v_sql_text_id;
            g_sql_stmt_pieces (v_text_id).sql_text := v_sql_text_frag;
            -- Add a pointer to this piece within the SQL structure
            g_sql_list (g_sql_id).sql_text_list (v_sql_text_id) := v_text_id;

            IF (LENGTH (v_sql_text) > v_max_line_len)
            THEN
               v_sql_text := SUBSTR (v_sql_text, v_max_line_len + 1);
--               = dbms_output.put_line(v_sql_text);
            ELSE
               v_all_sql_loaded := TRUE;
            END IF;

            v_counter := v_counter + 1;

            IF v_counter > 1000
            THEN                                       -- infinite loop panic!
               raise_application_error (-20002, 'Infinite loop feared');
            END IF;
         END LOOP;
      END IF;
   END;

   --
   -- Process and end of statement marker
   --
   PROCEDURE process_end_of_stmt (p_line VARCHAR2)
   IS
   BEGIN
      -- Note that we have all the SQL and do not have to add it again
      g_sql_list (g_sql_id).sql_known := TRUE;
   END;

   -- add the data from a  sql trace fetch entry to the previous fetch entry
   -- we do this to reduce the number of fetch rows we have to store.
   PROCEDURE merge_fetch (
      p_fetch_id                     NUMBER,
      p_fetch_line   IN OUT NOCOPY   quest_soo_at_sql_fetch%ROWTYPE
   )
   IS
      v_fetch_line   quest_soo_at_sql_fetch%ROWTYPE;
   BEGIN
      v_fetch_line := g_fetch_list (p_fetch_id);
      DEBUG (0,
                'Merging fetch '
             || v_fetch_line.fetch_id
             || ' with '
             || p_fetch_line.fetch_id
            );
      DEBUG (0, 'tim1=' || v_fetch_line.tim || ' tim2=' || p_fetch_line.tim);
      v_fetch_line.cpu := v_fetch_line.cpu + p_fetch_line.cpu;
      v_fetch_line.elapsed := v_fetch_line.elapsed + p_fetch_line.elapsed;
      v_fetch_line.physical_reads :=
                     v_fetch_line.physical_reads + p_fetch_line.physical_reads;
      v_fetch_line.consistent_reads :=
                 v_fetch_line.consistent_reads + p_fetch_line.consistent_reads;
      v_fetch_line.current_reads :=
                       v_fetch_line.current_reads + p_fetch_line.current_reads;
      v_fetch_line.row_count :=
                               v_fetch_line.row_count + p_fetch_line.row_count;
      v_fetch_line.fetch_count := v_fetch_line.fetch_count + 1;
      v_fetch_line.end_tim := p_fetch_line.tim;
      g_fetch_list (p_fetch_id) := v_fetch_line;
   END;

   --
   -- Process a FETCH line
   -- 'FETCH #(\d+):c=(\d+),e=(\d+),p=(\d+),cr=(\d+),cu=(\d+),mis=(\d+),r=(\d+),dep=(\d+),og=(\d+),tim=(\d+)(.*)'
   --
   PROCEDURE process_fetch (p_line VARCHAR2)
   IS
      v_sql_id          NUMBER;
      v_csr_id          NUMBER;
      v_sql_fetch_id    NUMBER;                   -- fetch within SQL stmt id
      v_fetch_id        NUMBER;                            -- global fetch id
      v_fetch_line      quest_soo_at_sql_fetch%ROWTYPE;
      v_prev_fetch      quest_soo_at_sql_fetch%ROWTYPE;
      v_prev_fetch_id   NUMBER;
   BEGIN
      -- References to the current sql, parse and execution
      v_csr_id := get_stat (p_line, '#', ':c=');         -- Get cursor number
      v_sql_id := get_sqlid_for_csr (v_csr_id);
      v_fetch_line.trace_file_id := g_trace_file_id;
      v_fetch_line.sql_id := v_sql_id;
      v_fetch_line.parse_id := g_sql_list (v_sql_id).parse_list.COUNT;
      v_fetch_line.execution_id := g_sql_list (v_sql_id).exec_list.COUNT;
      -- parse the line
      v_fetch_line.fetch_count := 1;
      v_fetch_line.cpu := get_stat (p_line, ':c=', ',e=');
      v_fetch_line.elapsed := get_stat (p_line, ',e=', ',p=');
      v_fetch_line.physical_reads := get_stat (p_line, ',p=', ',cr=');
      v_fetch_line.consistent_reads := get_stat (p_line, ',cr=', ',cu=');
      v_fetch_line.current_reads := get_stat (p_line, ',cu=', ',mis=');
      v_fetch_line.row_count := get_stat (p_line, ',r=', ',dep=');
      v_fetch_line.tim := get_stat (p_line, ',tim=');
      -- Compare with previous fetch and aggregate if warranted
      v_sql_fetch_id := g_sql_list (v_sql_id).fetch_list.COUNT + 1;
      v_fetch_line.fetch_id := v_sql_fetch_id;

      IF v_sql_fetch_id > 1
      THEN
         v_prev_fetch_id :=
                        g_sql_list (v_sql_id).fetch_list (v_sql_fetch_id - 1);
         v_prev_fetch := g_fetch_list (v_prev_fetch_id);
      END IF;

      IF     v_sql_fetch_id > 1
         AND (v_fetch_line.tim - v_prev_fetch.tim) < g_fetch_bunching_time
         AND v_fetch_line.parse_id = v_prev_fetch.parse_id
         AND v_fetch_line.execution_id = v_prev_fetch.execution_id
      THEN
         -- Previous fetch was within the last g_fetch_time seconds, so merge.
         merge_fetch (v_prev_fetch_id, v_fetch_line);
      ELSE                                                    -- add the fetch
         v_fetch_id := g_fetch_list.COUNT + 1;
         v_fetch_line.fetch_id := v_sql_fetch_id;
         g_fetch_list (v_fetch_id) := v_fetch_line;
         g_sql_list (v_sql_id).fetch_list (v_sql_fetch_id) := v_fetch_id;
      END IF;

      add_fetch_stats (v_fetch_line);
   END;

   --
   -- Add a wait entry associated with an execution
   --
   PROCEDURE add_wait_exec (
      p_wait_line   IN OUT NOCOPY   quest_soo_at_sql_waits%ROWTYPE
   )
   IS
      v_sql_id           NUMBER;
      v_wait_id          NUMBER;                           -- global fetch id
      v_wait_index       VARCHAR2 (60);
      v_exec_waits       quest_soo_at_sql_waits%ROWTYPE;
      v_sql_stmt         sql_stmt_typ;
      v_exec_wait_list   exec_wait_typ;
   BEGIN
      v_sql_id := p_wait_line.sql_id;

      -- Get the list of existing waits for this execution (if it exists)
      IF g_sql_list (v_sql_id).exec_wait_list.EXISTS
                                                    (p_wait_line.execution_id)
      THEN
         v_exec_wait_list :=
              g_sql_list (v_sql_id).exec_wait_list (p_wait_line.execution_id);
      END IF;

      -- the exec_wait_list is keyed by object/waitName
      v_wait_index := p_wait_line.event_id || '-' || p_wait_line.obj#;

      IF v_exec_wait_list.EXISTS (v_wait_index)
      THEN
         -- We already have an entry for this name/object combo for this execution
         -- so just increment the relevent counters
         v_wait_id := v_exec_wait_list (v_wait_index);
         v_exec_waits := g_wait_list (v_wait_id);
         v_exec_waits.wait_count := v_exec_waits.wait_count + 1;
         v_exec_waits.sum_elapsed :=
                           v_exec_waits.sum_elapsed + p_wait_line.sum_elapsed;
         v_exec_waits.sumsquares_elapsed :=
             v_exec_waits.sumsquares_elapsed + p_wait_line.sumsquares_elapsed;
         g_wait_list (v_wait_id) := v_exec_waits;
      ELSE
         -- First time we have seen this name/object combo for this execution
         -- so create a new entry for it;
         v_wait_id := g_wait_list.COUNT + 1;                     -- Global ID
         p_wait_line.wait_id := v_exec_wait_list.COUNT + 1;
         -- ID within the exec record
         g_wait_list (v_wait_id) := p_wait_line;
         -- Add a pointer in the SQL structure so we can find this later if
         -- we want to increment it
         v_exec_wait_list (v_wait_index) := v_wait_id;
         g_sql_list (v_sql_id).exec_wait_list (p_wait_line.execution_id) :=
                                                             v_exec_wait_list;
      END IF;
   END;

--
   -- Hold a wait that occurs before the execution;  we will attribute it
   -- later
   --
   PROCEDURE add_pending_waits (
      p_wait_line   IN OUT NOCOPY   quest_soo_at_sql_waits%ROWTYPE
   )
   IS
      v_pending_wait_id   NUMBER;
      v_sql_id            NUMBER;
      v_wait_list         number_tab_typ;
   BEGIN
      v_pending_wait_id := g_pending_waits.COUNT + 1;
      g_pending_waits (v_pending_wait_id) := p_wait_line;
      v_sql_id := p_wait_line.sql_id;

      IF g_pending_waits_sql_idx.EXISTS (v_sql_id)
      THEN
         v_wait_list := g_pending_waits_sql_idx (v_sql_id);
      END IF;

      v_wait_list (v_wait_list.COUNT + 1) := v_pending_wait_id;
      g_pending_waits_sql_idx (v_sql_id) := v_wait_list;
      DEBUG (0,
                'Added pending wait '
             || p_wait_line.event_id
             || ' for sql '
             || v_sql_id
            );
   END;

   --
   -- Add any waits that occured BEFORE the first execution marker to
   -- the first execution
   --
   PROCEDURE process_pending_waits (p_sql_id NUMBER)
   IS
      v_wait_line   quest_soo_at_sql_waits%ROWTYPE;
      v_wait_list   number_tab_typ;
   BEGIN
      IF g_pending_waits_sql_idx.EXISTS (p_sql_id)
      THEN
         DEBUG (0, 'Processing pending waits for sql ' || p_sql_id);
         v_wait_list := g_pending_waits_sql_idx (p_sql_id);

         FOR i IN 1 .. v_wait_list.COUNT
         LOOP
            v_wait_line := g_pending_waits (v_wait_list (i));
            v_wait_line.execution_id := 1;
            DEBUG (0,
                   ' sql ' || p_sql_id || ' wait nam=' || v_wait_line.event_id
                  );
            add_wait_exec (v_wait_line);
         END LOOP;

         g_pending_waits_sql_idx.DELETE (p_sql_id);
      END IF;
   END;

   PROCEDURE process_sql_error (p_line VARCHAR2)
   IS
      v_sql_id             NUMBER;
      v_csr_id             NUMBER;
      v_sql_parse_id       NUMBER;
      v_sql_execution_id   NUMBER;
      v_sql_error_id       NUMBER;                -- fetch within SQL stmt id
      v_error_code         NUMBER;                         -- global fetch id
      v_error_message      VARCHAR2 (2000);
      v_error_line         quest_soo_at_sql_exec_error%ROWTYPE;
   BEGIN
      -- DBMS_OUTPUT.put_line (p_line);
      -- References to the current sql, parse and execution
      v_csr_id := get_stat (p_line, '#', ':');           -- Get cursor number
      v_sql_id := get_sqlid_for_csr (v_csr_id);
      v_error_line.trace_file_id := g_trace_file_id;
      v_error_line.sql_id := v_sql_id;
      v_error_line.parse_id := g_sql_list (v_sql_id).parse_list.COUNT;
      v_error_line.execution_id := g_sql_list (v_sql_id).exec_list.COUNT;
      v_error_line.error_id := g_error_list.COUNT + 1;
      v_error_line.err := get_stat (p_line, 'err=', 'tim');
      v_error_line.SQLERRM := SQLERRM (-1 * v_error_line.err);
      g_error_list (g_error_list.COUNT + 1) := v_error_line;
   END;

   --
   -- process a wait line
   --'WAIT #(\d+): nam=''(.*)'' ela= (\d+) (.*) obj#=(.*) tim=(\d+)(.*)';
   --
   PROCEDURE process_wait (p_line VARCHAR2)
   IS
      v_sql_id             NUMBER;
      v_csr_id             NUMBER;
      v_sql_parse_id       NUMBER;
      v_sql_execution_id   NUMBER;
      v_sql_wait_id        NUMBER;                -- fetch within SQL stmt id
      v_wait_id            NUMBER;                         -- global fetch id
      v_wait_index         VARCHAR2 (256);
      v_wait_line          quest_soo_at_sql_waits%ROWTYPE;
      v_exec_waits         quest_soo_at_sql_waits%ROWTYPE;
      v_sql_stmt           sql_stmt_typ;
      v_exec_wait_list     exec_wait_typ;
      v_wait_nam           quest_soo_at_wait_names.nam%TYPE;
   BEGIN
      -- DEBUG(1,p_line);
       -- References to the current sql, parse and execution
      v_csr_id := get_stat (p_line, '#', ':');           -- Get cursor number
      v_wait_line.trace_file_id := g_trace_file_id;
      v_sql_id := get_sqlid_for_csr (v_csr_id);
      v_wait_line.sql_id := v_sql_id;
      v_wait_line.parse_id := g_sql_list (v_sql_id).parse_list.COUNT;
      v_wait_line.execution_id := g_sql_list (v_sql_id).exec_list.COUNT;
      v_wait_line.wait_count := 1;
      -- parse the line data
      v_wait_nam := get_string (p_line, 'nam=''', '''');
      v_wait_line.event_id := get_wait_id (v_wait_nam);
      v_wait_line.sum_elapsed := get_stat (p_line, 'ela= ', ' ');
      v_wait_line.obj# := get_stat (p_line, 'obj#=', 'tim=');
      v_wait_line.sumsquares_elapsed := POWER (v_wait_line.sum_elapsed, 2);

      -- Associate the wait with a SQL execution
      IF v_wait_line.execution_id > 0
      THEN
         add_wait_exec (v_wait_line);
      ELSE
         -- These  are wait that we see before the very first execution
         -- (often they are lock waits)
         add_pending_waits (v_wait_line);
      END IF;
   END;

   PROCEDURE process_parse_error (p_line IN OUT NOCOPY VARCHAR2)
   IS
   BEGIN
      /* parse error statements commence with a PARSE ERROR statement
      but have no END OF STMT marker.  THis makes them very hard to process .
      We don't have a UI to display parse errors so this is a placeholder for
      further work
      */
      DEBUG (0, p_line);
   END;

   --
   -- Process s single line of trace output.
   --
   PROCEDURE process_line (p_line IN OUT NOCOPY VARCHAR2, p_line_count NUMBER)
   IS
      v_linetype    VARCHAR2 (20);
      v_start_pga   NUMBER;
      v_track_pga   BOOLEAN       := FALSE;
   BEGIN
      v_linetype := get_line_type (p_line);
      DEBUG (0, v_linetype || ': ' || p_line);

      IF g_debug > 0 AND MOD (p_line_count, 100) = 0
      THEN
         v_start_pga := session_pga_memory ();
         v_track_pga := TRUE;
      END IF;

      CASE v_linetype
         WHEN 'FETCH'
         THEN
            process_fetch (p_line);
         WHEN 'WAIT'
         THEN
            IF g_process_waits
            THEN
               process_wait (p_line);
            END IF;
         WHEN 'PARSE'
         THEN
            process_parse (p_line);
         WHEN 'PARSING'
         THEN
            process_parsing (p_line);
         WHEN 'SQLTEXT'
         THEN
            process_sqltext (p_line);
         WHEN 'EXEC'
         THEN
            process_exec (p_line);
         WHEN 'END OF STMT'
         THEN
            process_end_of_stmt (p_line);
         WHEN 'SESSIONID'
         THEN
            process_sessionid (p_line);
         WHEN 'STAT'
         THEN
            process_stat (p_line);
         WHEN 'BIND'
         THEN
            IF g_process_binds
            THEN
               process_bind (p_line);
            END IF;
         WHEN 'BINDDATA'
         THEN
            IF g_process_binds
            THEN
               process_binddata (p_line);
            END IF;
         WHEN 'ERROR'
         THEN
            process_sql_error (p_line);
         WHEN 'PARSE_ERROR'
         THEN
            process_parse_error (p_line);
         ELSE
            NULL;
      END CASE;

      IF v_track_pga
      THEN
         track_pga (v_linetype, v_start_pga, session_pga_memory ());
      END IF;
   END;

   --
   -- Save the trace file row.
   --
   PROCEDURE save_trace_file_details
   IS
   BEGIN
      g_trace_file.load_status := 'LOADING';

      DELETE FROM quest_soo_at_trace_file
            WHERE UPPER (trace_file_name) =
                                         UPPER (g_trace_file.trace_file_name)
              AND inst_id = USERENV ('INSTANCE');

      INSERT INTO quest_soo_at_trace_file
           VALUES g_trace_file;

      COMMIT;
   END;

   --
   -- Save all the SQLs
   --
   PROCEDURE save_sql_statements
   IS
      v_sql_id     NUMBER;
      v_sql_stmt   quest_soo_at_sql_statement%ROWTYPE;
   BEGIN
      FOR i IN 0 .. g_sql_statement_list.LAST
      LOOP
         --DEBUG(0,'sql_list element='||i);
         v_sql_id := g_sql_statement_list (i).sql_id;
         g_sql_statement_list (i).sql_statement_first2000 :=
                                                      get_sql_text (v_sql_id);
      END LOOP;

      FORALL i IN 0 .. g_sql_statement_list.LAST
         INSERT INTO quest_soo_at_sql_statement
              VALUES g_sql_statement_list (i);
   EXCEPTION
      -- Note this will not fire unless "SAVE EXCEPTIONS" is specified above
      WHEN bulk_errors
      THEN
         FOR i IN 1 .. SQL%BULK_EXCEPTIONS.COUNT
         LOOP
            v_sql_id := SQL%BULK_EXCEPTIONS (i).ERROR_INDEX;
            v_sql_stmt := g_sql_statement_list (v_sql_id);
            DEBUG (2,
                      'sql id='
                   || v_sql_stmt.sql_id
                   || ' traceid='
                   || v_sql_stmt.trace_file_id
                  );
         END LOOP;
   END;

   --
   -- Save the SQL text
   --
   PROCEDURE save_sql_text
   IS
   BEGIN
      FORALL i IN 1 .. g_sql_stmt_pieces.COUNT
         INSERT INTO quest_soo_at_sql_stmt_pieces
              VALUES g_sql_stmt_pieces (i);
   END;

   --
   -- Save execute records
   --
   PROCEDURE save_execs
   IS
   BEGIN
      -- TODO: If save of individual FETCH rows is OFF, then
      -- work out and save "LAST_TIM" in the EXEC row
      FORALL i IN 1 .. g_exec_list.COUNT
         INSERT INTO quest_soo_at_sql_executions
              VALUES g_exec_list (i);
   END;

   --
   -- Save bind rows
   --
   PROCEDURE save_binds
   IS
   BEGIN
      FORALL i IN 1 .. g_bind_list.COUNT
         INSERT INTO quest_soo_at_sql_binds
              VALUES g_bind_list (i);
   END;

   --
   -- save fetch records
   --
   PROCEDURE save_fetches
   IS
   BEGIN
      FORALL i IN 1 .. g_fetch_list.COUNT
         INSERT INTO quest_soo_at_sql_fetch
              VALUES g_fetch_list (i);
   END;

   --
   -- Save wait records
   --
   PROCEDURE save_waits
   IS
      v_wait_line   quest_soo_at_sql_waits%ROWTYPE;
      v_wait_id     NUMBER;
   BEGIN
      FORALL i IN 1 .. g_wait_list.COUNT                    --SAVE EXCEPTIONS
         INSERT INTO quest_soo_at_sql_waits
              VALUES g_wait_list (i);
   /*EXCEPTION
      WHEN bulk_errors
      THEN
         FOR i IN 1 .. SQL%BULK_EXCEPTIONS.COUNT
         LOOP
            v_wait_id := SQL%BULK_EXCEPTIONS (i).ERROR_INDEX;
            v_wait_line := g_wait_list (v_wait_id);

            INSERT INTO wait_errors
                 VALUES v_wait_line;
         END LOOP;*/
   END;

   -- For debugging purposes only
   PROCEDURE save_waits_nobulk
   IS
      v_wait   quest_soo_at_sql_waits%ROWTYPE;
   BEGIN
      DEBUG (2, 'Saving waits (NOBULK)');

      FOR i IN 1 .. g_wait_list.COUNT
      LOOP
         BEGIN
            v_wait := g_wait_list (i);

            INSERT INTO quest_soo_at_sql_waits
                 VALUES v_wait;
         EXCEPTION
            WHEN OTHERS
            THEN
               DEBUG (2, v_wait.sql_id);
               DEBUG (2, v_wait.parse_id);
               DEBUG (2, v_wait.execution_id);
               DEBUG (2, v_wait.wait_id);
               RAISE;
         END;
      END LOOP;
   END;

   -- Save parse records
   PROCEDURE save_parses
   IS
   BEGIN
      FORALL i IN 1 .. g_parse_list.COUNT
         INSERT INTO quest_soo_at_parse_cursor
              VALUES g_parse_list (i);
   END;

   -- Save stat records
   PROCEDURE save_stat_records
   IS
   BEGIN
      FORALL i IN 1 .. g_stat_list.COUNT
         INSERT INTO quest_soo_at_execution_plan
              VALUES g_stat_list (i);
   END;

   -- Save SQL execute errors
   PROCEDURE save_exec_errors
   IS
   BEGIN
      /*  FOR i IN 1 .. g_error_list.COUNT
        LOOP
           DEBUG (1,
                     ' ERROR line for '
                  || g_error_list (i).sql_id
                  || '-'
                  || g_error_list (i).execution_id
                 );
        END LOOP; */
      FORALL i IN 1 .. g_error_list.COUNT
         INSERT INTO quest_soo_at_sql_exec_error
              VALUES g_error_list (i);
   END;

   --
   -- Save operations (unique plan lines)
   --
   PROCEDURE save_op_records
   IS
   BEGIN
      FORALL i IN 1 .. g_operations_list.COUNT
         INSERT INTO quest_soo_at_operations
              VALUES g_operations_list (i);
   END;

   -- Save all the tracefile details to the database
   --
   PROCEDURE save_trace_file
   IS
   BEGIN
      IF g_sql_statement_list.COUNT > 0
      THEN
         COMMIT;
         save_sql_statements ();
         save_sql_text ();
         save_parses ();
         save_execs ();
         save_fetches ();
         COMMIT;

         IF g_process_waits
         THEN
            save_waits ();
         END IF;

         IF g_process_binds
         THEN
            -- Bind summary data is saved to the execution table.
            -- This should/might be enough
            NULL;
         -- save_binds ();
         END IF;

         save_op_records ();
         save_stat_records ();
         save_exec_errors ();
         COMMIT;
      ELSE
         raise_application_error (-20005,
                                     'No SQL statements found in '
                                  || g_trace_file.trace_file_name
                                 );
      END IF;
   END;

   -- Get a timer value (centi-seconds)
   FUNCTION get_hsecs
      RETURN NUMBER
   IS
      v_cs_time   NUMBER;
   BEGIN
      execute immediate 'SELECT hsecs
                         FROM v$timer' INTO v_cs_time;

      RETURN (v_cs_time);
   END;

   --
   -- Check that the QUEST_SOO_UDUMP_DEST directory exists, create it if not
   --
   PROCEDURE check_directory
   IS
      v_user_id   NUMBER;
      v_user_trace_dir VARCHAR2 (32767);

   BEGIN
      /* The directory name includes the user id of the user who creates it
      Reason is that directory is always owned by SYS, even when we create it
      So we can't really share directories amongst users  */

      -- TODO: Consider dropping the directory later.
      SELECT user_id
        INTO v_user_id
        FROM user_users;

      g_directory_name := 'QUEST_SOO_UDUMP_DIR_' || SYS_CONTEXT('USERENV', 'INSTANCE') || '_' || v_user_id;

      IF (NOT is_directory (g_directory_name))
      THEN
      /*Tried to create a function called get_user_trace_directory but kept
      getting create any directory errorsso I'm sticking with this for this release*/
         IF (quest_soo_pkg.get_db_version >= 12.1) THEN
           execute immediate 'SELECT value
                 FROM v$diag_info
                 WHERE name like ''Diag Trace'''
                 INTO v_user_trace_dir;
           create_directory (g_directory_name,
                              v_user_trace_dir);
         ELSE
            create_directory (g_directory_name,
                              get_parameter ('USER_DUMP_DEST'));
         END IF;
      END IF;
   END;

   --
   -- Clear the contents of existing tables.
   --
   PROCEDURE clear_tables
   IS
      l_trace_file   quest_soo_at_trace_file%ROWTYPE;
   BEGIN
      g_parse_list.DELETE;
      g_exec_list.DELETE;
      g_fetch_list.DELETE;
      g_sql_statement_list.DELETE;
      g_wait_list.DELETE;
      g_sql_stmt_pieces.DELETE;
      g_stat_list.DELETE;
      g_sql_binds.DELETE;
      g_bind_list.DELETE;
      g_sql_list.DELETE;
      g_sql_lookup.DELETE;
      g_error_list.DELETE;
      g_operations_list.DELETE;
      g_operations_idx.DELETE;
      cursor_to_stmt_map.DELETE;
      g_wait_names.DELETE;
      g_wait_nam_idx.DELETE;
      g_pending_waits.DELETE;
      g_pending_waits_sql_idx.DELETE;
      g_pga_usage.DELETE;
      g_trace_file := l_trace_file;
      g_sql_id := -1;
      g_sql_zero := NULL;
      g_trace_file_id := NULL;
      g_session_id := NULL;
      g_serial := NULL;
      g_currently_binding_sql := NULL;
      g_previous_line_type := NULL;
      g_pga_size := 0;
      g_session_pga_memory_stat# := NULL;
   END;

   --
    -- Release memory, etc
    --
   PROCEDURE reset_package
   IS
   BEGIN
      clear_tables;
      --DBMS_SESSION.reset_package;
      DBMS_SESSION.free_unused_user_memory;
   --DBMS_OUTPUT.ENABLE;
   END;

   PROCEDURE table_sizes
   IS
   BEGIN
      DEBUG (2, 'g_parse_list ' || g_parse_list.COUNT);
      DEBUG (2, 'g_exec_list ' || g_exec_list.COUNT);
      DEBUG (2, 'g_fetch_list ' || g_fetch_list.COUNT);
      DEBUG (2, 'g_sql_statement_list ' || g_sql_statement_list.COUNT);
      DEBUG (2, 'g_wait_list ' || g_wait_list.COUNT);
      DEBUG (2, 'g_sql_stmt_pieces ' || g_sql_stmt_pieces.COUNT);
      DEBUG (2, 'g_stat_list ' || g_stat_list.COUNT);
      DEBUG (2, 'g_sql_binds ' || g_sql_binds.COUNT);
      DEBUG (2, 'g_bind_list ' || g_bind_list.COUNT);
      DEBUG (2, 'g_sql_list ' || g_sql_list.COUNT);
      DEBUG (2, 'g_sql_lookup ' || g_sql_lookup.COUNT);
      DEBUG (2, 'cursor_to_stmt_map ' || cursor_to_stmt_map.COUNT);
   END;

   --
   -- Initialize global variables etc
   --
   PROCEDURE initialize_globals (
      p_file_name        VARCHAR2,
      p_comment_text     VARCHAR2,
      p_load_all_lines   BOOLEAN,
      p_process_waits    NUMBER,
      p_process_binds    NUMBER,
      p_load_recursive   NUMBER,
      p_debug_level      NUMBER
   )
   IS
   BEGIN
      check_directory ();
      clear_tables ();
      get_oracle_version ();
      g_trace_file_id := get_seq_no ();        -- unique ID for the tracefile
      DEBUG (1, 'Trace file id=' || g_trace_file_id);
      g_trace_file.trace_file_id := g_trace_file_id;
      g_trace_file.inst_id := USERENV ('INSTANCE');
      g_trace_file.last_analyzed_date := SYSDATE;
      g_trace_file.trace_file_name := p_file_name;
      g_trace_file.comment_text := p_comment_text;
      g_load_all_lines := p_load_all_lines;
      g_process_waits := CASE p_process_waits
                           WHEN 1
                              THEN TRUE
                           ELSE FALSE
                        END;
      g_process_binds := CASE p_process_binds
                           WHEN 1
                              THEN TRUE
                           ELSE FALSE
                        END;
      g_load_recursive := CASE p_load_recursive
                            WHEN 1
                               THEN TRUE
                            ELSE FALSE
                         END;
      g_debug := p_debug_level;
      initialize_sqlzero ();   -- special SQL for otherwise unassociated data
      initialize_wait_lookup;
   END;

   PROCEDURE set_pga_limit (p_pga_limit NUMBER)
   IS
      v_pga_limit    NUMBER;
      v_pga_target   NUMBER;
   BEGIN
      IF p_pga_limit IS NULL
      THEN
         v_pga_limit := 100;
      ELSE
         v_pga_limit := p_pga_limit;
      END IF;

      IF v_pga_limit < 101
      THEN
         -- if <100 then treat as a %aga of pga_aggregate_target
         execute immediate 'SELECT VALUE
                            FROM v$parameter
                            WHERE NAME = ''pga_aggregate_target''' INTO v_pga_target;

         g_pga_limit := v_pga_target * v_pga_limit / 100;
      ELSE
         g_pga_limit := v_pga_limit;
      END IF;

      DEBUG (0, 'pga limit=' || g_pga_limit);
   END;

   --
   -- Check the PGA size and abort if too much memory used
   --
   PROCEDURE check_pga_size (p_file_name VARCHAR2, p_linecount NUMBER)
   IS
      v_error   VARCHAR2 (1000);
   BEGIN
      IF session_pga_memory > g_pga_limit
      THEN
         v_error :=
               'PGA limit of '
            || g_pga_limit
            || ' bytes exceeded; call package with higher PGA limit or increase PGA_AGGREGATE_TARGET.'
            || ' Trace file being analysed: ' || g_trace_file.trace_file_name;
         print_pga;
         log_error (p_file_name,
                    v_error,
                    DBMS_UTILITY.format_call_stack,
                    p_linecount
                   );
         clear_tables ();
         reset_package ();
         raise_application_error (-20002, v_error);
      END IF;
   END;

   --
   -- Main routines that reads lines and sends them off for processing
   --
   -- TODO: enable the various flags
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
   )
   IS
      v_file_hdl     UTL_FILE.file_type;
      v_line         VARCHAR2 (32767);
      v_linecount    NUMBER             := 0;
      v_eof          BOOLEAN            := FALSE;
      v_start_time   NUMBER;
      v_end_time     NUMBER;
      v_lines_ps     NUMBER;
      v_sql_count    NUMBER;
   BEGIN
      /* Disable parallel query CR 9869 */
      BEGIN
         EXECUTE IMMEDIATE 'alter session disable parallel query';
      EXCEPTION
         WHEN OTHERS THEN
            null;
      END;

      v_start_time := get_hsecs ();
      initialize_globals (p_file_name           => file_name,
                          p_comment_text        => comment_text,
                          p_load_all_lines      => load_all_lines,
                          p_process_waits       => process_waits,
                          p_process_binds       => process_binds,
                          p_load_recursive      => load_recursive,
                          p_debug_level         => debug_level
                         );
      set_pga_limit (pga_limit);
      DEBUG (1, 'Start PGA=' || session_pga_memory ());
      v_file_hdl := open_tracefile (file_name);
      save_trace_file_details ();

      LOOP
         read_line (v_file_hdl, v_line, v_eof);
         EXIT WHEN v_eof OR v_linecount = line_limit;

         v_linecount := v_linecount + 1;

         IF (MOD (v_linecount, 10000) = 0)
         THEN
            check_pga_size (file_name, v_linecount);
         END IF;

         process_line (v_line, v_linecount);
      END LOOP;

      save_trace_file ();                             -- write out to database
      v_end_time := get_hsecs ();

      IF (v_end_time > v_start_time)
      THEN
         v_lines_ps := v_linecount / ((v_end_time - v_start_time) / 100);
      ELSE
         v_lines_ps := 0;
      END IF;

      v_sql_count := g_sql_list.COUNT - 1;               -- Don't count SQL# 0

      UPDATE quest_soo_at_trace_file
         SET lines_loaded = v_linecount,
             sql_statement_count = v_sql_count,
             load_elapsed_ms = (v_end_time - v_start_time) * 10,
             load_status = 'COMPLETE',
             base_datetime_value = g_trace_file.base_datetime_value,
             base_tim_value = g_trace_file.base_tim_value,
             oracle_version = g_trace_file.oracle_version
       WHERE trace_file_id = g_trace_file_id;

      COMMIT;

      IF g_debug > 0
      THEN
         DEBUG (1, file_name);
         table_sizes ();
         DEBUG (1, 'End PGA=' || session_pga_memory ());
         print_pga ();
      END IF;
   EXCEPTION
      WHEN OTHERS
      THEN
         log_error (file_name,
                    DBMS_UTILITY.format_error_stack,
                    DBMS_UTILITY.format_call_stack,
                    v_linecount
                   );
         ROLLBACK;
         RAISE;
   END;

   PROCEDURE add_background_trace_row (
      p_file_name        VARCHAR2,
      p_process_waits    INTEGER := 1,
      p_process_binds    INTEGER := 1,
      p_load_recursive   INTEGER := 1,
      p_line_limit       INTEGER := NULL,
      p_comment_text     VARCHAR2 := NULL,
      p_debug_level      INTEGER := 0,
      p_pga_limit        NUMBER := NULL
   )
   IS
      v_file_id   NUMBER;
   BEGIN
      v_file_id := get_seq_no ();

      INSERT INTO quest_soo_at_trace_file
                  (trace_file_id, inst_id, trace_file_name,
                   comment_text, load_status, process_waits,
                   process_binds, load_recursive, pga_limit
                  )
           VALUES (v_file_id, USERENV ('INSTANCE'), p_file_name,
                   p_comment_text, 'PENDING', p_process_waits,
                   p_process_binds, p_load_recursive, p_pga_limit
                  );
   END;

   PROCEDURE update_background_trace_row (
      p_file_id          NUMBER,
      p_process_waits    INTEGER := 1,
      p_process_binds    INTEGER := 1,
      p_load_recursive   INTEGER := 1,
      p_line_limit       INTEGER := NULL,
      p_comment_text     VARCHAR2 := NULL,
      p_debug_level      INTEGER := 0,
      p_pga_limit        NUMBER := NULL
   )
   IS
   BEGIN
      UPDATE quest_soo_at_trace_file
         SET comment_text = p_comment_text,
             load_status = 'PENDING',
             process_waits = p_process_waits,
             process_binds = p_process_binds,
             load_recursive = p_load_recursive,
             pga_limit = p_pga_limit
       WHERE trace_file_id = p_file_id;
   END;

   --
   -- Create a DBMS job entry to submit the job for processing
   -- Returns job_id;
   --
   FUNCTION submit_load_trace_job
      RETURN NUMBER
   IS
      v_job_str        VARCHAR2 (1000);
      v_job_no         NUMBER;
      v_10seconds      NUMBER          := 1 / (24 * 60 * 10);
      v_comment_text   VARCHAR2 (2000);

      CURSOR c_jobs
      IS
         SELECT job
           FROM user_jobs
          WHERE what LIKE '%QUEST_SOO_SQLTRACE.BACKGROUND_LOADJOB%'
            AND broken = 'N'
            AND INSTANCE = USERENV ('INSTANCE');
   BEGIN
      OPEN c_jobs;

      FETCH c_jobs
       INTO v_job_no;

      IF c_jobs%NOTFOUND
      THEN
         v_job_str := 'BEGIN QUEST_SOO_SQLTRACE.BACKGROUND_LOADJOB; END;';
         DEBUG (0, 'Value of v_job_str=' || v_job_str);
         DBMS_JOB.submit (job            => v_job_no,
                          what           => v_job_str,
                          next_date      => SYSDATE + v_10seconds,
                          INTERVAL       => NULL,
                          INSTANCE       => USERENV ('instance')
                         );
         COMMIT;
      END IF;

      CLOSE c_jobs;

      DEBUG (2, SUBSTR ('Value of v_job_no=' || v_job_no, 1, 255));
      RETURN (v_job_no);
   END;

   --
   -- Mark a job for background submission
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
      RETURN NUMBER
   IS
      CURSOR get_trace_csr
      IS
         SELECT     *
               FROM quest_soo_at_trace_file
              WHERE trace_file_name = file_name
                AND inst_id = USERENV ('INSTANCE')
         FOR UPDATE;

      trace_row   get_trace_csr%ROWTYPE;
   BEGIN
      OPEN get_trace_csr;

      FETCH get_trace_csr
       INTO trace_row;

      IF get_trace_csr%NOTFOUND
      THEN
         add_background_trace_row (p_file_name           => file_name,
                                   p_process_waits       => process_waits,
                                   p_process_binds       => process_binds,
                                   p_load_recursive      => load_recursive,
                                   p_line_limit          => line_limit,
                                   p_comment_text        => comment_text,
                                   p_debug_level         => debug_level,
                                   p_pga_limit           => pga_limit
                                  );
      ELSE
         update_background_trace_row (p_file_id             => trace_row.trace_file_id,
                                      p_process_waits       => process_waits,
                                      p_process_binds       => process_binds,
                                      p_load_recursive      => load_recursive,
                                      p_line_limit          => line_limit,
                                      p_comment_text        => comment_text,
                                      p_debug_level         => debug_level,
                                      p_pga_limit           => pga_limit
                                     );
      END IF;

      COMMIT;
      RETURN (submit_load_trace_job ());
   END;

   --
   -- Process every row scheduled for background processing
   --
   PROCEDURE background_loadjob
   IS
      CURSOR get_jobs_csr
      IS
         SELECT        *
                  FROM quest_soo_at_trace_file
                 WHERE load_status = 'PENDING'
                   AND inst_id = USERENV ('INSTANCE')
         FOR UPDATE OF load_status;

      TYPE job_list_typ IS TABLE OF get_jobs_csr%ROWTYPE
         INDEX BY BINARY_INTEGER;

      jobs_list   job_list_typ;
   BEGIN
      FOR jobs_row IN get_jobs_csr
      LOOP
         jobs_list (jobs_list.COUNT + 1) := jobs_row;

         UPDATE quest_soo_at_trace_file
            SET load_status = 'SCHEDULED'
          WHERE CURRENT OF get_jobs_csr;
      END LOOP;

      COMMIT;

      IF jobs_list.COUNT > 0
      THEN
         FOR i IN 1 .. jobs_list.COUNT
         LOOP
            load_trace (file_name           => jobs_list (i).trace_file_name,
                        process_waits       => jobs_list (i).process_waits,
                        process_binds       => jobs_list (i).process_binds,
                        load_recursive      => jobs_list (i).load_recursive,
                        comment_text        => jobs_list (i).comment_text,
                        debug_level         => 1,
                        pga_limit           => jobs_list (i).pga_limit
                       );
         END LOOP;
      END IF;
   END;
END;
/
