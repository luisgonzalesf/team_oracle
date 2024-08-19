CREATE OR REPLACE PACKAGE BODY LGONZALES.QUEST_SOO_PKG
IS
   --
   -- This package contains routines used by Spotlight On Oracle
   --

   --
   -- These tables contain event names and categories
   --
   TYPE varchar_tab_typ IS TABLE OF VARCHAR2 (120)
      INDEX BY BINARY_INTEGER;

   TYPE number_tab_typ IS TABLE OF NUMBER
      INDEX BY BINARY_INTEGER;

   TYPE lock_type_typ IS TABLE OF VARCHAR2 (64)
      INDEX BY VARCHAR2 (64);

   event_indx_tab        varchar_tab_typ;
   event_name_tab        varchar_tab_typ;
   event_category_tab    varchar_tab_typ;
   lock_type_tab         lock_type_typ;
   g_event_count         NUMBER := 0;
   l_event_initialized   BOOLEAN := FALSE;

   TYPE rc is REF CURSOR;

   /* -----------------------------------------------------------------
   ** Full version of Oracle RDBMS.
   ** We just need to run the function dbversion once and
   ** save the result in this variable for other procedures/functions
   */
   -----------------------------------------------------------------
   full_version          VARCHAR2 (20);

   /* ===========================================================
   || Some forward declarations
   =========================================================*/

   PROCEDURE initialize_object_cache;

   FUNCTION dbversion
      RETURN VARCHAR2;

   PROCEDURE populate_lock_type;


     --private declarations
   FUNCTION build_select_list (lowner IN VARCHAR2, lname IN VARCHAR2)
      RETURN VARCHAR2;

   FUNCTION run_stmt (lowner IN VARCHAR2, lname IN VARCHAR2, lrowid IN VARCHAR2)
      RETURN VARCHAR2;


   /* -----------------------------------------------------------
   || Functions and procedure bodies start here
   */
   -----------------------------------------------------------

   -- Function to format SQL text
   FUNCTION format_sql (p_sql_text IN VARCHAR2, p_max_len IN NUMBER := 256)
      RETURN VARCHAR2
   IS
      i               NUMBER := 0;
      l_text_len      NUMBER := 0;
      l_this_char     CHAR;
      l_last_char     CHAR;
      l_from_pos      NUMBER := 0;
      l_dup_sp_pos    NUMBER := 0;
      l_return_text   VARCHAR2 (2000);
   BEGIN
      -- Strip out blanks
      l_return_text := TRANSLATE (p_sql_text, CHR (10) || CHR (13), '  ');
      l_dup_sp_pos := INSTR (l_return_text, '  ');
      i := 1;

      WHILE (l_dup_sp_pos <> 0)
      LOOP
         l_return_text :=
               SUBSTR (l_return_text, 1, l_dup_sp_pos)
            || SUBSTR (l_return_text, l_dup_sp_pos + 2);
         l_dup_sp_pos := INSTR (l_return_text, '  ');
         i := i + 1;
         EXIT WHEN l_dup_sp_pos > 40;
      END LOOP;

      -- For selects, make sure the 'FROM' is visible
      IF UPPER (SUBSTR (p_sql_text, 1, 6)) = 'SELECT'
      THEN
         l_from_pos := INSTR (UPPER (l_return_text), 'FROM');

         IF l_from_pos > 40
         THEN
            l_return_text :=
                  SUBSTR (l_return_text, 1, 40)
               || ' ... '
               || SUBSTR (l_return_text, l_from_pos);
         END IF;
      END IF;

      RETURN SUBSTR (l_return_text, 1, p_max_len);
   END;


   FUNCTION latch_category (p_latch_name VARCHAR2)
      RETURN VARCHAR2
   IS
   BEGIN
      IF    (p_latch_name LIKE 'library cache%')
         OR (p_latch_name = 'shared pool')
      THEN
         RETURN ('Shared Pool');
      ELSIF (p_latch_name LIKE 'redo%')
      THEN
         RETURN ('Redo buffer');
      ELSIF (p_latch_name LIKE 'cache buffer%')
      THEN
         RETURN ('Buffer cache');
      ELSIF (p_latch_name LIKE '%enqueue%')
      THEN
         RETURN ('Enqueue');
      ELSIF (p_latch_name LIKE '%virtual circuit%')
      THEN
         RETURN ('MTS');
      ELSIF (p_latch_name LIKE '%transaction%')
      THEN
         RETURN ('Transaction');
      ELSE
         RETURN ('Other');
      END IF;
   END;


   /* ===================================
  || Print a debug message
  =====================================*/
   PROCEDURE DEBUG (in_string VARCHAR2)
   IS
   BEGIN
      IF g_debug = 1
      THEN
         DBMS_OUTPUT.put_line (in_string);
      END IF;
   END;

   /* ===============================================================
   || Function to set up the object cache which allows fast retrieval
   || of segment name from file/block segment header
      ==============================================================*/
   PROCEDURE initialize_object_cache
   IS
   BEGIN
        EXECUTE IMMEDIATE 'SELECT file_id,
                             extent_id,
                             block_id,
                             blocks,
                             owner || ''.'' || segment_name segment_name
                           FROM SYS.dba_extents
                           ORDER BY file_id, block_id'
                           BULK COLLECT INTO object_cache_fileno,
                                             object_cache_extno,
                                             object_cache_blockno,
                                             object_cache_length,
                                             object_cache_segname;

      object_cache_count := object_cache_segname.COUNT;
      g_object_cache_initialized := 1;
   END;                                              -- intialize object_cache

   /* -------------------------------------------------------------
   || A function to return a segment name given a file/block header address
   || This is faster than using DBA_SEGMENTS
   || This is the I18N version of get_seg_name
   */
   -------------------------------------------------------------
   FUNCTION get_seg_name_41 (p_fileno NUMBER, p_blockno NUMBER)
      RETURN VARCHAR2
   AS
      i      NUMBER := 0;
      hi     NUMBER := 0;
      lo     NUMBER := 0;
      NEXT   NUMBER := 0;
      prev   NUMBER := 0;
   BEGIN
      /* -------------------------------------------------------------
      || If the object cache is not initialized, then
      || initialize it
      */
      -------------------------------------------------------------
      IF g_object_cache_initialized = 0
      THEN
         RETURN ('Extent at file ' || p_fileno || ', block ' || p_blockno);
      END IF;

      -- Binary chop through the table
      hi := object_cache_count;
      lo := 1;
      i := TRUNC ( (hi - lo) / 2);

     <<main_loop>>
      LOOP
         -- Found a match
         DEBUG (
               'checking entry '
            || i
            || ': '
            || object_cache_fileno (i)
            || ', '
            || object_cache_blockno (i)
            || '-'
            || TO_CHAR (
                  object_cache_blockno (i) + object_cache_length (i) - 1));

         IF     object_cache_fileno (i) = p_fileno
            AND                                               -- Found a match
               p_blockno BETWEEN object_cache_blockno (i)
                             AND   object_cache_blockno (i)
                                 + object_cache_length (i)
                                 - 1
         THEN
            DEBUG ('found match at ' || i || ' : ' || object_cache_segname (i));
            RETURN (object_cache_segname (i));
         ELSIF (   object_cache_fileno (i) < p_fileno
                OR                                     -- matching row is high
                   (    object_cache_fileno (i) = p_fileno
                    AND   object_cache_blockno (i)
                        + object_cache_length (i)
                        - 1 < p_blockno))
         THEN
--            -- We are low
--            DEBUG ('too low');
            lo := i;
            NEXT := i + CEIL ( (hi - lo) / 2);
         ELSIF (   object_cache_fileno (i) > p_fileno
                OR (    object_cache_fileno (i) = p_fileno
                    AND object_cache_blockno (i) > p_blockno))
         THEN
--            -- We are high
--            DEBUG ('too high');
            hi := i;
            NEXT := i - CEIL ( (hi - lo) / 2);
         END IF;

         IF NEXT = i OR NEXT = prev
         THEN
--            DEBUG ('chopped down to nothing (next entry' || NEXT || ')');
            -- We've chopped down to nothing (perhaps the cache should be refreshed)
            RETURN ('UNK');             -- 'Unknown, temporary or new segment'
         END IF;

         prev := i;
         i := NEXT;
      END LOOP;
   END;                                                     -- get_seg_name_41

   --
   -- This function returns the wait class of an event in 10g
   --
   FUNCTION oracleeventclass (p_event_name VARCHAR2)
      RETURN VARCHAR2
   IS
      cs          VARCHAR2 (200)
         := 'SELECT wait_class FROM v$event_name WHERE name = :event_name';
      ch          INTEGER;
      waitclass   VARCHAR2 (200) := 'Unknown';
      rv          NUMBER;
      VERSION     NUMBER;
   BEGIN
      -- Mostly we double checked the version, but better this way......
      VERSION :=
         TO_NUMBER (SUBSTR (full_version, 1, INSTR (full_version, '.') - 1));

      IF VERSION = 10
      THEN
         ch := DBMS_SQL.open_cursor;
         DBMS_SQL.parse (ch, cs, DBMS_SQL.native);
         DBMS_SQL.bind_variable (ch, 'event_name', p_event_name);
         DBMS_SQL.define_column (ch,
                                 1,
                                 waitclass,
                                 200);
         rv := DBMS_SQL.EXECUTE (ch);
         rv := DBMS_SQL.fetch_rows (ch);

         IF rv > 0
         THEN
            --only getting the first one...
            DBMS_SQL.COLUMN_VALUE (ch, 1, waitclass);
            DBMS_SQL.close_cursor (ch);
         END IF;
      END IF;

      RETURN (waitclass);
   END;

   --
   -- This procedure populates the PL/SQL tables containing events and categories
   --
   PROCEDURE populate_event_table
   IS
      /* -----------------------------------------------------------------
      -- This cursor pulls out events and categories.  It pulls them
      -- out in descending frequency, so we can scan the table a bit
      -- more efficiently.  It gets INDX from X$KSLEI so that we can
      -- use that instead of the event name to avoid the join on X$KSLED
      -- The above comment is for dbs prior to v11.After v11, we are eliminating
      -- the need for x$ references and are using the the v$ equivalents.
      ------------------------------------------------------------------*/
      stmt                VARCHAR2 (3200);
      stmt7               VARCHAR2 (3200)
         := 'SELECT /*+ORDERED USE_HASH(E) */

                    s.event event,

                    e.topcategory || '' - '' || e.subcategory || '' ^ '' || e.category category,

                    NVL(total_waits, -1)       total_waits,

                    NVL(S.INDX, -1)            indx

               FROM (SELECT /*+  ORDERED */

                            0 inst_id,

                            D.KSLEDNAM event,

                            S.KSLESWTS total_waits,

                            S.KSLESTMO total_timeouts,

                            S.KSLESTIM time_waited,

                            S.KSLESTIM / DECODE(S.KSLESWTS,0,1,S.KSLESWTS) average_wait,

                            S.INDX indx

                       FROM X$KSLED D, X$KSLEI S

                      WHERE S.INDX = D.INDX

                    ) s,

                    quest_soo_event_categories e

              WHERE s.event=e.name(+)

              ORDER BY total_waits desc';
      stmt8               VARCHAR2 (3200)
         := 'SELECT /*+ ORDERED USE_HASH(E) */

                    s.event event,

                    e.topcategory || '' - '' || e.subcategory || '' ^ '' || e.category category,

                    NVL(total_waits, -1)       total_waits,

                    NVL(S.INDX, -1)            indx

               FROM (SELECT /*+  ORDERED */

                            D.INST_ID,

                            D.KSLEDNAM event,

                            S.KSLESWTS total_waits,

                            S.KSLESTMO total_timeouts,

                            S.KSLESTIM time_waited,

                            S.KSLESTIM / DECODE(S.KSLESWTS,0,1,S.KSLESWTS) average_wait,

                            S.INDX indx

                       FROM X$KSLED D, X$KSLEI S

                      WHERE s.indx = d.indx

                        AND d.inst_id = USERENV(''INSTANCE'')

                        AND s.inst_id = USERENV(''INSTANCE'')

                    ) s,

                    quest_soo_event_categories e

              WHERE s.event=e.name(+)

              ORDER BY total_waits desc';
      stmt9               VARCHAR2 (3200)
         := 'SELECT /*+ ORDERED USE_HASH(E) */

                    s.event event,

                    e.topcategory || '' - '' || e.subcategory || '' ^ '' || e.category category,

                    NVL(total_waits, -1)       total_waits,

                    NVL(S.INDX,-1)            indx

               FROM (SELECT /*+  ORDERED */

                            D.INST_ID,

                            D.KSLEDNAM event,

                            S.KSLESWTS total_waits,

                            S.KSLESTMO total_timeouts,

                            S.KSLESTIM/10000 time_waited,  -- microsecond in 9i,convert to centisecond

                            S.KSLESTIM/10000/DECODE(S.KSLESWTS,0,1,S.KSLESWTS) average_wait,

                            S.INDX indx

                       FROM X$KSLED D, X$KSLEI S

                      WHERE S.INDX = D.INDX

                        AND d.INST_ID = USERENV(''INSTANCE'')

                        AND s.inst_id = USERENV(''INSTANCE'')

                    ) s,

                    quest_soo_event_categories e

              WHERE s.event=e.name(+)

              ORDER BY total_waits desc';

      stmt11              VARCHAR2 (3200)
         := ' SELECT sysevent_waits.name,
                     e.topcategory || '' - '' || e.subcategory || '' ^ '' || e.category
                     category,
                     sysevent_waits.event_total_waits total_waits,
                     NVL (sysevent_waits.indx, -1) indx
              FROM (SELECT n.name,
                           NVL (s.total_waits, 0) event_total_waits,
                           n.event# indx
                    FROM v$system_event s, v$event_name n
                    WHERE n.event_id = s.event_id(+)) sysevent_waits,
                    quest_soo_event_categories e
              WHERE e.NAME(+) = sysevent_waits.name
              ORDER BY total_waits DESC';

      VERSION             NUMBER;
      csr                 INTEGER;
      event_name          VARCHAR2 (3200);
      event_cat           VARCHAR2 (3200);
      event_waits         NUMBER;
      event_indx          INTEGER;
      ignore              INTEGER;

      TYPE varchar_typ IS TABLE OF VARCHAR2 (3200)
         INDEX BY BINARY_INTEGER;

      TYPE num_typ IS TABLE OF NUMBER
         INDEX BY BINARY_INTEGER;

      l_event_name_tab    DBMS_SQL.varchar2_table;
      l_event_cat_tab     DBMS_SQL.varchar2_table;
      l_event_waits_tab   DBMS_SQL.number_table;
      l_event_indx_tab    DBMS_SQL.number_table;
      l_no_events         NUMBER;
      l_rows              NUMBER;
   BEGIN
      g_event_count := 0;
      VERSION :=
         TO_NUMBER (SUBSTR (full_version, 1, INSTR (full_version, '.') - 1));
      DEBUG ('start');
      stmt := stmt9;

      -- default to Oracle 9 first, which covers 10G. Future releases such as 12 are taken care of by 11.
      IF (VERSION = 7)
      THEN
         stmt := stmt7;
      ELSIF (VERSION = 8)
      THEN
         stmt := stmt8;
      ELSIF (VERSION >= 11)
      THEN
         stmt := stmt11;
      END IF;

      IF VERSION >= 10
      THEN
         EXECUTE IMMEDIATE
               'INSERT INTO quest_soo_event_categories (NAME, topcategory, subcategory, CATEGORY) '
            || 'SELECT NAME, decode(wait_class, ''Idle'', ''Idle'', ''Other''), '
            || 'DECODE(wait_class, ''Idle'', ''Idle'', ''Other''), decode(wait_class, ''Idle'', ''Idle'', ''Other'') '
            || ' FROM v$event_name e WHERE NOT EXISTS (SELECT 1 FROM quest_soo_event_categories c WHERE c.NAME = e.NAME)';
      END IF;

      -- Fetch the number of rows neccessary for array fetch:
      IF (VERSION >= 11)
      THEN
         EXECUTE IMMEDIATE 'SELECT COUNT (*) FROM v$event_name' INTO l_no_events ;
      ELSE
         EXECUTE IMMEDIATE 'SELECT COUNT (*) FROM x$ksled' INTO l_no_events;
      END IF;

         --
         -- Execute the appropriate SQL and put the rows into PLSQL
         -- Collections (DBMS_SQL is neccessary since the SQL is dynamic and
         -- we might be running in an earlier version that doesn't have bulk
         -- collect in NDS
         --
         csr := DBMS_SQL.open_cursor;
         DBMS_SQL.parse (csr, stmt, DBMS_SQL.native);
         DBMS_SQL.define_array (csr,
                                1,
                                l_event_name_tab,
                                l_no_events + 1,
                                0);
         DBMS_SQL.define_array (csr,
                                2,
                                l_event_cat_tab,
                                l_no_events + 1,
                                0);
         DBMS_SQL.define_array (csr,
                                3,
                                l_event_waits_tab,
                                l_no_events + 1,
                                0);
         DBMS_SQL.define_array (csr,
                                4,
                                l_event_indx_tab,
                                l_no_events + 1,
                                0);
         ignore := DBMS_SQL.EXECUTE (csr);
         l_rows := DBMS_SQL.fetch_rows (csr);
         DBMS_SQL.COLUMN_VALUE (csr, 1, l_event_name_tab);
         DBMS_SQL.COLUMN_VALUE (csr, 2, l_event_cat_tab);
         DBMS_SQL.COLUMN_VALUE (csr, 3, l_event_waits_tab);
         DBMS_SQL.COLUMN_VALUE (csr, 4, l_event_indx_tab);
         DBMS_SQL.close_cursor (csr);

         --
         -- Loop through the resulting rows, translating them to the
         -- "traditional" event category tab format
         --
         -- TODO: The delimited format of this structure seems ridiculous and
         --       would almost certainly be better as a record structured array
         --
         FOR i IN 0 .. l_rows - 1
         LOOP
            event_name := l_event_name_tab (i);
            event_cat := l_event_cat_tab (i);
            event_waits := l_event_waits_tab (i);
            event_indx := l_event_indx_tab (i);
            g_event_count := g_event_count + 1;

            --dbms_output.put_line(substr('Value of event_name='||event_name,1,255));

            -- An new event is not categorised, set to Unknown.  If it is 10g, see if it is Idle.
            IF event_cat = ' -  ^ '
            THEN
               IF VERSION >= 10 AND oracleeventclass (event_name) = 'Idle'
               THEN
                  event_category_tab (g_event_count) := 'Idle - Idle ^ Idle';
               ELSE
                  event_category_tab (g_event_count) :=
                     'Unknown - Unknown ^ Unknown';
               END IF;
            ELSE
               event_category_tab (g_event_count) := event_cat;
            END IF;

            event_name_tab (g_event_count) := event_name;

            IF event_indx > -1
            THEN
               --dbms_output.put_line(event_indx);
               event_indx_tab (event_indx) :=
                  event_category_tab (g_event_count);
            END IF;
         END LOOP;

         -- Populate the lock type table
         populate_lock_type;
      /*  EXCEPTION
           WHEN OTHERS
           THEN
              IF DBMS_SQL.is_open (csr)
              THEN
                 DBMS_SQL.close_cursor (csr);
              END IF;

              RAISE; */
   END;                                                -- populate_event_table

   PROCEDURE initialize
   IS
   --
   -- Initialization section. This initializes PL/SQL tables.
   --
   BEGIN
      full_version := dbversion;          --Don't get version more than once.
      populate_event_table;
      initialize_object_cache;
   END;

   PROCEDURE initialize_fast
   IS
   --
   -- Initialization section A. This includes those initializations which
   -- Must be performed before any functions can be used.
   --
   BEGIN
      full_version := dbversion;          --Don't get version more than once.
      populate_event_table;
   END;

   PROCEDURE initialize_objects
   IS
   --
   -- Initialization section B. This includes all the slower loads which can
   -- Be deferred until after the first refresh.
   --
   BEGIN
      initialize_object_cache;
   END;

  --------------------------------------------------
   -- Start tracing the session
   PROCEDURE set_trace (p_sid NUMBER, p_serial NUMBER, p_level NUMBER)
   IS
    strWaitsBinds VARCHAR2(100);
   BEGIN
      CASE
        WHEN p_level = 1  THEN strWaitsBinds := 'WAITS=>FALSE, BINDS=>TRUE';
        WHEN p_level = 4  THEN strWaitsBinds := 'WAITS=>FALSE, BINDS=>TRUE';
        WHEN p_level = 8  THEN strWaitsBinds := 'WAITS=>TRUE, BINDS=>FALSE';
        WHEN p_level = 12 THEN strWaitsBinds := 'WAITS=>TRUE, BINDS=>TRUE';
      ELSE
        strWaitsBinds := 'WAITS=>TRUE, BINDS=>TRUE';
      END CASE;

      EXECUTE IMMEDIATE 'BEGIN SYS.DBMS_MONITOR.session_trace_enable(:p_sid,:p_serial,' || strWaitsBinds || '); END;' USING IN p_sid, p_serial;
   END;

   -- Overload for backward compatibiity
   PROCEDURE set_trace (p_sid NUMBER, p_serial NUMBER, p_mode BOOLEAN)
   IS
    strEnableTrace VARCHAR2(100);
   BEGIN
      IF p_mode THEN
        strEnableTrace := 'BEGIN SYS.DBMS_MONITOR.session_trace_enable(:p_sid, :p_serial); END;';
      ELSE
        strEnableTrace := 'BEGIN SYS.DBMS_MONITOR.session_trace_disable(:p_sid, :p_serial); END;';
      END IF;

      EXECUTE IMMEDIATE strEnableTrace USING IN p_sid, p_serial;
   END;

   --
   -- Translate values in the form 999{K|M} to byte values so
   -- instance monitor can deal with them
   --
   FUNCTION translate_parameter (p_value VARCHAR2)
      RETURN VARCHAR2
   IS
      last_char      CHAR;
      numeric_part   NUMBER;
      -- Below two variables are used for buffer_pool_keep/recycle
      para_value     VARCHAR2 (200);
      end_position   INTEGER;
   BEGIN
      -- buffer_pool_keep/recycle has format {integer | (BUFFERS: integer [,LRU_LATCHES: integer] ) }
      -- the first integer is the size.
      IF (INSTR (p_value, ',') > 1)
      THEN
         end_position := INSTR (p_value, ',');
      ELSE
         end_position := LENGTH (p_value);
      END IF;

      para_value := LOWER (REPLACE (SUBSTR (p_value, 1, end_position), ' '));

      IF (INSTR (para_value, 'buffers:', 1) > 0)
      THEN
         RETURN (TO_NUMBER (TRANSLATE (para_value,
                                       '0123456789befrsu,:)(',
                                       '0123456789'
                                      )
                           )
                );
      ELSE
         -- Above is the end for puffer_pool_keep/recycle.  Below is not changed.
         last_char := NVL (UPPER (SUBSTR (p_value, -1)), ' ');

         IF last_char <> 'K' AND last_char <> 'M' AND last_char <> 'G'
         THEN
            -- Does not have a trailing 'K' or 'M' or 'G'
            RETURN (p_value);
         ELSE
            BEGIN
               numeric_part :=
                         TO_NUMBER (SUBSTR (p_value, 1, LENGTH (p_value) - 1));

               IF last_char = 'K'
               THEN
                  RETURN (TO_CHAR (numeric_part * 1024));
               ELSIF last_char = 'M'
               THEN
                  RETURN (TO_CHAR (numeric_part * 1024 * 1024));
               ELSIF last_char = 'G'
               THEN
                  RETURN (TO_CHAR (numeric_part * 1024 * 1024 * 1024));
               END IF;
            EXCEPTION
               WHEN OTHERS
               THEN
                  -- Can't convert the leading chars to a number, so return the
                  -- original value
                  RETURN (p_value);
            END;
         END IF;
      END IF;
   EXCEPTION
      WHEN OTHERS
      THEN
         RETURN (p_value);
   END;


   /*---------------------------------------------------------
   Show all the rows being waited on
   I18N version
   -----------------------------------------------------------*/
   FUNCTION show_locked_row_41 (lsid IN NUMBER)
      RETURN VARCHAR2
   IS
      --rowid changed between Oracle7 and Oracle8, so we
      --dynamically create the statement to suit.
      cs8         VARCHAR2 (2000)
         := 'SELECT u.name oowner, o.name oname,
                    sys.dbms_rowid.rowid_create(1, s.row_wait_obj#,
                    s.row_wait_file#,
                    s.row_wait_block#,
                    s.row_wait_row#) orowid
             FROM v$session s, sys.obj$ o, sys.user$ u
             WHERE s.row_wait_obj# != -1
                  AND o.obj# = s.row_wait_obj#
                  AND u.user# = o.owner#
                  AND s.sid = :lsid';

      ch          INTEGER;
      ldataline   VARCHAR2 (2000);
      oowner      VARCHAR2 (500);
      oname       VARCHAR2 (500);
      orowid      VARCHAR2 (50);
      rv          NUMBER;
      lsql        VARCHAR2 (2000);
      VERSION     NUMBER;
   BEGIN
      IF full_version IS NULL
      THEN                        -- We don't initialize all sessions in ADK.
         full_version := dbversion;
      END IF;

      lsql := cs8;

      --debug('version='||version||' '||lsql);
      ch := DBMS_SQL.open_cursor;
      DBMS_SQL.parse (ch, lsql, DBMS_SQL.native);
      DBMS_SQL.bind_variable (ch, 'lsid', lsid);
      DBMS_SQL.define_column (ch, 1, oowner, 500);
      DBMS_SQL.define_column (ch, 2, oname, 500);
      DBMS_SQL.define_column (ch, 3, orowid, 50);
      rv := DBMS_SQL.EXECUTE (ch);
      rv := DBMS_SQL.fetch_rows (ch);

      IF rv > 0
      THEN
         --only getting the first one...
         DBMS_SQL.COLUMN_VALUE (ch, 1, oowner);
         DBMS_SQL.COLUMN_VALUE (ch, 2, oname);
         DBMS_SQL.COLUMN_VALUE (ch, 3, orowid);
         --debug(oowner||' '||oname||' '||orowid);
         ldataline := run_stmt (oowner, oname, orowid);
         DBMS_SQL.close_cursor (ch);
         --debug(ldataline);
         RETURN (ldataline);
      ELSE
         RETURN ('ERROR');
      END IF;
   END;                                         --procedure show_locked_row_41

/* ---------------------------------------------------------------
|| Procedure to run the statement built to retrieve the locked row
*/--------------------------------------------------------------
   FUNCTION run_stmt (lowner IN VARCHAR2, lname IN VARCHAR2, lrowid IN VARCHAR2)
      RETURN VARCHAR2
   IS
      c1          INTEGER         DEFAULT 0;
      rc          INTEGER         DEFAULT 0;
      lsql        VARCHAR2 (2000);
      ldataline   VARCHAR2 (2000);
      nrows       INTEGER;
   BEGIN
      --debug('Entering run_stmt');
      --Only one column to be bound...a long string
      c1 := DBMS_SQL.open_cursor;
      lsql :=
            'SELECT '
         || '''Table="'
         || lowner
         || '.'
         || lname
         || '" ''||'
         || '''rowid="'
         || lrowid
         || '"''||'
         || build_select_list (lowner, lname)
         || ' FROM '
         || lowner
         || '.'
         || lname
         || ' WHERE rowid=chartorowid(:lr) ';
      --debug('stmt='||lsql);
      DBMS_SQL.parse (c1, lsql, DBMS_SQL.native);
      DBMS_SQL.bind_variable (c1, 'lr', lrowid);
      DBMS_SQL.define_column (c1, 1, ldataline, 2000);
      --check return codes from function calls
      rc := DBMS_SQL.EXECUTE (c1);
      --debug('rows = '||rc);
      nrows := DBMS_SQL.fetch_rows (c1);
      DBMS_SQL.COLUMN_VALUE (c1, 1, ldataline);
      DBMS_SQL.close_cursor (c1);
      --debug('return string is '||ldataline);
      RETURN (ldataline);
   END;                                                   --procedure run_stmt

   /* ---------------------------------------------------------------
  || Build the select list for the sql stmt based on the columns of
  || the table and their types
  */--------------------------------------------------------------
   FUNCTION build_select_list (lowner IN VARCHAR2, lname IN VARCHAR2)
      RETURN VARCHAR2
   IS
         cols rc;
      str_cols VARCHAR(1024) :=
           'SELECT   DECODE (data_type,
                          ''NUMBER'', ''to_char('' || column_name || '')'',
                          ''DATE'', ''to_char('' || column_name || '')'',
                          column_name
                         ) newcol,
                  column_name
             FROM dba_tab_columns
            WHERE owner = :lowner
              AND table_name = :lname
              AND data_type IN
                     (''CHAR'',
                      ''VARCHAR2'',
                      ''DATE'',
                      ''NUMBER'',
                      ''NCHAR'',
                      ''NVARCHAR2''
                     )
            ORDER BY column_id ASC';

      lselstmt   VARCHAR2 (2000) := NULL;
      lColName  VARCHAR2 (100);
      lNewColName VARCHAR2 (100);
   BEGIN
     OPEN cols FOR str_cols USING lowner, lname;

     LOOP
        FETCH cols into lNewColName,lColName;

         EXIT WHEN cols%NOTFOUND OR
                   LENGTH (lselstmt)
                   + LENGTH (lColName)
                   + 11
                   + LENGTH (lNewColName) > 1500;


         IF (LENGTH (lselstmt) != 0)
         THEN
            lselstmt := lselstmt || '||';
         --debug('prefixing'||lselstmt);
         END IF;

         lselstmt :=
               lselstmt
            || ''' '
            || lColName
            || '="''||'
            || lNewColName
            || '||''"''';
      END LOOP;

      CLOSE cols;

      --and tack a handle on the end of it...
      lselstmt := lselstmt || ' ' || ' OUTSTR ';
      --debug(lselstmt);
      RETURN (lselstmt);
   END;


   -- Take a string and convert it to a number
   -- If string isn't in number format return -1
   FUNCTION stringToDigit(str IN VARCHAR2)
      RETURN NUMBER
   AS
     numstr     NUMBER;
   BEGIN
       BEGIN
          numstr := TO_NUMBER(str);

       EXCEPTION
          WHEN OTHERS THEN
             numstr := -1;
       END;

       RETURN numstr;

   END stringToDigit;

  --------------------------------------------------
  --Acquire and return the full dbms version number
  --------------------------------------------------
   FUNCTION dbversion
      RETURN VARCHAR2
   IS
      db_version   VARCHAR2 (20);

      CURSOR c1
      IS
         SELECT SUBSTR (SUBSTR (banner, INSTR (banner, 'Release ') + 8),
                        1,
                        INSTR (SUBSTR (banner, INSTR (banner, 'Release ') + 8),
                               ' '
                              )
                       )
           FROM v$version
          WHERE banner LIKE 'Oracle%' OR banner LIKE 'Personal Oracle%';
   BEGIN
      --The first row contains the dbms version...I am assured.
      OPEN c1;

      FETCH c1
       INTO db_version;

      CLOSE c1;

      --debug('Major Version: '||db_version);
      RETURN (db_version);
     EXCEPTION
      WHEN OTHERS
      THEN
         raise_application_error (-20100,
                                     'Exception in version check'
                                  || SQLCODE
                                  || ':'
                                  || SQLERRM
                                 );
   -- debug('Exception in version check'||sqlcode||':'||sqlerrm);
   END; --function dbversion

    -- Function get to version number in a number
  FUNCTION get_db_version RETURN NUMBER
   IS
      db_version   NUMBER;
   BEGIN
      EXECUTE IMMEDIATE
         'SELECT TO_NUMBER (SUBSTR (VERSION, 1, INSTR (VERSION, ''.'', 1, 2) - 1), ''99.99'')
                        FROM  v$instance'
         INTO db_version;

      RETURN db_version;
   EXCEPTION
      WHEN OTHERS
      THEN
         EXECUTE IMMEDIATE 'SELECT TO_NUMBER (SUBSTR (VERSION, 1, INSTR (VERSION, ''.'') - 1),
                            ''99.99'') FROM v$instance' INTO db_version;
         RETURN db_version;
   END get_db_version;

   --
   -- Functions to help decipher shared pool structure
   --
   FUNCTION sga_cat2 (p_pool VARCHAR2, p_name VARCHAR2)
      RETURN VARCHAR2
   IS
      l_sga_cat   VARCHAR2 (30);
   BEGIN
      IF     p_pool IN ('shared pool', 'large pool', 'java pool')
         AND p_name IN ('sql area', 'library cache', 'free memory')
      THEN
         l_sga_cat := p_name;
      ELSE
         l_sga_cat := 'Other Used';
      END IF;

      RETURN l_sga_cat;
   END;

   FUNCTION sga_cat (p_pool VARCHAR2, p_name VARCHAR2)
      RETURN VARCHAR2
   IS
      l_sga_cat   VARCHAR2 (30);
   BEGIN
      IF p_pool IS NULL
      THEN
         l_sga_cat := p_name;
      ELSE
         l_sga_cat := p_pool;
      END IF;

      RETURN l_sga_cat;
   END;

   --
   -- This function returns the long SQL text string.  It attempts this in a
   -- number of ways to work around problems with hash values in various
   -- releases of Oracle
   --
   FUNCTION get_long_sqltext (p_hash_value NUMBER, p_address RAW)
      RETURN VARCHAR2
   IS
      c_get_sqltext_newlines_hash rc;
      str_get_sqltext_newlines_hash VARCHAR2(512) :=
             'SELECT   sql_text
              FROM v$sqltext_with_newlines
              WHERE hash_value = :p_hash_value AND address = :p_address
              ORDER BY piece';

      c_get_sqltext_nl_nohash rc;
      str_get_sqltext_nl_nohash VARCHAR2(512) :=
              'SELECT   sql_text
               FROM v$sqltext_with_newlines
               WHERE address = :p_address
               ORDER BY piece';

      c_get_sql_hash rc;
      str_get_sql_hash VARCHAR2(128) :=
              'SELECT sql_text
               FROM v$sql
               WHERE hash_value = :p_hash_value AND address = :p_address';

      l_sql     VARCHAR (32512) := '';            -- The Max supported by DOA
      lsqlpiece VARCHAR2(1000);
      n         NUMBER          := 0;
      VERSION   VARCHAR2 (10);
   BEGIN
      IF full_version IS NULL
      THEN                        -- We don't initialize all sessions in ADK.
         full_version := dbversion;
      END IF;

      VERSION := SUBSTR (full_version, 1, INSTR (full_version, '.', 1, 3) - 1);

      --
      -- First try v$sqltext via hash; UNLESS the version
      -- is 8.1.5, in which case this will cause an infinite
      -- loop
      --
      --IF  exact_db_version(v1, v2, v3) NOT LIKE '8.1.5.%' THEN
      IF VERSION <> '8.1.5'
      THEN
         OPEN c_get_sqltext_newlines_hash for str_get_sqltext_newlines_hash using p_hash_value, p_address;
         LOOP
            FETCH c_get_sqltext_newlines_hash into lsqlpiece;

            EXIT WHEN c_get_sqltext_newlines_hash%NOTFOUND;

            l_sql := l_sql || lsqlpiece;
         END LOOP;

         CLOSE c_get_sqltext_newlines_hash;
      END IF;

      --dbms_output.put_line('Found '||length(l_sql)||' from sqltext_newlines_hash');
      -- Get anything?  If not, try looking at v$sql
      IF LENGTH (l_sql) = 0 OR l_sql IS NULL
      THEN
         OPEN c_get_sql_hash for str_get_sql_hash using p_hash_value, p_address;
         LOOP
            FETCH c_get_sql_hash into lsqlpiece;

            EXIT WHEN c_get_sql_hash%NOTFOUND;

            l_sql := l_sql || lsqlpiece;
         END LOOP;

         CLOSE c_get_sql_hash;


         --dbms_output.put_line('Found '||length(l_sql)||' from sql');

         --
         -- If we got nothing try v$sqltext_with_newlines but drop the hash
         -- Also do this if the text is greater than 1000 bytes
         --
         -- l_sql:='';
         IF LENGTH (l_sql) = 0 OR LENGTH (l_sql) >= 999 OR l_sql IS NULL
         THEN
            OPEN c_get_sqltext_nl_nohash for str_get_sqltext_nl_nohash using p_address;
            LOOP
                FETCH c_get_sqltext_nl_nohash into lsqlpiece;

                EXIT WHEN c_get_sqltext_nl_nohash%NOTFOUND;

                l_sql := l_sql || lsqlpiece;
            END LOOP;

            CLOSE c_get_sqltext_nl_nohash;

         --dbms_output.put_line('Found '||length(l_sql)||' from sqltext_newlines_nohash');
         END IF;
      END IF;

      --
      -- That's all folks.....
      --
      RETURN (REPLACE (l_sql, CHR (0)));
   -- ADK can't handle a NULL character in a string.
   EXCEPTION
      WHEN VALUE_ERROR
      THEN
         -- Pretty unlikely that we'll see statmenets > 32K, but if we do....
         RETURN (REPLACE (l_sql, CHR (0)));
   -- ADK can't handle a NULL character in a string.
   END;

   FUNCTION lock_type_decode (type_p VARCHAR2, id2_p NUMBER DEFAULT -1)
      RETURN VARCHAR2
   IS
      return_string   VARCHAR2 (100);
   BEGIN

      IF lock_type_tab.EXISTS(type_p) THEN
       return_string := lock_type_tab(type_p);
      END IF;

      IF return_string IS NULL THEN

    -- TODO:  better to go against v$lock_type but this view only came in
    -- in 10g
    IF type_p = 'PE'
    THEN
    return_string := 'Parameter';
    ELSIF type_p = 'PG'
    THEN
    return_string := 'Global Parameter';
    ELSIF type_p = 'PV'
    THEN
    return_string := 'KSV slave startup';
    ELSIF type_p = 'AS'
    THEN
    return_string := 'Service Operations';
    ELSIF type_p = 'PD'
    THEN
    return_string := 'Property Lock';
    ELSIF type_p = 'CF'
    THEN
    return_string := 'Controlfile Transaction';
    ELSIF type_p = 'PW'
    THEN
    return_string := 'Buffer Cache PreWarm';
    ELSIF type_p = 'RO'
    THEN
    return_string := 'Multiple Object Reuse';
    ELSIF type_p = 'WS'
    THEN
    return_string := 'LogWriter Standby';
    ELSIF type_p = 'WL'
    THEN
    return_string := 'Being Written Redo Log';
    ELSIF type_p = 'DF'
    THEN
    return_string := 'Datafile Online in RAC';
    ELSIF type_p = 'PL'
    THEN
    return_string := 'Transportable Tablespace';
    ELSIF type_p = 'XR'
    THEN
    return_string := 'Quiesce / Force Logging';
    ELSIF type_p = 'TA'
    THEN
    return_string := 'Instance Undo';
    ELSIF type_p = 'TE'
    THEN
    return_string := 'KTF broadcast';
    ELSIF type_p = 'RW'
    THEN
    return_string := 'Materialized View Flags';
    ELSIF type_p = 'PI'
    THEN
    return_string := 'Remote PX Process Spawn Status';
    ELSIF type_p = 'PS'
    THEN
    return_string := 'PX Process Reservation';
    ELSIF type_p = 'PT'
    THEN
    return_string := 'ASM Partnership and Status Table';
    ELSIF type_p = 'PM'
    THEN
    return_string := 'ASM PST Signalling';
    ELSIF type_p = 'SH'
    THEN
    return_string := 'Active Session History Flushing';
    ELSIF type_p = 'BL'
    THEN
    return_string := 'Buffer hash table instance lock';
    ELSIF type_p = 'CF'
    THEN
    return_string := 'Control file schema global enqueue lock';
    ELSIF type_p = 'CI'
    THEN
    return_string := 'Cross-instance function invocation instance lock';
    ELSIF type_p = 'CS'
    THEN
    return_string := 'Control file schema global enqueue lock';
    ELSIF type_p = 'CU'
    THEN
    return_string := 'Cursor bind lock';
    ELSIF type_p = 'DF'
    THEN
    return_string := 'Data file instance lock';
    ELSIF type_p = 'DL'
    THEN
    return_string := 'Direct loader parallel index create';
    ELSIF type_p = 'DM'
    THEN
    return_string := 'Mount/startup db primary/secondary instance lock';
    ELSIF type_p = 'DR'
    THEN
    return_string := 'Distributed recovery process lock';
    ELSIF type_p = 'DX'
    THEN
    return_string := 'Distributed transaction entry lock';
    ELSIF type_p = 'FI'
    THEN
    return_string := 'SGA open-file information lock';
    ELSIF type_p = 'FS'
    THEN
    return_string := 'File set lock';
    ELSIF type_p = 'HW'
    THEN
    return_string :=
       'Space management operations on a specific segment lock';
    ELSIF type_p = 'IN'
    THEN
    return_string := 'Instance number lock';
    ELSIF type_p = 'IR'
    THEN
    return_string :=
       'Instance recovery serialization global enqueue lock';
    ELSIF type_p = 'IS'
    THEN
    return_string := 'Instance state lock';
    ELSIF type_p = 'IV'
    THEN
    return_string := 'Library cache invalidation instance lock';
    ELSIF type_p = 'JQ'
    THEN
    return_string := 'Job queue lock';
    ELSIF type_p = 'KK'
    THEN
    return_string := 'Thread kick lock';
    ELSIF type_p = 'MB'
    THEN
    return_string := 'Master buffer hash table instance lock';
    ELSIF type_p = 'MM'
    THEN
    return_string := 'Mount definition gloabal enqueue lock';
    ELSIF type_p = 'MR'
    THEN
    return_string := 'Media recovery lock';
    ELSIF type_p = 'PF'
    THEN
    return_string := 'Password file lock';
    ELSIF type_p = 'PI'
    THEN
    return_string := 'Parallel operation lock PI';
    ELSIF type_p = 'PR'
    THEN
    return_string := 'Process startup lock';
    ELSIF type_p = 'PS'
    THEN
    return_string := 'Parallel operation lock PS';
    ELSIF type_p = 'RE'
    THEN
    return_string := 'USE_ROW_ENQUEUE enforcement lock';
    ELSIF type_p = 'RT'
    THEN
    return_string := 'Redo thread global enqueue lock';
    ELSIF type_p = 'RW'
    THEN
    return_string := 'Row wait enqueue lock';
    ELSIF type_p = 'SC'
    THEN
    return_string := 'System commit number instance lock';
    ELSIF type_p = 'SH'
    THEN
    return_string := 'System commit number high water mark enqueue lock';
    ELSIF type_p = 'SM'
    THEN
    return_string := 'SMON lock';
    ELSIF type_p = 'SN'
    THEN
    return_string := 'Sequence number instance lock';
    ELSIF type_p = 'SQ'
    THEN
    return_string := 'Sequence number enqueue lock';
    ELSIF type_p = 'SS'
    THEN
    return_string := 'Sort segment lock';
    ELSIF type_p = 'ST'
    THEN
    return_string := 'Space transaction enqueue lock';
    ELSIF type_p = 'SV'
    THEN
    return_string := 'Sequence number value lock';
    ELSIF type_p = 'TA'
    THEN
    return_string := 'Generic enqueue lock';
    ELSIF type_p = 'TD'
    THEN
    return_string := 'DDL enqueue lock';
    ELSIF type_p = 'TE'
    THEN
    return_string := 'Extend-segment enqueue lock';
    ELSIF type_p = 'TM'
    THEN
    return_string := 'DML enqueue lock';
    ELSIF type_p = 'TO'
    THEN
    return_string := 'Temporary object operations lock';
    ELSIF type_p = 'TT'
    THEN
    return_string := 'Temporary table enqueue lock';
    ELSIF type_p = 'TX'
    THEN
    return_string := 'Transaction enqueue lock';
    ELSIF type_p = 'UL'
    THEN
    return_string := 'User supplied lock';
    ELSIF type_p = 'UN'
    THEN
    return_string := 'User name lock';
    ELSIF type_p = 'US'
    THEN
    return_string := 'Undo segment DDL lock';
    ELSIF type_p = 'WL'
    THEN
    return_string := 'Being-written redo log instance lock';
    ELSIF type_p = 'WS'
    THEN
    return_string := 'Write-atomic-log-switch global enqueue lock';
    ELSIF type_p = 'TS'
    THEN
    return_string :=
       'Temporary segment or new block allocation enqueue lock';
    ELSIF type_p = 'LS'
    THEN
    return_string := 'Log start/log switch enqueue lock';
    ELSIF type_p = 'DT'
    THEN
    return_string := 'Default Temporary Tablespace Enqueue';
    ELSIF type_p = 'DV'
    THEN
    return_string := 'Diana Version Enqueue';
    ELSIF type_p = 'IA'
    THEN
    return_string := 'Internet Application Server Enqueue';
    ELSIF type_p = 'KM'
    THEN
    return_string := 'Scheduler Modification and Loading Enqueue';
    ELSIF type_p = 'KT'
    THEN
    return_string := 'Scheduler Top Plan Enqueue';
    ELSIF type_p = 'SR'
    THEN
    return_string := 'Synchronized Replication Enqueue';
    ELSIF type_p = 'MD'
    THEN
    return_string := 'Change Data Capture Materialized View Log';
    ELSIF type_p = 'JD'
    THEN
    return_string := 'DBMS Jobs enqueue/lock';
    ELSIF type_p = 'FB'
    THEN
    return_string :=
       'Formatting a range of Bitmap Blocks (BMBs) for ASSM';
    ELSIF type_p = 'SW'
    THEN
    return_string := 'Suspend Writes (ALTER SYSTEM SUSPEND|RESUME)';
    ELSIF type_p = 'XR'
    THEN
    return_string :=
    'ALTER SYSTEM QUIESCE RESTRICTED enqueue or ALTER DATABASE OPEN in RAC mode enqueue';
    ELSIF type_p = 'AF'
    THEN
    return_string := 'Advisor task lock';
    ELSIF type_p = 'AG'
    THEN
    return_string := 'Workspace lock';
    ELSIF type_p = 'AS'
    THEN
    return_string := 'New service activation';
    ELSIF type_p = 'AW'
    THEN
    return_string := 'Workspace AW$ table access lock';
    ELSIF type_p = 'CT'
    THEN
    return_string := 'Change tracking lock';
    ELSIF type_p = 'DP'
    THEN
    return_string := 'LDAP parameters access lock';
    ELSIF type_p = 'FU'
    THEN
    return_string := 'Capture of the DB Feature Usage and HWM Stat lock';
    ELSIF type_p = 'IT'
    THEN
    return_string := 'Temp table meta-data pinning/recreation lock';
    ELSIF type_p = 'JS'
    THEN
    return_string := 'Job cache lock';
    ELSIF type_p = 'MN'
    THEN
    return_string := 'LogMiner dictionary and synchronize lock';
    ELSIF type_p = 'MW'
    THEN
    return_string :=
    'Calibration of the manageability schedules with the Maintenance Window';
    ELSIF type_p = 'RO'
    THEN
    return_string := 'Coordinates flushing of multiple objects lock';
    ELSIF type_p = 'RS'
    THEN
    return_string := 'Space reclaimable operations lock';
    ELSIF type_p = 'TB'
    THEN
    return_string :=
        'Writes to the SQL Tuning Base Existence Cache lock';
    ELSIF type_p = 'TC'
    THEN
    return_string := 'Tablespace checkpoint lock';
    ELSIF type_p = 'TL'
    THEN
    return_string := 'Threshold log table lock';
    ELSIF type_p = 'TQ'
    THEN
    return_string := 'Queue table lock';
    ELSIF type_p = 'WF'
    THEN
    return_string := 'Flushing of snapshots lock';
    ELSIF type_p = 'WP'
    THEN
    return_string := 'Purging and baselines lock';
    ELSIF type_p = 'LA'
    THEN
    return_string := 'Library cache lock instance lock (A=namespace)';
    ELSIF type_p = 'LB'
    THEN
    return_string := 'Library cache lock instance lock (B=namespace)';
    ELSIF type_p = 'LC'
    THEN
    return_string := 'Library cache lock instance lock (C=namespace)';
    ELSIF type_p = 'LD'
    THEN
    return_string := 'Library cache lock instance lock (D=namespace)';
    ELSIF type_p = 'LE'
    THEN
    return_string := 'Library cache lock instance lock (E=namespace)';
    ELSIF type_p = 'LF'
    THEN
    return_string := 'Library cache lock instance lock (F=namespace)';
    ELSIF type_p = 'LG'
    THEN
    return_string := 'Library cache lock instance lock (G=namespace)';
    ELSIF type_p = 'LH'
    THEN
    return_string := 'Library cache lock instance lock (H=namespace)';
    ELSIF type_p = 'LI'
    THEN
    return_string := 'Library cache lock instance lock (I=namespace)';
    ELSIF type_p = 'LJ'
    THEN
    return_string := 'Library cache lock instance lock (J=namespace)';
    ELSIF type_p = 'LK'
    THEN
    return_string := 'Library cache lock instance lock (K=namespace)';
    ELSIF type_p = 'LL'
    THEN
    return_string := 'Library cache lock instance lock (L=namespace)';
    ELSIF type_p = 'LM'
    THEN
    return_string := 'Library cache lock instance lock (M=namespace)';
    ELSIF type_p = 'LN'
    THEN
    return_string := 'Library cache lock instance lock (N=namespace)';
    ELSIF type_p = 'LO'
    THEN
    return_string := 'Library cache lock instance lock (O=namespace)';
    ELSIF type_p = 'LP'
    THEN
    return_string := 'Library cache lock instance lock (P=namespace)';
    ELSIF type_p = 'PA'
    THEN
    return_string := 'Library cache pin instance lock (A=namespace)';
    ELSIF type_p = 'PB'
    THEN
    return_string := 'Library cache pin instance lock (B=namespace)';
    ELSIF type_p = 'PC'
    THEN
    return_string := 'Library cache pin instance lock (C=namespace)';
    ELSIF type_p = 'PD'
    THEN
    return_string := 'Library cache pin instance lock (D=namespace)';
    ELSIF type_p = 'PE'
    THEN
    return_string := 'Library cache pin instance lock (E=namespace)';
    ELSIF type_p = 'PF'
    THEN
    return_string := 'Library cache pin instance lock (F=namespace)';
    ELSIF type_p = 'PG'
    THEN
    return_string := 'Library cache pin instance lock (G=namespace)';
    ELSIF type_p = 'PH'
    THEN
    return_string := 'Library cache pin instance lock (H=namespace)';
    ELSIF type_p = 'PI'
    THEN
    return_string := 'Library cache pin instance lock (I=namespace)';
    ELSIF type_p = 'PJ'
    THEN
    return_string := 'Library cache pin instance lock (J=namespace)';
    ELSIF type_p = 'PL'
    THEN
    return_string := 'Library cache pin instance lock (K=namespace)';
    ELSIF type_p = 'PK'
    THEN
    return_string := 'Library cache pin instance lock (L=namespace)';
    ELSIF type_p = 'PM'
    THEN
    return_string := 'Library cache pin instance lock (M=namespace)';
    ELSIF type_p = 'PN'
    THEN
    return_string := 'Library cache pin instance lock (N=namespace)';
    ELSIF type_p = 'PO'
    THEN
    return_string := 'Library cache pin instance lock (O=namespace)';
    ELSIF type_p = 'PP'
    THEN
    return_string := 'Library cache pin instance lock (P=namespace)';
    ELSIF type_p = 'PQ'
    THEN
    return_string := 'Library cache pin instance lock (Q=namespace)';
    ELSIF type_p = 'PR'
    THEN
    return_string := 'Library cache pin instance lock (R=namespace)';
    ELSIF type_p = 'PS'
    THEN
    return_string := 'Library cache pin instance lock (S=namespace)';
    ELSIF type_p = 'PT'
    THEN
    return_string := 'Library cache pin instance lock (T=namespace)';
    ELSIF type_p = 'PU'
    THEN
    return_string := 'Library cache pin instance lock (U=namespace)';
    ELSIF type_p = 'PV'
    THEN
    return_string := 'Library cache pin instance lock (V=namespace)';
    ELSIF type_p = 'PW'
    THEN
    return_string := 'Library cache pin instance lock (W=namespace)';
    ELSIF type_p = 'PX'
    THEN
    return_string := 'Library cache pin instance lock (X=namespace)';
    ELSIF type_p = 'PY'
    THEN
    return_string := 'Library cache pin instance lock (Y=namespace)';
    ELSIF type_p = 'PZ'
    THEN
    return_string := 'Library cache pin instance lock (Z=namespace)';
    ELSIF type_p = 'QA'
    THEN
    return_string := 'Row cache instance lock (A=cache)';
    ELSIF type_p = 'QB'
    THEN
    return_string := 'Row cache instance lock (B=cache)';
    ELSIF type_p = 'QC'
    THEN
    return_string := 'Row cache instance lock (C=cache)';
    ELSIF type_p = 'QD'
    THEN
    return_string := 'Row cache instance lock (D=cache)';
    ELSIF type_p = 'QE'
    THEN
    return_string := 'Row cache instance lock (E=cache)';
    ELSIF type_p = 'QF'
    THEN
    return_string := 'Row cache instance lock (F=cache)';
    ELSIF type_p = 'QG'
    THEN
    return_string := 'Row cache instance lock (G=cache)';
    ELSIF type_p = 'QH'
    THEN
    return_string := 'Row cache instance lock (H=cache)';
    ELSIF type_p = 'QI'
    THEN
    return_string := 'Row cache instance lock (I=cache)';
    ELSIF type_p = 'QJ'
    THEN
    return_string := 'Row cache instance lock (J=cache)';
    ELSIF type_p = 'QL'
    THEN
    return_string := 'Row cache instance lock (K=cache)';
    ELSIF type_p = 'QK'
    THEN
    return_string := 'Row cache instance lock (L=cache)';
    ELSIF type_p = 'QM'
    THEN
    return_string := 'Row cache instance lock (M=cache)';
    ELSIF type_p = 'QN'
    THEN
    return_string := 'Row cache instance lock (N=cache)';
    ELSIF type_p = 'QO'
    THEN
    return_string := 'Row cache instance lock (O=cache)';
    ELSIF type_p = 'QP'
    THEN
    return_string := 'Row cache instance lock (P=cache)';
    ELSIF type_p = 'QQ'
    THEN
    return_string := 'Row cache instance lock (Q=cache)';
    ELSIF type_p = 'QR'
    THEN
    return_string := 'Row cache instance lock (R=cache)';
    ELSIF type_p = 'QS'
    THEN
    return_string := 'Row cache instance lock (S=cache)';
    ELSIF type_p = 'QT'
    THEN
    return_string := 'Row cache instance lock (T=cache)';
    ELSIF type_p = 'QU'
    THEN
    return_string := 'Row cache instance lock (U=cache)';
    ELSIF type_p = 'QV'
    THEN
    return_string := 'Row cache instance lock (V=cache)';
    ELSIF type_p = 'QW'
    THEN
    return_string := 'Row cache instance lock (W=cache)';
    ELSIF type_p = 'QX'
    THEN
    return_string := 'Row cache instance lock (X=cache)';
    ELSIF type_p = 'QY'
    THEN
    return_string := 'Row cache instance lock (Y=cache)';
    ELSIF type_p = 'QZ'
    THEN
    return_string := 'Row cache instance lock (Z=cache)';
    ELSIF type_p = 'SJ'
    THEN
    return_string := 'KTSJ Slave Task Cancel';
    ELSIF type_p = 'RR'
    THEN
    return_string := 'Workload Capture and Replay';
    ELSIF type_p = 'CN'
    THEN
    return_string := 'KTCN REG enq';
    ELSIF type_p = 'SE'
    THEN
    return_string := 'Session Migration';
    ELSIF type_p = 'TH'
    THEN
    return_string := 'Threshold Chain';
    ELSIF type_p = 'RC'
    THEN
    return_string := 'Result Set Cache';
    ELSIF type_p = 'AE'
    THEN
    return_string := 'Edition Lock';
    ELSIF type_p = 'AK'
    THEN
    return_string := 'GES Deadlock Test';
    ELSIF type_p = 'DI'
    THEN
    return_string := 'GES Internal';
    ELSIF type_p = 'RM'
    THEN
    return_string := 'GES Resource Remastering';
    ELSIF type_p = 'FP'
    THEN
    return_string := 'File Object';
    ELSIF type_p = 'FM'
    THEN
    return_string := 'File Mapping';
    ELSIF type_p = 'XY'
    THEN
    return_string := 'Internal Test';
    ELSIF type_p = 'RU'
    THEN
    return_string := 'Rolling Upgrade';
    ELSIF type_p = 'DS'
    THEN
    return_string := 'Database Suspend';
    ELSIF type_p = 'KO'
    THEN
    return_string := 'Multiple Object Checkpoint';
    ELSIF type_p = 'WR'
    THEN
    return_string := 'LNS archiving log';
    ELSIF type_p = 'RN'
    THEN
    return_string := 'Redo Log Nab Computation';
    ELSIF type_p = 'RP'
    THEN
    return_string := 'Resilver / Repair';
    ELSIF type_p = 'BR'
    THEN
    return_string := 'Backup/Restore';
    ELSIF type_p = 'ID'
    THEN
    return_string := 'NID';
    ELSIF type_p = 'SB'
    THEN
    return_string := 'LogicalStandby';
    ELSIF type_p = 'FL'
    THEN
    return_string := 'Flashback database log';
    ELSIF type_p = 'FD'
    THEN
    return_string := 'Flashback Database';
    ELSIF type_p = 'FW'
    THEN
    return_string := 'Flashback Writer';
    ELSIF type_p = 'TF'
    THEN
    return_string := 'Temporary File';
    ELSIF type_p = 'SK'
    THEN
    return_string := 'Shrink Segment';
    ELSIF type_p = 'TW'
    THEN
    return_string := 'Cross-Instance Transaction';
    ELSIF type_p = 'SU'
    THEN
    return_string := 'SaveUndo Segment';
    ELSIF type_p = 'IM'
    THEN
    return_string := 'Kti blr lock';
    ELSIF type_p = 'HV'
    THEN
    return_string := 'Direct Loader High Water Mark';
    ELSIF type_p = 'HQ'
    THEN
    return_string := 'Hash Queue';
    ELSIF type_p = 'HP'
    THEN
    return_string := 'Queue Page';
    ELSIF type_p = 'Q '
    THEN
    return_string := 'Row Cache';
    ELSIF type_p = 'V '
    THEN
    return_string := 'Library Cache Lock 3';
    ELSIF type_p = 'E '
    THEN
    return_string := 'Library Cache Lock 2';
    ELSIF type_p = 'L '
    THEN
    return_string := 'Library Cache Lock 1';
    ELSIF type_p = 'Y '
    THEN
    return_string := 'Library Cache Pin 3';
    ELSIF type_p = 'G '
    THEN
    return_string := 'Library Cache Pin 2';
    ELSIF type_p = 'N '
    THEN
    return_string := 'Library Cache Pin 1';
    ELSIF type_p = 'OC'
    THEN
    return_string := 'Outline Cache';
    ELSIF type_p = 'OL'
    THEN
    return_string := 'Outline Name';
    ELSIF type_p = 'IL'
    THEN
    return_string := 'Label Security';
    ELSIF type_p = 'CL'
    THEN
    return_string := 'Label Security cache';
    ELSIF type_p = 'MK'
    THEN
    return_string := 'Master Key';
    ELSIF type_p = 'OW'
    THEN
    return_string := 'Encryption Wallet';
    ELSIF type_p = 'AU'
    THEN
    return_string := 'Audit index file';
    ELSIF type_p = 'DB'
    THEN
    return_string := 'DbsDriver';
    ELSIF type_p = 'MS'
    THEN
    return_string := 'Materialized View Refresh Log';
    ELSIF type_p = 'BF'
    THEN
    return_string := 'BLOOM FILTER';
    ELSIF type_p = 'KP'
    THEN
    return_string := 'Kupp Process Startup';
    ELSIF type_p = 'SI'
    THEN
    return_string := 'Streams Table Instantiation';
    ELSIF type_p = 'ZG'
    THEN
    return_string := 'File Group';
    ELSIF type_p = 'JI'
    THEN
    return_string := 'Materialized View';
    ELSIF type_p = 'AT'
    THEN
    return_string := 'Alter Tablespace';
    ELSIF type_p = 'MH'
    THEN
    return_string := 'AQ Notification Mail Host';
    ELSIF type_p = 'ML'
    THEN
    return_string := 'AQ Notification Mail Port';
    ELSIF type_p = 'SF'
    THEN
    return_string := 'AQ Notification Sender';
    ELSIF type_p = 'XH'
    THEN
    return_string := 'AQ Notification No-Proxy';
    ELSIF type_p = 'WA'
    THEN
    return_string := 'AQ Notification Watermark';
    ELSIF type_p = 'RF'
    THEN
    return_string := 'Data Guard Broker';
    ELSIF type_p = 'AO'
    THEN
    return_string := 'MultiWriter Object Access';
    ELSIF type_p = 'OQ'
    THEN
    return_string := 'OLAPI Histories';
    ELSIF type_p = 'IZ'
    THEN
    return_string := 'INSTANCE LOCK';
    ELSIF type_p = 'AM'
    THEN
    return_string := 'ASM Enqueue';
    ELSIF type_p = 'CM'
    THEN
    return_string := 'ASM Instance Enqueue';
    ELSIF type_p = 'XQ'
    THEN
    return_string := 'ASM Extent Relocation Enqueue';
    ELSIF type_p = 'AD'
    THEN
    return_string := 'ASM Disk AU Lock';
    ELSIF type_p = 'DG'
    THEN
    return_string := 'ASM Disk Group Modification';
    ELSIF type_p = 'DD'
    THEN
    return_string := 'ASM Local Disk Group';
    ELSIF type_p = 'HD'
    THEN
    return_string := 'ASM Disk Header';
    ELSIF type_p = 'DQ'
    THEN
    return_string := 'ASM RBAL doorbell';
    ELSIF type_p = 'DN'
    THEN
    return_string := 'Diskgroup number generator';
    ELSIF type_p = 'FA'
    THEN
    return_string := 'ASM File Access Lock';
    ELSIF type_p = 'FR'
    THEN
    return_string := 'Disk Group Recovery';
    ELSIF type_p = 'FG'
    THEN
    return_string := 'ACD Relocation Gate Enqueue';
    ELSIF type_p = 'FT'
    THEN
    return_string := 'Disk Group Redo Generation';
    ELSIF type_p = 'FC'
    THEN
    return_string := 'Disk Group Chunk Mount';
    ELSIF type_p = 'RB'
    THEN
    return_string := 'ASM Rollback Recovery';
    ELSE
    return_string := type_p;
    END IF;
  END IF;

      /*  SELECT DECODE
                  (type_p,
                   'BL', 'Buffer hash table instance lock',
                   'CF', 'Control file schema global enqueue lock',
                   'CI', 'Cross-instance function invocation instance lock',
                   'CS', 'Control file schema global enqueue lock',
                   'CU', 'Cursor bind lock',
                   'DF', 'Data file instance lock',
                   'DL', 'Direct loader parallel index create',
                   'DM', 'Mount/startup db primary/secondary instance lock',
                   'DR', 'Distributed recovery process lock',
                   'DX', 'Distributed transaction entry lock',
                   'FI', 'SGA open-file information lock',
                   'FS', 'File set lock',
                   'HW', 'Space management operations on a specific segment lock',
                   'IN', 'Instance number lock',
                   'IR', 'Instance recovery serialization global enqueue lock',
                   'IS', 'Instance state lock',
                   'IV', 'Library cache invalidation instance lock',
                   'JQ', 'Job queue lock',
                   'KK', 'Thread kick lock',
                   'MB', 'Master buffer hash table instance lock',
                   'MM', 'Mount definition gloabal enqueue lock',
                   'MR', 'Media recovery lock',
                   'PF', 'Password file lock',
                   'PI', 'Parallel operation lock PI',
                   'PR', 'Process startup lock',
                   'PS', 'Parallel operation lock PS',
                   'RE', 'USE_ROW_ENQUEUE enforcement lock',
                   'RT', 'Redo thread global enqueue lock',
                   'RW', 'Row wait enqueue lock',
                   'SC', 'System commit number instance lock',
                   'SH', 'System commit number high water mark enqueue lock',
                   'SM', 'SMON lock',
                   'SN', 'Sequence number instance lock',
                   'SQ', 'Sequence number enqueue lock',
                   'SS', 'Sort segment lock',
                   'ST', 'Space transaction enqueue lock',
                   'SV', 'Sequence number value lock',
                   'TA', 'Generic enqueue lock',
                   'TD', 'DDL enqueue lock',
                   'TE', 'Extend-segment enqueue lock',
                   'TM', 'DML enqueue lock',
                   'TO', 'Temporary object operations lock',
                   'TT', 'Temporary table enqueue lock',
                   'TX', 'Transaction enqueue lock',
                   'UL', 'User supplied lock',
                   'UN', 'User name lock',
                   'US', 'Undo segment DDL lock',
                   'WL', 'Being-written redo log instance lock',
                   'WS', 'Write-atomic-log-switch global enqueue lock',
                   'TS', 'Temporary segment or new block allocation enqueue lock',
                   'LS', 'Log start/log switch enqueue lock',
                   'DT', 'Default Temporary Tablespace Enqueue',
                   'DV', 'Diana Version Enqueue',
                   'IA', 'Internet Application Server Enqueue',
                   'KM', 'Scheduler Modification and Loading Enqueue',
                   'KT', 'Scheduler Top Plan Enqueue',
                   'SR', 'Synchronized Replication Enqueue',
                   'MD', 'Change Data Capture Materialized View Log',
                   'JD', 'DBMS Jobs enqueue/lock',
                   'FB', 'Formatting a range of Bitmap Blocks (BMBs) for ASSM',
                   'SW', 'Suspend Writes (ALTER SYSTEM SUSPEND|RESUME)',
                   'XR', 'ALTER SYSTEM QUIESCE RESTRICTED enqueue or ALTER DATABASE OPEN in RAC mode enqueue',
                   'AF', 'Advisor task lock',
                   'AG', 'Workspace lock',
                   'AS', 'New service activation',
                   'AW', 'Workspace AW$ table access lock',
                   'CT', 'Change tracking lock',
                   'DP', 'LDAP parameters access lock',
                   'FU', 'Capture of the DB Feature Usage and HWM Stat lock',
                   'IT', 'Temp table meta-data pinning/recreation lock',
                   'JS', 'Job cache lock',
                   'MN', 'LogMiner dictionary and synchronize lock',
                   'MW', 'Calibration of the manageability schedules with the Maintenance Window',
                   'RO', 'Coordinates flushing of multiple objects lock',
                   'RS', 'Space reclaimable operations lock',
                   'TB', 'Writes to the SQL Tuning Base Existence Cache lock',
                   'TC', 'Tablespace checkpoint lock',
                   'TL', 'Threshold log table lock',
                   'TQ', 'Queue table lock',
                   'WF', 'Flushing of snapshots lock',
                   'WP', 'Purging and baselines lock',
                   DECODE (type_p,
                           'LA', 'Library cache lock instance lock (A=namespace)',
                           'LB', 'Library cache lock instance lock (B=namespace)',
                           'LC', 'Library cache lock instance lock (C=namespace)',
                           'LD', 'Library cache lock instance lock (D=namespace)',
                           'LE', 'Library cache lock instance lock (E=namespace)',
                           'LF', 'Library cache lock instance lock (F=namespace)',
                           'LG', 'Library cache lock instance lock (G=namespace)',
                           'LH', 'Library cache lock instance lock (H=namespace)',
                           'LI', 'Library cache lock instance lock (I=namespace)',
                           'LJ', 'Library cache lock instance lock (J=namespace)',
                           'LK', 'Library cache lock instance lock (K=namespace)',
                           'LL', 'Library cache lock instance lock (L=namespace)',
                           'LM', 'Library cache lock instance lock (M=namespace)',
                           'LN', 'Library cache lock instance lock (N=namespace)',
                           'LO', 'Library cache lock instance lock (O=namespace)',
                           'LP', 'Library cache lock instance lock (P=namespace)',
                           'PA', 'Library cache pin instance lock (A=namespace)',
                           'PB', 'Library cache pin instance lock (B=namespace)',
                           'PC', 'Library cache pin instance lock (C=namespace)',
                           'PD', 'Library cache pin instance lock (D=namespace)',
                           'PE', 'Library cache pin instance lock (E=namespace)',
                           'PF', 'Library cache pin instance lock (F=namespace)',
                           'PG', 'Library cache pin instance lock (G=namespace)',
                           'PH', 'Library cache pin instance lock (H=namespace)',
                           'PI', 'Library cache pin instance lock (I=namespace)',
                           'PJ', 'Library cache pin instance lock (J=namespace)',
                           'PL', 'Library cache pin instance lock (K=namespace)',
                           'PK', 'Library cache pin instance lock (L=namespace)',
                           'PM', 'Library cache pin instance lock (M=namespace)',
                           'PN', 'Library cache pin instance lock (N=namespace)',
                           'PO', 'Library cache pin instance lock (O=namespace)',
                           'PP', 'Library cache pin instance lock (P=namespace)',
                           'PQ', 'Library cache pin instance lock (Q=namespace)',
                           'PR', 'Library cache pin instance lock (R=namespace)',
                           'PS', 'Library cache pin instance lock (S=namespace)',
                           'PT', 'Library cache pin instance lock (T=namespace)',
                           'PU', 'Library cache pin instance lock (U=namespace)',
                           'PV', 'Library cache pin instance lock (V=namespace)',
                           'PW', 'Library cache pin instance lock (W=namespace)',
                           'PX', 'Library cache pin instance lock (X=namespace)',
                           'PY', 'Library cache pin instance lock (Y=namespace)',
                           'PZ', 'Library cache pin instance lock (Z=namespace)',
                           'QA', 'Row cache instance lock (A=cache)',
                           'QB', 'Row cache instance lock (B=cache)',
                           'QC', 'Row cache instance lock (C=cache)',
                           'QD', 'Row cache instance lock (D=cache)',
                           'QE', 'Row cache instance lock (E=cache)',
                           'QF', 'Row cache instance lock (F=cache)',
                           'QG', 'Row cache instance lock (G=cache)',
                           'QH', 'Row cache instance lock (H=cache)',
                           'QI', 'Row cache instance lock (I=cache)',
                           'QJ', 'Row cache instance lock (J=cache)',
                           'QL', 'Row cache instance lock (K=cache)',
                           'QK', 'Row cache instance lock (L=cache)',
                           'QM', 'Row cache instance lock (M=cache)',
                           'QN', 'Row cache instance lock (N=cache)',
                           'QO', 'Row cache instance lock (O=cache)',
                           'QP', 'Row cache instance lock (P=cache)',
                           'QQ', 'Row cache instance lock (Q=cache)',
                           'QR', 'Row cache instance lock (R=cache)',
                           'QS', 'Row cache instance lock (S=cache)',
                           'QT', 'Row cache instance lock (T=cache)',
                           'QU', 'Row cache instance lock (U=cache)',
                           'QV', 'Row cache instance lock (V=cache)',
                           'QW', 'Row cache instance lock (W=cache)',
                           'QX', 'Row cache instance lock (X=cache)',
                           'QY', 'Row cache instance lock (Y=cache)',
                           'QZ', 'Row cache instance lock (Z=cache)',
                           'SJ', 'KTSJ Slave Task Cancel',
                           'RR', 'Workload Capture and Replay',
                           'CN', 'KTCN REG enq',
                           'SE', 'Session Migration',
                           'TH', 'Threshold Chain',
                           'RC', 'Result Set Cache',
                           'AE', 'Edition Lock',
                           type_p
                          )
                  )
          INTO return_string
          FROM DUAL; */

      -- id2 is needed to distinct 'TS' lock.  -1 is used when id2 is not available
      IF type_p = 'TS' AND id2_p = 0
      THEN
         return_string := 'Temporary segment enqueue lock (id2=0)';
      END IF;

      IF type_p = 'TS' AND id2_p = 1
      THEN
         return_string := 'New block allocation enqueue lock (id2=1)';
      END IF;

      RETURN return_string;
   END;

      -- lock_mode is used for both the request mode and hold mode
   FUNCTION lock_mode_decode (mode_p NUMBER)
      RETURN VARCHAR2
   IS
      return_string   VARCHAR2 (20);
   BEGIN
      SELECT DECODE (mode_p,
                     0, 'None',                      /* Mon Lock equivalent */
                     1, 'Null',                                        /* N */
                     2, 'Row-S (SS)',                                  /* L */
                     3, 'Row-X (SX)',                                  /* R */
                     4, 'Share',                                       /* S */
                     5, 'S/Row-X (SSX)',                               /* C */
                     6, 'Exclusive',                                   /* X */
                     TO_CHAR (mode_p)
                    )
        INTO return_string
        FROM DUAL;

      RETURN return_string;
   END;

   FUNCTION wait_detail (
      event_p    IN   VARCHAR2,
      p1text_p   IN   VARCHAR2,
      p1_p       IN   NUMBER,
      p2text_p   IN   VARCHAR2 DEFAULT '',
      p2_p       IN   NUMBER DEFAULT 0,
      p3text_p   IN   VARCHAR2 DEFAULT '',
      p3_p       IN   NUMBER DEFAULT 0
   )
      RETURN VARCHAR2
   IS
      p1detail               VARCHAR2 (512);
      lock_type              VARCHAR2 (10);
      lock_mode              INTEGER;
      default_return_value   VARCHAR2 (2048) := '';
      return_value           VARCHAR2 (2048) := '';
      obj_name               VARCHAR2 (255);
      ch                     INTEGER;
      rv                     INTEGER;
   BEGIN
      -- Set default return value first
      default_return_value := event_p;

      IF (LENGTH (RTRIM (p1text_p)) >= 2)
      THEN
         default_return_value :=
                      default_return_value || ', ' || p1text_p || '=' || p1_p;

         IF (LENGTH (RTRIM (p2text_p)) >= 2)
         THEN
            default_return_value :=
                      default_return_value || ', ' || p2text_p || '=' || p2_p;

            IF (LENGTH (RTRIM (p3text_p)) >= 2)
            THEN
               default_return_value :=
                      default_return_value || ', ' || p3text_p || '=' || p3_p;
            END IF;
         END IF;
      END IF;

      -- IO events.  p1=file#, p2=block# (except DFS db file lock)
      -- Add direct path io as well
      IF (   (p1text_p = 'file#' AND p2text_p = 'block#')
          OR (p1text_p = 'file number' AND p2text_p = 'first dba')
          OR event_p = 'DFS db file lock'
         )
      THEN
         BEGIN
            execute immediate 'SELECT NAME
                               FROM v$dbfile
                               WHERE file# = :p1_p AND ROWNUM = 1' INTO p1detail USING IN p1_p;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN         -- If file name is not found, it must be a temp file.
               p1detail := 'TEMP datafile:' || TO_CHAR (p1_p);
         END;

         return_value := p1detail;
      -- lock events.  p1=name|mode
      ELSIF (event_p = 'enqueue')
      THEN
         lock_type :=
               CHR (BITAND (p1_p, -16777216) / 16777215)
            || CHR (BITAND (p1_p, 16711680) / 65535);
         lock_mode := BITAND (p1_p, 65535);

         BEGIN
            execute immediate 'SELECT NAME
                                FROM SYS.obj$
                               WHERE obj# = :p2_p' INTO obj_name USING IN p2_p;

            return_value :=
                  lock_type_decode (lock_type)
               || ', mode:'
               || lock_mode_decode (lock_mode)
               || ', Object='
               || obj_name;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               return_value :=
                     lock_type_decode (lock_type)
                  || ', mode:'
                  || lock_mode_decode (lock_mode);
         END;
      -- latch event.  p2=latch#
      ELSIF (event_p = 'latch activity' OR event_p = 'latch free')
      THEN
         BEGIN
            execute immediate 'SELECT NAME
                               FROM v$latchname
                               WHERE latch# = :p2_p AND ROWNUM = 1' INTO return_value USING IN p2_p;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               return_value := 'latch#=' || TO_CHAR(p2_p);
         END;
      -- undo event.  p1=segment#
      ELSIF (event_p = 'undo segment recovery')
      THEN
         BEGIN
            execute immediate 'SELECT NAME
                               FROM v$rollname
                               WHERE usn = :p1_p AND ROWNUM = 1' INTO return_value USING IN p1_p;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               return_value := 'RBS#=' || TO_CHAR (p1_p);
         END;
      -- This event is valid at lease in 7.2
      ELSIF (event_p = 'row cache lock')
      THEN
         BEGIN
            execute immediate 'SELECT parameter
                               FROM v$rowcache
                               WHERE cache# = :p1_p AND ROWNUM = 1' INTO return_value USING IN p1_p;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               return_value := 'cache#=' || TO_CHAR (p1_p);
         END;
      END IF;

      -- if the event is covered by above, we add p3 when available
      IF (LENGTH (RTRIM (return_value)) > 1)
      THEN
         IF (LENGTH (RTRIM (p3text_p)) > 1)
         THEN
            return_value :=
               event_p || ', ' || return_value || ', ' || p3text_p || '='
               || p3_p;
         ELSE
            return_value := event_p || ', ' || return_value;
         END IF;
      ELSE
         return_value := default_return_value;
      END IF;

      RETURN return_value;
   EXCEPTION
      WHEN NO_DATA_FOUND
      THEN
         RETURN default_return_value;
   END;

   -- Function job_interval is used to deal with complicate interval setting in dbms_jobs.
   -- Simple setting like 'sysdate+15/24' is handled by clinet.
   -- Complicate setting, like NEXT_DAY(ADD_MONTHS(TRUNC(SYSDATE,'Q'),3),'THURSDAY'), (i.e. The first Thursday in the next quarter), is handled here.
   -- When the interval is set by user's PL/SQL function, as we don't know how to call all user's functions, we have to ignore them.  NULL is returned.
   FUNCTION job_interval(next_date_p DATE, interval_p VARCHAR2) RETURN DATE IS
      interval DATE := NULL;
      stmt     VARCHAR2(32000);
      c        INTEGER;
      rv       NUMBER;
   BEGIN
      stmt := 'SELECT '||REPLACE(LOWER(interval_p),'sysdate',
              'TO_DATE('''||TO_CHAR(next_date_p,'dd/mm/rr hh24:mi:ss')||''',''dd/mm/rr hh24:mi:ss'')')||
              ' FROM DUAL';

      BEGIN
        c := DBMS_SQL.OPEN_CURSOR;
        DBMS_SQL.PARSE(c, stmt, DBMS_SQL.NATIVE);
        DBMS_SQL.DEFINE_COLUMN(c, 1, interval);
        rv := DBMS_SQL.EXECUTE(c);
        rv := DBMS_SQL.FETCH_ROWS(c);
        IF rv >0 THEN
           DBMS_SQL.COLUMN_VALUE(c, 1, interval);
        END IF;
        DBMS_SQL.CLOSE_CURSOR(c);

      --If the expression can't be parsed, return defualt NULL.
      EXCEPTION WHEN OTHERS THEN DBMS_SQL.CLOSE_CURSOR(c);
      END;

      RETURN interval;
   END;

   -- Populate lock event array with entries from v$lock_type table
   -- Used for future proofing of lock types to handle new versions of Oracle rather than having a static list
   -- Will be called when package is initialised
   PROCEDURE populate_lock_type IS

      lv_version   NUMBER;

      arr_type   varchar_tab_typ;
      arr_name   varchar_tab_typ;
   BEGIN

      lv_version := get_db_version;

      IF lv_version >= 10 THEN

        EXECUTE IMMEDIATE 'select type, name from v$lock_type'
        BULK COLLECT INTO arr_type, arr_name;

        FOR idx IN 1..arr_type.COUNT LOOP

         lock_type_tab(arr_type(idx)) := arr_name(idx);

        END LOOP;


      END IF;

   END populate_lock_type;

   FUNCTION is_schema_writable
      RETURN NUMBER
   IS
      l_open_mode             VARCHAR2(128);
      l_database_role         VARCHAR2(128);
      l_guard_status          VARCHAR2(128);
      l_tablespace_status     VARCHAR2(128);
      l_is_schema_unguarded   NUMBER;
   BEGIN
      /* Get database parameters */
      execute immediate 'SELECT open_mode, database_role, guard_status FROM v$database'
        INTO l_open_mode, l_database_role, l_guard_status;

      /* Check if DB is not open READ WRITE */
      IF l_open_mode <> 'READ WRITE'
      THEN
         RETURN 0;
      END IF;

      /* Check if the database is a LOGICAL STANDBY */
      IF l_database_role = 'LOGICAL STANDBY'
      THEN
         IF l_guard_status = 'ALL'
         THEN
            /* If Data Guard is set to all then nothing can be written to */
            RETURN 0;
         ELSE
            /* If it is set to STANDBY or NONE, then some tables can be written to,
               however we do not want to write to tables that are either created by data guard,
               or have not been set to skip DML */
            BEGIN
               EXECUTE IMMEDIATE 'SELECT COUNT (*)
                                    FROM sys.logstdby_support
                                   WHERE     owner = SYS_CONTEXT (''USERENV'', ''CURRENT_SCHEMA'')
                                         AND name = ''QUEST_SOO_VERSION''
                                         AND current_sby = 0
                                         AND generated_sby = 0'
                  INTO l_is_schema_unguarded;
            EXCEPTION
               WHEN OTHERS
               THEN
                  /* If this SQL fails we will assume it is read only */
                  RETURN 0;
            END;

            IF l_is_schema_unguarded = 0
            THEN
               /* This statement will return 0 if the table is created by data guard, or does not have a DML skip rule, otherwise should return 1 */
               RETURN 0;
            ELSE
               /* Table was created on the logical standby, and has a DML skip rule - so it is safe for Spotlight to write to it */
               RETURN 1;
            END IF;
         END IF;
      END IF;

      /* Check if the users default tablespace is a read only tablespace */
      BEGIN
        execute immediate 'SELECT ts.status
           FROM user_users u, dba_tablespaces ts
          WHERE ts.tablespace_name = u.default_tablespace' INTO l_tablespace_status;

         IF l_tablespace_status = 'READ ONLY'
         THEN
            RETURN 0;
         END IF;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            /* If this query cannot find data - use default value */
            NULL;
      END;

      /* Default behaviour is to assume schema is writable */
      RETURN 1;
   END;
END;
/
