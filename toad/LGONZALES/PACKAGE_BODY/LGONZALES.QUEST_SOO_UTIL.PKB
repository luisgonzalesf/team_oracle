CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_util
AS
   TYPE typ_lock_type_desc IS TABLE OF VARCHAR2 (100)
      INDEX BY BINARY_INTEGER;

   TYPE typ_lock_mode_desc IS TABLE OF VARCHAR2 (20)
      INDEX BY BINARY_INTEGER;

   TYPE typ_lock_type IS TABLE OF VARCHAR2 (2)
      INDEX BY BINARY_INTEGER;

   TYPE typ_lock_idx IS TABLE OF PLS_INTEGER
      INDEX BY BINARY_INTEGER;

   arr_lock_type_desc   typ_lock_type_desc;
   arr_lock_type        typ_lock_type;
   arr_lock_type_idx    typ_lock_idx;
   arr_lock_mode_desc   typ_lock_mode_desc;
   arr_lock_mode        typ_lock_type;
   arr_lock_mode_idx 	typ_lock_idx;
   -- Fill in global text variables
   mv_searching         VARCHAR2 (20)      := '{searching...}';
   mv_cache             VARCHAR2 (10)      := 'cache#';
   mv_rbs               VARCHAR2 (10)      := 'RBS#';
   mv_latch             VARCHAR2 (10)      := 'latch#';
   mv_mode              VARCHAR2 (10)      := 'mode:';
   mv_object            VARCHAR2 (10)      := 'Object';
   mv_datafile          VARCHAR2 (20)      := 'TEMP datafile:';
   mv_file              VARCHAR2 (10)      := 'file';
   mv_scan              VARCHAR2 (30)      := 'Full table scan on %s';
   mv_complete          VARCHAR2 (20)      := '(%s%% complete)';
   mv_unknown           VARCHAR2 (40)  := 'Unknown, temporary or new segment';

   -- Index encoding. Basically takes in uppercase letters and numbers and creates a
   -- number out of it to do faster lookups. Written this way as don't have
   -- character hashmaps in 8i
   FUNCTION encode_index (p_value VARCHAR2)
      RETURN NUMBER
   IS
      lv_char   VARCHAR2 (1);
      lv_pos    VARCHAR2 (5);
      lv_tmp    VARCHAR2 (10);
   BEGIN
      FOR idx IN 1 .. LENGTH (p_value)
      LOOP
         lv_char := SUBSTR (p_value, idx, 1);

         -- Test if a number
         IF ASCII (lv_char) BETWEEN 48 AND 57
         THEN
            lv_pos := '0' || lv_char;
         ELSE                                                     -- Character
            -- For a character, assign it values 11-36
            -- 65 is base for 'A', 'A' is 1 in alphabet, 10 is number of single digit numbers
            lv_pos := TO_CHAR (ASCII (lv_char) - 64 + 10);
         END IF;

         lv_tmp := lv_tmp || lv_pos;
      END LOOP;

      RETURN TO_NUMBER (lv_tmp);
   END encode_index;

   -- Do some transformation and return a lock type description
   FUNCTION get_lock_type_desc (p_lock_type VARCHAR2, p_id2 NUMBER DEFAULT -1)
      RETURN VARCHAR2
   IS
      lv_idx   PLS_INTEGER;
   BEGIN
      IF p_lock_type IS NULL THEN
      	 RETURN NULL;
      END IF;

      IF p_lock_type = 'TS' AND p_id2 = 0
      THEN
         lv_idx := encode_index ('T0');
      ELSIF p_lock_type = 'TS' AND p_id2 = 1
      THEN
         lv_idx := encode_index ('T1');
      ELSE
         lv_idx := encode_index (p_lock_type);
      END IF;

      -- If exists in lookup table, description exists
      -- Return description
      IF arr_lock_type_idx.EXISTS (lv_idx)
      THEN
         RETURN arr_lock_type_desc (arr_lock_type_idx (lv_idx));
      END IF;

      -- Else return lock code
      RETURN p_lock_type;
   END get_lock_type_desc;

   -- Get lock mode description
   -- It's a number so use indexing from 0 to 6
   FUNCTION get_lock_mode_desc (p_idx PLS_INTEGER)
      RETURN VARCHAR2
   IS
   BEGIN
      IF p_idx IS NULL THEN
         RETURN NULL;
      END IF;

      IF arr_lock_mode_desc.EXISTS (p_idx)
      THEN
         RETURN arr_lock_mode_desc (p_idx);
      END IF;

      RETURN TO_CHAR (p_idx);
   END get_lock_mode_desc;

   -- Get lock mode description
   -- If part of Q, X, N etc then will be ok
   FUNCTION get_lock_mode_desc (p_idx VARCHAR2)
      RETURN VARCHAR2
   IS
   BEGIN
      IF p_idx IS NULL THEN
         RETURN NULL;
      END IF;

      IF arr_lock_mode_idx.EXISTS (encode_index(p_idx))
      THEN
         RETURN arr_lock_mode_desc (arr_lock_mode_idx(encode_index(p_idx)));
      END IF;

      RETURN p_idx;
   END get_lock_mode_desc;

   -- Used within event_detail to describe IO events
   FUNCTION io_event (
      p_event   VARCHAR2,
      p_p1      NUMBER,
      p_p2      NUMBER,
      p_type    PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
      lv_tmp   VARCHAR2 (512);
   BEGIN
      BEGIN
         execute immediate 'SELECT NAME
	 		    FROM v$dbfile
	 		    WHERE file# = :p_p1 AND ROWNUM = 1'
	      INTO lv_tmp USING p_p1;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN            -- If file name is not found, it must be a temp file.
            IF p_type = 1
            THEN
               EXECUTE IMMEDIATE    'BEGIN SELECT t.name INTO :1 FROM v$tempfile t, v$parameter p '
                                 || ' WHERE p.name = ''db_files'' AND t.file#=:2-p.value; '
                                 || 'EXCEPTION WHEN NO_DATA_FOUND THEN :1 := NULL; END;'
                           USING OUT lv_tmp, IN p_p1;

               IF lv_tmp IS NULL
               THEN
                  lv_tmp := ' (file#=' || TO_CHAR (p_p1) || ')';
               END IF;
            ELSE
               lv_tmp := TO_CHAR (p_p1);
            END IF;
      END;

      IF p_event != 'DFS db file lock'
      THEN
         lv_tmp := quest_soo_pkg.get_seg_name_41(p_p1, p_p2)
         			|| ', '
         			|| mv_file
         			|| '='
         			|| lv_tmp;
      END IF;

      RETURN lv_tmp;
   END io_event;

   -- Used within event_detail to describe Enqueue events
   FUNCTION enqueue_event (p_p1 NUMBER)
      RETURN VARCHAR2
   IS
      lv_tmp         VARCHAR2 (512);
      lv_lock_type   VARCHAR2 (5);
      lv_lock_mode   PLS_INTEGER;
   BEGIN
      lv_lock_type :=
            CHR (BITAND (p_p1, -16777216) / 16777215)
         || CHR (BITAND (p_p1, 16711680) / 65535);
      lv_lock_mode := BITAND (p_p1, 65535);
      lv_tmp :=
            get_lock_type_desc (lv_lock_type)
         || ', '
         || mv_mode
         || get_lock_mode_desc (lv_lock_mode);
      RETURN lv_tmp;
   END enqueue_event;

   -- Used within event_detail to describe latch events
   FUNCTION latch_event (p_p2 NUMBER)
      RETURN VARCHAR2
   IS
      lv_tmp   VARCHAR2 (512);
   BEGIN
      BEGIN
         execute immediate 'SELECT NAME
	 		    FROM v$latchname
			    WHERE latch# = :p_p2 AND ROWNUM = 1'
	   INTO lv_tmp USING p_p2;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            lv_tmp := TO_CHAR (p_p2);
      END;

      lv_tmp := mv_latch || '=' || lv_tmp;
      RETURN lv_tmp;
   END latch_event;

   -- Used within event_detail to describe data block address (dba) events
   FUNCTION dba_event (p_px NUMBER)
      RETURN VARCHAR2
   IS
      lv_tmp   VARCHAR2 (512);
   BEGIN
      lv_tmp :=
            mv_unknown
         || ' '
         || 'Extent at file '
         || DBMS_UTILITY.data_block_address_file (p_px)
         || ', block '
         || DBMS_UTILITY.data_block_address_block (p_px);
      RETURN lv_tmp;
   END dba_event;

   -- Used within event_detail to describe undo events
   FUNCTION undo_event (p_p1 NUMBER)
      RETURN VARCHAR2
   IS
      lv_tmp   VARCHAR2 (512);
   BEGIN
      BEGIN
         execute immediate 'SELECT NAME
	 		    FROM v$rollname
			    WHERE usn = :p_p1 AND ROWNUM = 1'
	        INTO lv_tmp USING p_p1;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            lv_tmp := TO_CHAR (p_p1);
      END;

      lv_tmp := mv_rbs || '=' || lv_tmp;
      RETURN lv_tmp;
   END undo_event;

   -- Used within event_detail to describe row cache events
   FUNCTION row_event (p_p1 NUMBER)
      RETURN VARCHAR2
   IS
      lv_tmp   VARCHAR2 (512);
   BEGIN
      BEGIN
         execute immediate 'SELECT parameter
	                    FROM v$rowcache
			    WHERE cache# = :p_p1 AND ROWNUM = 1'
	        INTO lv_tmp USING p_p1;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            lv_tmp := TO_CHAR (p_p1);
      END;

      lv_tmp := mv_cache || '=' || lv_tmp;
      RETURN lv_tmp;
   END row_event;

   -- Get details about events on system.
   -- Replacement for quest_soo_pkb.event_detail_41 and wait_detail_41
   FUNCTION event_detail (
      p_event    VARCHAR2,
      p_p1text   VARCHAR2,
      p_p1       NUMBER,
      p_p2text   VARCHAR2,
      p_p2       NUMBER,
      p_p3text   VARCHAR2,
      p_p3       NUMBER,
      p_type     PLS_INTEGER DEFAULT 1                -- 1 is Event, 2 is Wait
   )
      RETURN VARCHAR2
   IS
      lv_return   VARCHAR2 (2048);
      lv_tmp      VARCHAR2 (512);
   BEGIN
      -- IO events.  p1=file#, p2=block# (except DFS db file lock)
      -- Add direct path io as well
      IF (   (p_p1text = 'file#' AND p_p2text = 'block#')
          OR (p_p1text = 'file number' AND p_p2text = 'first dba')
          OR p_event = 'DFS db file lock'
         )
      THEN
         lv_tmp := io_event (p_event, p_p1, p_p2, p_type);
      ELSIF (p_event = 'enqueue' OR p_event LIKE 'enq:%')
      THEN
         lv_tmp := enqueue_event (p_p1);
      ELSIF (p_event = 'latch activity' OR p_event = 'latch free')
      THEN
         lv_tmp := latch_event (p_p2);
      ELSIF (p_p1text = 'dba' OR p_p2text = 'dba')
      THEN
         IF (p_p1text = 'dba')
         THEN
            lv_tmp := dba_event (p_p1);
         ELSE
            lv_tmp := dba_event (p_p2);
         END IF;
      ELSIF (p_event = 'undo segment recovery')
      THEN
         lv_tmp := undo_event (p_p1);
      ELSIF (p_event = 'row cache lock')
      THEN
         lv_tmp := row_event (p_p1);
      END IF;

      IF LENGTH (TRIM (lv_tmp)) > 1
      THEN
         IF LENGTH (TRIM (p_p3text)) > 1
         THEN
            RETURN p_event || ', ' || lv_tmp || ', ' || p_p3text || '='
                   || p_p3;
         ELSE
            RETURN p_event || ', ' || lv_tmp;
         END IF;
      ELSE
         lv_tmp := p_event;

         IF LENGTH (TRIM (p_p1text)) > 1
         THEN
            lv_tmp := lv_tmp || ', ' || p_p1text || '=' || p_p1;

            IF LENGTH (TRIM (p_p2text)) > 1
            THEN
               lv_tmp := lv_tmp || ', ' || p_p2text || '=' || p_p2;

               IF LENGTH (TRIM (p_p3text)) > 1
               THEN
                  lv_tmp := lv_tmp || ', ' || p_p3text || '=' || p_p3;
               END IF;
            END IF;
         END IF;
      END IF;

      RETURN lv_tmp;
   END event_detail;

   -- Load lock codes and descriptions, create lookup table for faster lookups too
   PROCEDURE load_locks
   IS
   BEGIN
      arr_lock_type_desc (0) := 'Buffer hash table instance lock';
      arr_lock_type_desc (1) := 'Control file schema global enqueue lock';
      arr_lock_type_desc (2) :=
                           'Cross-instance function invocation instance lock';
      arr_lock_type_desc (3) := 'Control file schema global enqueue lock';
      arr_lock_type_desc (4) := 'Cursor bind lock';
      arr_lock_type_desc (5) := 'Data file instance lock';
      arr_lock_type_desc (6) := 'Direct loader parallel index create';
      arr_lock_type_desc (7) :=
                           'Mount/startup db primary/secondary instance lock';
      arr_lock_type_desc (8) := 'Distributed recovery process lock';
      arr_lock_type_desc (9) := 'Distributed transaction entry lock';
      arr_lock_type_desc (10) := 'SGA open-file information lock';
      arr_lock_type_desc (11) := 'File set lock';
      arr_lock_type_desc (12) :=
                     'Space management operations on a specific segment lock';
      arr_lock_type_desc (13) := 'Instance number lock';
      arr_lock_type_desc (14) :=
                        'Instance recovery serialization global enqueue lock';
      arr_lock_type_desc (15) := 'Instance state lock';
      arr_lock_type_desc (16) := 'Library cache invalidation instance lock';
      arr_lock_type_desc (17) := 'Job queue lock';
      arr_lock_type_desc (18) := 'Thread kick lock';
      arr_lock_type_desc (19) := 'Master buffer hash table instance lock';
      arr_lock_type_desc (20) := 'Mount definition gloabal enqueue lock';
      arr_lock_type_desc (21) := 'Media recovery lock';
      arr_lock_type_desc (22) := 'Password file lock';
      arr_lock_type_desc (23) := 'Parallel operation lock';
      arr_lock_type_desc (24) := 'Process startup lock';
      arr_lock_type_desc (25) := 'Parallel operation lock';
      arr_lock_type_desc (26) := 'USE_ROW_ENQUEUE enforcement lock';
      arr_lock_type_desc (27) := 'Redo thread global enqueue lock';
      arr_lock_type_desc (28) := 'Row wait enqueue lock';
      arr_lock_type_desc (29) := 'System commit number instance lock';
      arr_lock_type_desc (30) :=
                          'System commit number high water mark enqueue lock';
      arr_lock_type_desc (31) := 'SMON lock';
      arr_lock_type_desc (32) := 'Sequence number instance lock';
      arr_lock_type_desc (33) := 'Sequence number enqueue lock';
      arr_lock_type_desc (34) := 'Sort segment lock';
      arr_lock_type_desc (35) := 'Space transaction enqueue lock';
      arr_lock_type_desc (36) := 'Sequence number value lock';
      arr_lock_type_desc (37) := 'Generic enqueue lock';
      arr_lock_type_desc (38) := 'DDL enqueue lock';
      arr_lock_type_desc (39) := 'Extend-segment enqueue lock';
      arr_lock_type_desc (40) := 'DML enqueue lock';
      arr_lock_type_desc (41) := 'Temporary object operations lock';
      arr_lock_type_desc (42) := 'Temporary table enqueue lock';
      arr_lock_type_desc (43) := 'Transaction enqueue lock';
      arr_lock_type_desc (44) := 'User supplied lock';
      arr_lock_type_desc (45) := 'User name lock';
      arr_lock_type_desc (46) := 'Undo segment DDL lock';
      arr_lock_type_desc (47) := 'Being-written redo log instance lock';
      arr_lock_type_desc (48) :=
                                'Write-atomic-log-switch global enqueue lock';
      arr_lock_type_desc (49) :=
                     'Temporary segment or new block allocation enqueue lock';
      arr_lock_type_desc (50) := 'Log start/log switch enqueue lock';
      arr_lock_type_desc (51) := 'Default Temporary Tablespace Enqueue';
      arr_lock_type_desc (52) := 'Diana Version Enqueue';
      arr_lock_type_desc (53) := 'Internet Application Server Enqueue';
      arr_lock_type_desc (54) := 'Scheduler Modification and Loading Enqueue';
      arr_lock_type_desc (55) := 'Scheduler Top Plan Enqueue';
      arr_lock_type_desc (56) := 'Synchronized Replication Enqueue';
      arr_lock_type_desc (57) := 'Change Data Capture Materialized View Log';
      arr_lock_type_desc (58) := 'DBMS Jobs enqueue/lock';
      arr_lock_type_desc (59) :=
                        'Formatting a range of Bitmap Blocks (BMBs) for ASSM';
      arr_lock_type_desc (50) :=
                               'Suspend Writes (ALTER SYSTEM SUSPEND|RESUME)';
      arr_lock_type_desc (61) :=
         'ALTER SYSTEM QUIESCE RESTRICTED enqueue or ALTER DATABASE OPEN in RAC mode enqueue';
      arr_lock_type_desc (62) := 'Advisor task lock';
      arr_lock_type_desc (63) := 'Workspace lock';
      arr_lock_type_desc (64) := 'New service activation';
      arr_lock_type_desc (65) := 'Workspace AW$ table access lock';
      arr_lock_type_desc (66) := 'Change tracking lock';
      arr_lock_type_desc (67) := 'LDAP parameters access lock';
      arr_lock_type_desc (68) :=
                          'Capture of the DB Feature Usage and HWM Stat lock';
      arr_lock_type_desc (69) :=
                               'Temp table meta-data pinning/recreation lock';
      arr_lock_type_desc (70) := 'Job cache lock';
      arr_lock_type_desc (71) := 'LogMiner dictionary and synchronize lock';
      arr_lock_type_desc (72) :=
         'Calibration of the manageability schedules with the Maintenance Window';
      arr_lock_type_desc (73) :=
                              'Coordinates flushing of multiple objects lock';
      arr_lock_type_desc (74) := 'Space reclaimable operations lock';
      arr_lock_type_desc (75) :=
                           'Writes to the SQL Optimizer Existence Cache lock';
      arr_lock_type_desc (76) := 'Tablespace checkpoint lock';
      arr_lock_type_desc (77) := 'Threshold log table lock';
      arr_lock_type_desc (78) := 'Queue table lock';
      arr_lock_type_desc (79) := 'Flushing of snapshots lock';
      arr_lock_type_desc (80) := 'Purging and baselines lock';
      arr_lock_type_desc (81) :=
                             'Library cache lock instance lock (A=namespace)';
      arr_lock_type_desc (82) :=
                             'Library cache lock instance lock (B=namespace)';
      arr_lock_type_desc (83) :=
                             'Library cache lock instance lock (C=namespace)';
      arr_lock_type_desc (84) :=
                             'Library cache lock instance lock (D=namespace)';
      arr_lock_type_desc (85) :=
                             'Library cache lock instance lock (E=namespace)';
      arr_lock_type_desc (86) :=
                             'Library cache lock instance lock (F=namespace)';
      arr_lock_type_desc (87) :=
                             'Library cache lock instance lock (G=namespace)';
      arr_lock_type_desc (88) :=
                             'Library cache lock instance lock (H=namespace)';
      arr_lock_type_desc (89) :=
                             'Library cache lock instance lock (I=namespace)';
      arr_lock_type_desc (90) :=
                             'Library cache lock instance lock (J=namespace)';
      arr_lock_type_desc (91) :=
                             'Library cache lock instance lock (K=namespace)';
      arr_lock_type_desc (92) :=
                             'Library cache lock instance lock (L=namespace)';
      arr_lock_type_desc (93) :=
                             'Library cache lock instance lock (M=namespace)';
      arr_lock_type_desc (94) :=
                             'Library cache lock instance lock (N=namespace)';
      arr_lock_type_desc (95) :=
                             'Library cache lock instance lock (O=namespace)';
      arr_lock_type_desc (96) :=
                             'Library cache lock instance lock (P=namespace)';
      arr_lock_type_desc (97) :=
                              'Library cache pin instance lock (A=namespace)';
      arr_lock_type_desc (98) :=
                              'Library cache pin instance lock (B=namespace)';
      arr_lock_type_desc (99) :=
                              'Library cache pin instance lock (C=namespace)';
      arr_lock_type_desc (100) :=
                              'Library cache pin instance lock (D=namespace)';
      arr_lock_type_desc (101) :=
                              'Library cache pin instance lock (E=namespace)';
      arr_lock_type_desc (102) :=
                              'Library cache pin instance lock (F=namespace)';
      arr_lock_type_desc (103) :=
                              'Library cache pin instance lock (G=namespace)';
      arr_lock_type_desc (104) :=
                              'Library cache pin instance lock (H=namespace)';
      arr_lock_type_desc (105) :=
                              'Library cache pin instance lock (I=namespace)';
      arr_lock_type_desc (106) :=
                              'Library cache pin instance lock (J=namespace)';
      arr_lock_type_desc (107) :=
                              'Library cache pin instance lock (K=namespace)';
      arr_lock_type_desc (108) :=
                              'Library cache pin instance lock (L=namespace)';
      arr_lock_type_desc (109) :=
                              'Library cache pin instance lock (M=namespace)';
      arr_lock_type_desc (110) :=
                              'Library cache pin instance lock (N=namespace)';
      arr_lock_type_desc (111) :=
                              'Library cache pin instance lock (O=namespace)';
      arr_lock_type_desc (112) :=
                              'Library cache pin instance lock (P=namespace)';
      arr_lock_type_desc (113) :=
                              'Library cache pin instance lock (Q=namespace)';
      arr_lock_type_desc (114) :=
                              'Library cache pin instance lock (R=namespace)';
      arr_lock_type_desc (115) :=
                              'Library cache pin instance lock (S=namespace)';
      arr_lock_type_desc (116) :=
                              'Library cache pin instance lock (T=namespace)';
      arr_lock_type_desc (117) :=
                              'Library cache pin instance lock (U=namespace)';
      arr_lock_type_desc (118) :=
                              'Library cache pin instance lock (V=namespace)';
      arr_lock_type_desc (119) :=
                              'Library cache pin instance lock (W=namespace)';
      arr_lock_type_desc (120) :=
                              'Library cache pin instance lock (X=namespace)';
      arr_lock_type_desc (121) :=
                              'Library cache pin instance lock (Y=namespace)';
      arr_lock_type_desc (122) :=
                              'Library cache pin instance lock (Z=namespace)';
      arr_lock_type_desc (123) := 'Row cache instance lock (A=cache)';
      arr_lock_type_desc (124) := 'Row cache instance lock (B=cache)';
      arr_lock_type_desc (125) := 'Row cache instance lock (C=cache)';
      arr_lock_type_desc (126) := 'Row cache instance lock (D=cache)';
      arr_lock_type_desc (127) := 'Row cache instance lock (E=cache)';
      arr_lock_type_desc (128) := 'Row cache instance lock (F=cache)';
      arr_lock_type_desc (129) := 'Row cache instance lock (G=cache)';
      arr_lock_type_desc (130) := 'Row cache instance lock (H=cache)';
      arr_lock_type_desc (131) := 'Row cache instance lock (I=cache)';
      arr_lock_type_desc (132) := 'Row cache instance lock (J=cache)';
      arr_lock_type_desc (133) := 'Row cache instance lock (K=cache)';
      arr_lock_type_desc (134) := 'Row cache instance lock (L=cache)';
      arr_lock_type_desc (135) := 'Row cache instance lock (M=cache)';
      arr_lock_type_desc (136) := 'Row cache instance lock (N=cache)';
      arr_lock_type_desc (137) := 'Row cache instance lock (O=cache)';
      arr_lock_type_desc (138) := 'Row cache instance lock (P=cache)';
      arr_lock_type_desc (139) := 'Row cache instance lock (Q=cache)';
      arr_lock_type_desc (140) := 'Row cache instance lock (R=cache)';
      arr_lock_type_desc (141) := 'Row cache instance lock (S=cache)';
      arr_lock_type_desc (142) := 'Row cache instance lock (T=cache)';
      arr_lock_type_desc (143) := 'Row cache instance lock (U=cache)';
      arr_lock_type_desc (144) := 'Row cache instance lock (V=cache)';
      arr_lock_type_desc (145) := 'Row cache instance lock (W=cache)';
      arr_lock_type_desc (146) := 'Row cache instance lock (X=cache)';
      arr_lock_type_desc (147) := 'Row cache instance lock (Y=cache)';
      arr_lock_type_desc (148) := 'Row cache instance lock (Z=cache)';
      arr_lock_type_desc (149) := 'Temporary segment enqueue lock (id2=0)';
      arr_lock_type_desc (150) := 'New block allocation enqueue lock (id2=1)';
      -- Codes
      arr_lock_type (0) := 'BL';
      arr_lock_type (1) := 'CF';
      arr_lock_type (2) := 'CI';
      arr_lock_type (3) := 'CS';
      arr_lock_type (4) := 'CU';
      arr_lock_type (5) := 'DF';
      arr_lock_type (6) := 'DL';
      arr_lock_type (7) := 'DM';
      arr_lock_type (8) := 'DR';
      arr_lock_type (9) := 'DX';
      arr_lock_type (10) := 'FI';
      arr_lock_type (11) := 'FS';
      arr_lock_type (12) := 'HW';
      arr_lock_type (13) := 'IN';
      arr_lock_type (14) := 'IR';
      arr_lock_type (15) := 'IS';
      arr_lock_type (16) := 'IV';
      arr_lock_type (17) := 'JQ';
      arr_lock_type (18) := 'KK';
      arr_lock_type (19) := 'MB';
      arr_lock_type (20) := 'MM';
      arr_lock_type (21) := 'MR';
      arr_lock_type (22) := 'PF';
      arr_lock_type (23) := 'PI';
      arr_lock_type (24) := 'PR';
      arr_lock_type (25) := 'PS';
      arr_lock_type (26) := 'RE';
      arr_lock_type (27) := 'RT';
      arr_lock_type (28) := 'RW';
      arr_lock_type (29) := 'SC';
      arr_lock_type (30) := 'SH';
      arr_lock_type (31) := 'SM';
      arr_lock_type (32) := 'SN';
      arr_lock_type (33) := 'SQ';
      arr_lock_type (34) := 'SS';
      arr_lock_type (35) := 'ST';
      arr_lock_type (36) := 'SV';
      arr_lock_type (37) := 'TA';
      arr_lock_type (38) := 'TD';
      arr_lock_type (39) := 'TE';
      arr_lock_type (40) := 'TM';
      arr_lock_type (41) := 'TO';
      arr_lock_type (42) := 'TT';
      arr_lock_type (43) := 'TX';
      arr_lock_type (44) := 'UL';
      arr_lock_type (45) := 'UN';
      arr_lock_type (46) := 'US';
      arr_lock_type (47) := 'WL';
      arr_lock_type (48) := 'WS';
      arr_lock_type (49) := 'TS';
      arr_lock_type (50) := 'LS';
      arr_lock_type (51) := 'DT';
      arr_lock_type (52) := 'DV';
      arr_lock_type (53) := 'IA';
      arr_lock_type (54) := 'KM';
      arr_lock_type (55) := 'KT';
      arr_lock_type (56) := 'SR';
      arr_lock_type (57) := 'MD';
      arr_lock_type (58) := 'JD';
      arr_lock_type (59) := 'FB';
      arr_lock_type (60) := 'SW';
      arr_lock_type (61) := 'XR';
      arr_lock_type (62) := 'AF';
      arr_lock_type (63) := 'AG';
      arr_lock_type (64) := 'AS';
      arr_lock_type (65) := 'AW';
      arr_lock_type (66) := 'CT';
      arr_lock_type (67) := 'DP';
      arr_lock_type (68) := 'FU';
      arr_lock_type (69) := 'IT';
      arr_lock_type (70) := 'JS';
      arr_lock_type (71) := 'MN';
      arr_lock_type (72) := 'MW';
      arr_lock_type (73) := 'RO';
      arr_lock_type (74) := 'RS';
      arr_lock_type (75) := 'TB';
      arr_lock_type (76) := 'TC';
      arr_lock_type (77) := 'TL';
      arr_lock_type (78) := 'TQ';
      arr_lock_type (79) := 'WF';
      arr_lock_type (80) := 'WP';
      arr_lock_type (81) := 'LA';
      arr_lock_type (82) := 'LB';
      arr_lock_type (83) := 'LC';
      arr_lock_type (84) := 'LD';
      arr_lock_type (85) := 'LE';
      arr_lock_type (86) := 'LF';
      arr_lock_type (87) := 'LG';
      arr_lock_type (88) := 'LH';
      arr_lock_type (89) := 'LI';
      arr_lock_type (90) := 'LJ';
      arr_lock_type (91) := 'LK';
      arr_lock_type (92) := 'LL';
      arr_lock_type (93) := 'LM';
      arr_lock_type (94) := 'LN';
      arr_lock_type (95) := 'LO';
      arr_lock_type (96) := 'LP';
      arr_lock_type (97) := 'NA';
      arr_lock_type (98) := 'NB';
      arr_lock_type (99) := 'NC';
      arr_lock_type (100) := 'ND';
      arr_lock_type (101) := 'NE';
      arr_lock_type (102) := 'NF';
      arr_lock_type (103) := 'NG';
      arr_lock_type (104) := 'NH';
      arr_lock_type (105) := 'NI';
      arr_lock_type (106) := 'NJ';
      arr_lock_type (107) := 'NL';
      arr_lock_type (108) := 'NK';
      arr_lock_type (109) := 'NM';
      arr_lock_type (110) := 'NN';
      arr_lock_type (111) := 'NO';
      arr_lock_type (112) := 'NP';
      arr_lock_type (113) := 'NQ';
      arr_lock_type (114) := 'NR';
      arr_lock_type (115) := 'NS';
      arr_lock_type (116) := 'NT';
      arr_lock_type (117) := 'NU';
      arr_lock_type (118) := 'NV';
      arr_lock_type (119) := 'NW';
      arr_lock_type (120) := 'NX';
      arr_lock_type (121) := 'NY';
      arr_lock_type (122) := 'NZ';
      arr_lock_type (123) := 'QA';
      arr_lock_type (124) := 'QB';
      arr_lock_type (125) := 'QC';
      arr_lock_type (126) := 'QD';
      arr_lock_type (127) := 'QE';
      arr_lock_type (128) := 'QF';
      arr_lock_type (129) := 'QG';
      arr_lock_type (130) := 'QH';
      arr_lock_type (131) := 'QI';
      arr_lock_type (132) := 'QJ';
      arr_lock_type (133) := 'QL';
      arr_lock_type (134) := 'QK';
      arr_lock_type (135) := 'QM';
      arr_lock_type (136) := 'QN';
      arr_lock_type (137) := 'QO';
      arr_lock_type (138) := 'QP';
      arr_lock_type (139) := 'QQ';
      arr_lock_type (140) := 'QR';
      arr_lock_type (141) := 'QS';
      arr_lock_type (142) := 'QT';
      arr_lock_type (143) := 'QU';
      arr_lock_type (144) := 'QV';
      arr_lock_type (145) := 'QW';
      arr_lock_type (146) := 'QX';
      arr_lock_type (147) := 'QY';
      arr_lock_type (148) := 'QZ';
      arr_lock_type (149) := 'T0';
      arr_lock_type (150) := 'T1';

      -- Lookup table
      FOR idx IN arr_lock_type.FIRST .. arr_lock_type.LAST
      LOOP
         arr_lock_type_idx (encode_index (arr_lock_type (idx))) := idx;
      END LOOP;
   END load_locks;

   -- Create lock mode arrays and lookups
   PROCEDURE load_lock_mode
   IS
   BEGIN
      -- Descriptions
      arr_lock_mode_desc (0) := 'None';
      arr_lock_mode_desc (1) := 'Null';
      arr_lock_mode_desc (2) := 'Row-S (SS)';
      arr_lock_mode_desc (3) := 'Row-X (SX)';
      arr_lock_mode_desc (4) := 'Share';
      arr_lock_mode_desc (5) := 'S/Row-X (SSX)';
      arr_lock_mode_desc (6) := 'Exclusive';
      -- Codes
      arr_lock_mode (0) := 'Q';
      arr_lock_mode (1) := 'N';
      arr_lock_mode (2) := 'L';
      arr_lock_mode (3) := 'R';
      arr_lock_mode (4) := 'S';
      arr_lock_mode (5) := 'C';
      arr_lock_mode (6) := 'X';

      FOR idx IN arr_lock_mode.FIRST..arr_lock_mode.LAST
      LOOP
      	 arr_lock_mode_idx(encode_index(arr_lock_mode(idx))) := idx;
      END LOOP;
   END load_lock_mode;
BEGIN
   -- On package initialisation, load lock descriptions and lock modes
   load_locks;
   load_lock_mode;
END quest_soo_util;
/
