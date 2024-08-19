CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_archivelog
AS
   TYPE typ_inst_reverse_arr IS TABLE OF PLS_INTEGER
      INDEX BY LONG;

   arr_inst_reverse_idx   typ_inst_reverse_arr;
   arr_drive_rec          typ_drive_rec_arr;
   arr_local_arc_rec      typ_arc_rec_arr;
   ar2_arc_summary_rec    typ_arc_rec_ar2;
   ar2_dest_rec           typ_dest_rec_ar2;
   arr_drive_idx          typ_dest_idx;
   arr_instance_rec       quest_soo_variable.typ_db_rec_arr;
   arr_min_succeed        typ_drive_idx;
   gv_initialised         BOOLEAN                           DEFAULT FALSE;
   gv_recovery_dest       VARCHAR2 (100);
   gv_min_archive         NUMBER (2);
   gv_init                NUMBER (2)                        := 0;
   gv_param_init          BOOLEAN                           := FALSE;
   gv_redundancy          PLS_INTEGER;
   gv_thread_number       PLS_INTEGER;
   gv_last_sequence       PLS_INTEGER;
   gv_flashback_keep_time NUMBER;
   gv_db_version          NUMBER(4,2);
   gv_db_patch_level      NUMBER;
   gv_instance_name       VARCHAR2(50);
   gv_archivelog          BOOLEAN;
   gv_restart_count       PLS_INTEGER := 0;
   gv_rac_call            PLS_INTEGER := 0;
   gv_history_period      PLS_INTEGER;

   -- Constants
   gc_not_enough_hist    CONSTANT  VARCHAR2(50) := 'Not enough log history for accurate estimation';
   gc_package_name       CONSTANT  VARCHAR2(50) := 'QUEST_SOO_ARCHIVELOG';

   gv_9i_query            VARCHAR2(600) :=
      'SELECT 0, 0, 0, dest_name, dest.status, target, destination, ' ||
             'destination destination_end, BINDING, log_sequence, reopen_secs, ' ||
             'transmit_mode, dest.TYPE, NULL valid_type, ' ||
             '0 total_mb, ' ||
             '0 free_mb, ' ||
             '0 usable_file_mb, ' ||
             '0 space_reclaimable, ' ||
             '''FALSE'' is_asm, ' ||
             '''FALSE'' is_recovery, null min_record, NULL time_to_failure, ' ||
             ' instance_name, null, null, decode(fail_date, null, null, ''Failed at: '' || to_char(fail_date, ''DD-Mon-YYYY HH24:MI:SS'')), null, ' ||
             ' inst.archiver archiver_status ' ||
         'FROM v$archive_dest dest, v$instance inst ' ||
         '      WHERE destination IS NOT NULL';

    gv_10g_query        VARCHAR2(2000) :=
                ' WITH dest AS ( ' ||
                      'SELECT dest_id, dest_name, dest.status, BINDING, name_space, target, ' ||
                      '       dest.archiver, schedule, destination, ' ||
                      '       DECODE (UPPER(destination), ''USE_DB_RECOVERY_FILE_DEST'', :gv_recovery_dest, destination ) destination_end, ' ||
                      '       log_sequence, reopen_secs, delay_mins, 0 max_connections, net_timeout, process, REGISTER, ' ||
                      '       quota_size, quota_used, mountid, transmit_mode, TYPE, valid_now, valid_type, valid_role, db_unique_name, ' ||
                      '       verify, DECODE (UPPER(destination),''USE_DB_RECOVERY_FILE_DEST'', ''TRUE'', ''FALSE'') is_recovery, error, inst.archiver archiver_status ' ||
                      '  FROM v$archive_dest dest, v$instance inst ' ||
                      ' WHERE destination IS NOT NULL) ' ||
              'SELECT 0, 0, 0, dest_name, status, target, destination, ' ||
              '       destination_end, BINDING, log_sequence, reopen_secs, ' ||
              '       transmit_mode, dest.TYPE, valid_type, ' ||
              '       nvl(ROUND (DECODE (is_recovery,''TRUE'', recov.space_limit / 1024 / 1024,total_mb )), 0) total_mb, ' ||
              '       NVL (ROUND (DECODE (is_recovery,''TRUE'', (recov.space_limit - space_used) / 1024/ 1024,free_mb)),0) free_mb, ' ||
              '       NVL (ROUND (DECODE (is_recovery,''TRUE'', (recov.space_limit - space_used) / 1024/ 1024,free_mb/  ' ||
              '         DECODE (redundancy, ''HIGH'', 3, ''MIRROR'', 2, NULL, 2, 1))),0) usable_file_mb, ' ||
              '       NVL(space_reclaimable, 0) / 1024/1024 space_reclaimable,DECODE (SUBSTR (dest.destination_end, 1, 1),''+'', ''TRUE'',''FALSE'') is_asm, ' ||
              '       is_recovery, null min_record, NULL time_to_failure,SYS_CONTEXT (''USERENV'', ''INSTANCE_NAME'') instance_name, null, null, error, null, ' ||
              '       archiver_status ' ||
              '  FROM dest, v$asm_diskgroup dg, v$recovery_file_dest recov, v$asm_template tmp ' ||
              ' WHERE dg.NAME(+) = SUBSTR (destination_end, 2) ' ||
              '   AND recov.NAME(+) = dest.destination_end ' ||
              '   AND tmp.group_number(+) = dg.group_number ' ||
              '   AND tmp.NAME(+) = ''ARCHIVELOG''';

    gv_10gr2_query      VARCHAR2(2000) :=
                ' WITH dest AS ( ' ||
                      'SELECT dest_id, dest_name, dest.status, BINDING, name_space, target, ' ||
                      '       dest.archiver, schedule, destination, ' ||
                      '       DECODE (UPPER(destination), ''USE_DB_RECOVERY_FILE_DEST'', :gv_recovery_dest, destination ) destination_end, ' ||
                      '       log_sequence, reopen_secs, delay_mins, 0 max_connections, net_timeout, process, REGISTER, ' ||
                      '       quota_size, quota_used, mountid, transmit_mode, TYPE, valid_now, valid_type, valid_role, db_unique_name, ' ||
                      '       verify, DECODE (UPPER(destination),''USE_DB_RECOVERY_FILE_DEST'', ''TRUE'', ''FALSE'') is_recovery, error, inst.archiver archiver_status ' ||
                      '  FROM v$archive_dest dest, v$instance inst ' ||
                      ' WHERE destination IS NOT NULL) ' ||
              'SELECT 0, 0, 0, dest_name, status, target, destination, ' ||
              '       destination_end, BINDING, log_sequence, reopen_secs, ' ||
              '       transmit_mode, dest.TYPE, valid_type, ' ||
              '       nvl(ROUND (DECODE (is_recovery,''TRUE'', recov.space_limit / 1024 / 1024,null )), 0) total_mb, ' ||
              '       NVL (ROUND (DECODE (is_recovery,''TRUE'', (recov.space_limit - space_used) / 1024/ 1024,null)),0) free_mb, ' ||
              '       NVL (ROUND (DECODE (is_recovery,''TRUE'', (recov.space_limit - space_used) / 1024/ 1024,null)),0) usable_file_mb, ' ||
              '       NVL(space_reclaimable, 0) / 1024/1024 space_reclaimable,DECODE (SUBSTR (dest.destination_end, 1, 1),''+'', ''TRUE'',''FALSE'') is_asm, ' ||
              '       is_recovery, null min_record, NULL time_to_failure,SYS_CONTEXT (''USERENV'', ''INSTANCE_NAME'') instance_name, null, null, error, null, ' ||
              '       archiver_status ' ||
              '  FROM dest, v$recovery_file_dest recov ' ||
              ' WHERE recov.NAME(+) = dest.destination_end ';


   TYPE rc is REF CURSOR;
   str_gc_archive varchar2(1024) :=  '  SELECT   sequence#, next_time, file_size
                                        FROM (SELECT DISTINCT sequence#, next_time,
                                                     ROUND (blocks * block_size / 1024 / 1024
                                                     ) file_size,
                                                     RANK () OVER (ORDER BY sequence# DESC)
                                                        order_ranking
                                              FROM v$archived_log
                                              WHERE (thread# = :gv_thread_number OR :gv_thread_number = 0)
                                              AND ROUND (blocks * block_size / 1024 / 1024) > 0
                                              AND sequence# > :gv_last_sequence
                                              AND next_time > (SYSDATE - :gv_history_period))
                                        ORDER BY next_time';


   PROCEDURE get_db_version;

   FUNCTION get_min_succeed(p_instance   NUMBER DEFAULT NULL)
      RETURN PLS_INTEGER
   IS
      lv_num   PLS_INTEGER;
   BEGIN
      IF p_instance IS NULL THEN
		execute immediate 'SELECT TO_NUMBER (VALUE)
			               FROM v$parameter
		                   WHERE NAME = ''log_archive_min_succeed_dest'''
                           INTO lv_num;
	  ELSE
	  	execute immediate 'SELECT TO_NUMBER (VALUE)
		                   FROM gv$parameter
	                       WHERE NAME = ''log_archive_min_succeed_dest''
	                       AND inst_id = :p_instance'
                           INTO lv_num USING IN p_instance;
	  END IF;
      RETURN lv_num;
   END get_min_succeed;

   PROCEDURE setup_min_succeed
   IS
   BEGIN
      arr_min_succeed.DELETE;

      FOR idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         IF arr_instance_rec (idx).db_link IS NULL
         THEN
            arr_min_succeed (idx) := get_min_succeed;
         ELSE
            BEGIN
            EXECUTE IMMEDIATE    'SELECT quest_soo_archivelog.get_min_succeed@'
                              || arr_instance_rec (idx).db_link
                              || ' from dual'
                         INTO arr_min_succeed (idx);
            EXCEPTION
            	WHEN OTHERS THEN
            		arr_min_succeed(idx) := get_min_succeed(arr_instance_rec(idx).instance_number);
            END;
         END IF;
      END LOOP;
   END setup_min_succeed;

   PROCEDURE get_flashback_keep_time IS
   BEGIN

        execute immediate 'SELECT TO_NUMBER(VALUE)
                           FROM v$parameter
                           WHERE NAME = ''db_flashback_retention_target'''
                           INTO gv_flashback_keep_time;

        -- Convert flashback keep time to days
        IF gv_flashback_keep_time IS NOT NULL THEN
            gv_flashback_keep_time := gv_flashback_keep_time / (60*24);
        END IF;
   EXCEPTION
        WHEN OTHERS THEN
            NULL;
   END get_flashback_keep_time;

   FUNCTION get_flash_recov RETURN NUMBER IS
    lv_size     NUMBER(16,2) := 0;
   BEGIN
        IF gv_flashback_keep_time IS NOT NULL AND
            gv_flashback_keep_time > 0 AND
            gv_db_version = 10.2 AND
            gv_db_patch_level < 0.3 THEN

            execute IMMEDIATE 'SELECT round(sum(bytes)/1024/1024, 2) size_mb FROM (select bytes, lead(first_time) over(order by first_time asc) last_time, first_time from v$flashback_database_logfile) ' ||
                              'WHERE  last_time <= (SYSDATE - :gv_flashback_keep_time)' INTO lv_size USING IN gv_flashback_keep_time;

        END IF;

        RETURN lv_size;

   END get_flash_recov;

   PROCEDURE param_init
   IS
    lv_log_mode     VARCHAR2(50);
   BEGIN
    execute immediate 'SELECT log_mode
                       FROM v$database'
                       INTO lv_log_mode;

    IF lv_log_mode = 'ARCHIVELOG' THEN
        gv_archivelog := TRUE;
    ELSE
        gv_archivelog := FALSE;
    END IF;

    get_db_version;

    IF gv_db_version >= 10 THEN
          BEGIN

          execute immediate 'SELECT VALUE
                             FROM v$parameter
                             WHERE NAME = ''db_recovery_file_dest'''
                             INTO gv_recovery_dest;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
                NULL;
          END;
     END IF;

     BEGIN
      execute immediate 'SELECT VALUE
                         FROM v$parameter
                         WHERE NAME = ''thread'''
                        INTO gv_thread_number;
     EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
     END;

     setup_min_succeed;

     get_flashback_keep_time;

     -- Get keep period
     IF gv_history_period IS NULL THEN
		 BEGIN
			 gv_history_period := TO_NUMBER(quest_soo_variable.get_parameter('ARCHIVE_HISTORY_PERIOD'));
		 EXCEPTION
			WHEN OTHERS THEN
			  gv_history_period := NULL;
		 END;

		 IF gv_history_period IS NULL THEN
			quest_soo_variable.set_parameter('ARCHIVE_HISTORY_PERIOD', '3');
			gv_history_period := 3;
		 END IF;
     END IF;

     gv_param_init := TRUE;
   END param_init;

   PROCEDURE add_drive_details (
      destination     VARCHAR2,
      total_space     NUMBER,
      free_space      NUMBER,
      usable_space    NUMBER,
      IDENTIFIER      VARCHAR2,
      instance_name   VARCHAR2,
      message         VARCHAR2
   )
   IS
      lv_idx   PLS_INTEGER;
   BEGIN
      quest_soo_tracing.add_debug(gc_package_name,'add_drive_details', 100,
                                  destination || ':' ||
                                  total_space || ':' ||
                                  free_space  || ':' ||
                                  usable_space || ':' ||
                                  IDENTIFIER || ':' ||
                                  instance_name || ':' ||
                                  message);

      IF SUBSTR (IDENTIFIER, 1, 1) = '+'
      THEN
        IF arr_drive_idx.exists(identifier) THEN
            lv_idx := arr_drive_idx(identifier);
        ELSE
            lv_idx := arr_drive_rec.COUNT + 1;
            arr_drive_idx (IDENTIFIER) := lv_idx;
        END IF;
      ELSE
        IF arr_drive_idx.EXISTS (instance_name || ':' || IDENTIFIER) THEN
            lv_idx := arr_drive_idx(instance_name || ':' || IDENTIFIER);
        ELSE
            lv_idx := arr_drive_rec.COUNT + 1;
            arr_drive_idx (instance_name || ':' || IDENTIFIER) := lv_idx;
        end IF;
      END IF;

      arr_drive_rec (lv_idx).dest_id := IDENTIFIER;
      arr_drive_rec (lv_idx).drive := destination;
      arr_drive_rec (lv_idx).total_space := total_space;
      arr_drive_rec (lv_idx).free_space := free_space;
      arr_drive_rec (lv_idx).usable_space := usable_space;
      arr_drive_rec (lv_idx).instance_name := instance_name;
      arr_drive_rec(lv_idx).message := substr(message, 1, 200);
   END;

   FUNCTION calculate_archivelog_rate (
      p_days      PLS_INTEGER,
      p_minutes   PLS_INTEGER
   )
      RETURN typ_arc_rec_ar2
   IS
      lrec_rate         typ_arc_rec_ar2;
      lv_minute_add     NUMBER;
      lv_next_date      DATE;
      lv_first_date     DATE;
      lv_rate_idx       PLS_INTEGER;
      lv_idx            PLS_INTEGER;
      lv_tbl_idx        PLS_INTEGER;
      lv_rate           NUMBER (16, 3);
      lv_tmp_rate       NUMBER (16, 3);
      lv_date_display   VARCHAR2 (30);
   BEGIN
      lv_minute_add := p_minutes / (60 * 24);

      FOR inst_idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         lv_next_date :=
            TO_DATE (TO_CHAR (SYSDATE - p_days, 'DD-Mon-YYYY HH24'),
                     'DD-Mon-YYYY HH24'
                    );
         lv_first_date := lv_next_date - lv_minute_add;
         lv_rate_idx := 0;
         lv_idx := ar2_arc_summary_rec (inst_idx).FIRST;

         WHILE lv_idx IS NOT NULL
         LOOP
            IF ar2_arc_summary_rec (inst_idx) (lv_idx).end_date >
                                                                lv_first_date
            THEN
               EXIT;
            ELSE
               lv_idx := ar2_arc_summary_rec (inst_idx).NEXT (lv_idx);
            END IF;
         END LOOP;

         WHILE lv_next_date < SYSDATE
         LOOP
            lv_rate_idx := lv_rate_idx + 1;
            lrec_rate (inst_idx) (lv_rate_idx).start_date := lv_next_date;
            lrec_rate (inst_idx) (lv_rate_idx).size_mb := 0;

            LOOP
               EXIT WHEN lv_idx IS NULL;
               lv_rate :=
                  (  ar2_arc_summary_rec (inst_idx) (lv_idx).size_mb
                   * p_minutes
                   / (  (  ar2_arc_summary_rec (inst_idx) (lv_idx).end_date
                         - ar2_arc_summary_rec (inst_idx) (lv_idx).start_date
                        )
                      * 24
                      * 60
                     )
                  );

              /* IF     lv_first_date <
                            ar2_arc_summary_rec (inst_idx) (lv_idx).start_date
                  AND lv_first_date <
                            ar2_arc_summary_rec (inst_idx) (lv_idx).end_date
               THEN
                  NULL;
                  dbms_output.put_line('1 ');
                  dbms_output.put_line('First Date: ' || TO_CHAR(lv_first_date, 'DD-Mon-YYYY HH24:MI:SS') || ' - Start:' ||
                                    TO_CHAR(ar2_arc_summary_rec (inst_idx) (lv_idx).start_date, 'DD-Mon-YYYY HH24:MI:SS')
                        || ' - End:' || TO_CHAR(ar2_arc_summary_rec (inst_idx) (lv_idx).end_date, 'DD-Mon-YYYY HH24:MI:SS')
                  );
                  lv_tmp_rate := */
               IF lv_next_date < ar2_arc_summary_rec (inst_idx) (lv_idx).start_date then
                null;
               ELSIF     ar2_arc_summary_rec (inst_idx) (lv_idx).start_date <
                                                                 lv_first_date
                     AND ar2_arc_summary_rec (inst_idx) (lv_idx).end_date >
                                                                  lv_next_date
               THEN
                  lrec_rate (inst_idx) (lv_rate_idx).size_mb :=
                         lrec_rate (inst_idx) (lv_rate_idx).size_mb + lv_rate;
               -- Use rate calulation for entire period
               ELSIF     ar2_arc_summary_rec (inst_idx) (lv_idx).start_date <
                                                                 lv_first_date
                     AND ar2_arc_summary_rec (inst_idx) (lv_idx).end_date <
                                                                  lv_next_date
               THEN
                  -- Use rate pro-rata for time between first_date and end_date
                  lv_tmp_rate :=
                       lrec_rate (inst_idx) (lv_rate_idx).size_mb
                     + (  lv_rate
                        * (  ar2_arc_summary_rec (inst_idx) (lv_idx).end_date
                           - lv_first_date
                          )
                        / lv_minute_add
                       );
                  lrec_rate (inst_idx) (lv_rate_idx).size_mb := lv_tmp_rate;
               ELSIF     ar2_arc_summary_rec (inst_idx) (lv_idx).start_date >
                                                                 lv_first_date
                     AND ar2_arc_summary_rec (inst_idx) (lv_idx).end_date >
                                                                  lv_next_date
                    -- AND ar2_arc_summary_rec(inst_idx)(lv_idx).start_date < lv_next_date
               THEN
                  -- Use rate pro-rata for time between end_date and next_date

                  lv_tmp_rate :=
                       lrec_rate (inst_idx) (lv_rate_idx).size_mb
                     + (  lv_rate
                        * (  lv_next_date
                           - ar2_arc_summary_rec (inst_idx) (lv_idx).start_date
                          )
                        / lv_minute_add
                       );
                  lrec_rate (inst_idx) (lv_rate_idx).size_mb := lv_tmp_rate;
               ELSIF     ar2_arc_summary_rec (inst_idx) (lv_idx).start_date >
                                                                 lv_first_date
                     AND ar2_arc_summary_rec (inst_idx) (lv_idx).end_date <
                                                                  lv_next_date
               THEN
                  -- Add total MB to rate total
                  lv_tmp_rate :=
                       lrec_rate (inst_idx) (lv_rate_idx).size_mb
                     + ar2_arc_summary_rec (inst_idx) (lv_idx).size_mb;
                  lrec_rate (inst_idx) (lv_rate_idx).size_mb := lv_tmp_rate;
               ELSE
                  NULL;
                  -- Should never get here
                  dbms_output.put_line('Shouldnt get here ');
               END IF;

               EXIT WHEN ar2_arc_summary_rec (inst_idx) (lv_idx).end_date >
                                                                  lv_next_date;
               lv_idx := ar2_arc_summary_rec (inst_idx).NEXT (lv_idx);
            END LOOP;

            lv_first_date := lv_next_date;
            lv_next_date := lv_next_date + lv_minute_add;
         END LOOP;
      END LOOP;

      RETURN lrec_rate;
   END calculate_archivelog_rate;

   FUNCTION get_archivelog_rate (p_days PLS_INTEGER, p_minutes PLS_INTEGER)
      RETURN quest_soo_alerttrace_log_typ
   IS
      TYPE typ_date IS TABLE OF DATE
         INDEX BY BINARY_INTEGER;

      TYPE typ_rate IS TABLE OF NUMBER (16, 2)
         INDEX BY BINARY_INTEGER;

      lrec_rate       typ_arc_rec_ar2;
      arr_date        typ_date;
      arr_rate        typ_rate;
      lnt_rate        quest_soo_alerttrace_log_typ;
      lv_minute_add   NUMBER;
      lv_next_date    DATE;
      lv_first_date   DATE;
      lv_rate_idx     PLS_INTEGER;
      lv_idx          PLS_INTEGER;
      lv_tbl_idx      PLS_INTEGER;
      lv_rate         NUMBER (16, 3);
   BEGIN
      IF NOT gv_initialised
      THEN
         init (0);
      END IF;

      lrec_rate := calculate_archivelog_rate (p_days, p_minutes);
      lnt_rate := NEW quest_soo_alerttrace_log_typ ();
      lv_tbl_idx := 1;

      FOR inst_idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         lnt_rate.EXTEND (lrec_rate (inst_idx).COUNT);

         FOR idx IN 1 .. lrec_rate (inst_idx).COUNT
         LOOP
            lnt_rate (lv_tbl_idx) :=
               quest_soo_alerttrace_line_typ
                                   (lrec_rate (inst_idx) (idx).start_date,
                                    arr_instance_rec (inst_idx).instance_name,
                                    lrec_rate (inst_idx) (idx).size_mb
                                   );
            lv_tbl_idx := lv_tbl_idx + 1;
         END LOOP;
      END LOOP;

      RETURN lnt_rate;
   END get_archivelog_rate;

   -- Central function to add a drive listing for get_drive_listing
   -- Added because object type more complex now
   FUNCTION add_drive_listing(p_drive_type  VARCHAR2,
                              p_destination VARCHAR2,
                              p_instance    varchar2)
   RETURN quest_soo_archive_dest_typ IS
    lnt     quest_soo_archive_dest_typ;
   BEGIN

   quest_soo_tracing.add_debug(gc_package_name,
                               'add_drive_listing',
                               100,
                               p_drive_type || ' - ' || p_destination || ' - ' || p_instance);

   lnt := quest_soo_archive_dest_typ(NULL,
                                     p_drive_type,
                                     NULL,
                                     NULL,
                                     p_destination,
                                     p_destination,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     p_instance,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL,
                                     NULL);
    RETURN lnt;
   END add_drive_listing;

   FUNCTION get_win_drive(p_drive VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
        RETURN nvl(SUBSTR(p_drive, 1,
                                          INSTR(p_drive, ':')),
                                          nvl(SUBSTR(p_drive, 1,
                                          INSTR(p_drive, '\', 1, 4) -1 ),
                                          p_drive));
   END get_win_drive;

-- Get drive listing of data required from Spotlight front END
-- Need to get data from OS and ASM instances
   FUNCTION get_drive_listing
      RETURN quest_soo_arc_dest_list_typ
   IS
      TYPE typ_dest IS TABLE OF VARCHAR2 (200)
         INDEX BY BINARY_INTEGER;

      TYPE typ_idx IS TABLE OF PLS_INTEGER
         INDEX BY LONG;

      larr_idx    typ_idx;
      larr_dest   typ_dest;
      lnt_lst     quest_soo_arc_dest_list_typ;
      lv_idx      PLS_INTEGER;
   BEGIN
      lnt_lst := NEW quest_soo_arc_dest_list_typ ();
      lv_idx := 0;

      quest_soo_tracing.add_debug(gc_package_name,'get_drive_listing',100,'Entering get_drive');

      FOR inst_idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         FOR idx IN 1 .. ar2_dest_rec (inst_idx).COUNT
         LOOP
               IF SUBSTR (ar2_dest_rec (inst_idx) (idx).destination_end, 1,
                          1) = '+' AND NOT larr_idx.EXISTS(ar2_dest_rec (inst_idx) (idx).destination_end) THEN

                  -- ASM
                  -- File system on ASM
                  lnt_lst.EXTEND;
                  lv_idx := lv_idx + 1;
                  lnt_lst (lv_idx) := add_drive_listing('ASM', ar2_dest_rec (inst_idx) (idx).destination_end, arr_instance_rec (inst_idx).instance_name);
                  larr_idx (ar2_dest_rec (inst_idx) (idx).destination_end) :=
                                                                           idx;
               ELSIF ar2_dest_rec (inst_idx) (idx).destination_end LIKE '%/%' AND
                  NOT larr_idx.EXISTS
                                  (   arr_instance_rec (inst_idx).instance_name
                                   || ':'
                                   || ar2_dest_rec (inst_idx) (idx).destination_end
                                  )
               THEN
                  -- File system on unix
                  lnt_lst.EXTEND;
                  lv_idx := lv_idx + 1;
                  lnt_lst (lv_idx) := add_drive_listing('UNIX',
                                                        ar2_dest_rec (inst_idx) (idx).destination_end,
                                                        arr_instance_rec (inst_idx).instance_name);

                  larr_idx (   arr_instance_rec (inst_idx).instance_name
                            || ':'
                            || ar2_dest_rec (inst_idx) (idx).destination_end
                           ) := idx;
               ELSIF (ar2_dest_rec (inst_idx) (idx).destination_end LIKE '%:%' OR
                        ar2_dest_rec (inst_idx) (idx).destination_end LIKE '%\\%') AND
                NOT
                    larr_idx.EXISTS(   arr_instance_rec (inst_idx).instance_name
                                   || ':'
                                   || get_win_drive(ar2_dest_rec (inst_idx) (idx).destination_end)
                                  )
               THEN
                  -- File system on windows
                  lnt_lst.EXTEND;
                  lv_idx := lv_idx + 1;
                  ar2_dest_rec (inst_idx) (idx).destination_end := get_win_drive(ar2_dest_rec (inst_idx) (idx).destination_end);
                  lnt_lst (lv_idx) := add_drive_listing('WIN',
                                                        ar2_dest_rec (inst_idx) (idx).destination_end,
                                                        arr_instance_rec (inst_idx).instance_name);
                  larr_idx (   arr_instance_rec (inst_idx).instance_name
                            || ':'
                            || ar2_dest_rec (inst_idx) (idx).destination_end
                           ) := idx;
               ELSIF NOT larr_idx.exists(arr_instance_rec(inst_idx).instance_name || ':' ||
                                         ar2_dest_rec(inst_idx)(idx).destination_end)
                     AND NOT larr_idx .exists(ar2_dest_rec (inst_idx) (idx).destination_end)
               THEN
                  lnt_lst.extend;
                  lv_idx := lv_idx + 1;
                  lnt_lst(lv_idx) := add_drive_listing('OTHER',
                                                       ar2_dest_rec(inst_idx)(idx).destination_end,
                                                       arr_instance_rec(inst_idx).instance_name);
               END IF;

         END LOOP;

         larr_idx.DELETE;
      END LOOP;

      quest_soo_tracing.add_debug(gc_package_name,'get_drive_listing',102,'Leaving get_drive_listing');

      RETURN lnt_lst;
   END get_drive_listing;

   FUNCTION setup_archive (p_idx PLS_INTEGER DEFAULT NULL, p_local PLS_INTEGER DEFAULT 0)
      RETURN typ_arc_rec_arr
   IS
      lrec_archive       typ_archive_rec_arr;
      lrec_summary       typ_arc_rec_arr;
      lrec_tmp_summary   typ_arc_rec_arr;
      lv_idx             PLS_INTEGER;
      lv_prev_sequence   NUMBER;
      lv_prev_date       DATE;
      gc_archive         rc;
   BEGIN
      IF NOT gv_param_init
      THEN
         param_init;
      END IF;

      IF gv_last_sequence IS NULL
      THEN
         gv_last_sequence := 0;
      END IF;

      BEGIN
          OPEN gc_archive for str_gc_archive USING gv_thread_number,
                                                   gv_thread_number,
                                                   gv_last_sequence,
                                                   gv_history_period;


          FETCH gc_archive
          BULK COLLECT INTO lrec_archive;

          CLOSE gc_archive;
      EXCEPTION
        WHEN OTHERS THEN
            IF gc_archive%ISOPEN THEN
                CLOSE gc_archive;
            END IF;

            gv_last_sequence := 0;
            lrec_summary := arr_local_arc_rec;
      END;

      lv_idx := 1;

      IF p_idx IS NOT NULL AND gv_last_sequence > 0
      THEN
         lrec_summary := arr_local_arc_rec;

         lv_idx := lrec_summary.COUNT + 1;
         lv_prev_date := lrec_summary (lrec_summary.COUNT).end_date;
         lv_prev_sequence := gv_last_sequence;
      END IF;

      FOR idx IN 1 .. lrec_archive.COUNT
      LOOP
         IF     lv_prev_sequence IS NOT NULL
            AND lv_prev_sequence != lrec_archive (idx).sequence#
         THEN
            lrec_summary (lv_idx).start_date := lv_prev_date;
            lrec_summary (lv_idx).end_date := lrec_archive (idx).next_time;
            lrec_summary (lv_idx).size_mb := lrec_archive (idx).size_mb;
            lv_idx := lv_idx + 1;
         END IF;

         lv_prev_sequence := lrec_archive (idx).sequence#;
         lv_prev_date := lrec_archive (idx).next_time;
      END LOOP;

      IF lrec_archive.last IS NOT NULL AND lrec_summary.COUNT > 5 THEN
          gv_last_sequence := lrec_archive (lrec_archive.LAST).sequence#;
      END IF;

      IF lrec_summary.EXISTS (lrec_archive.COUNT)
      THEN
         IF lrec_summary (lrec_archive.COUNT).end_date < (SYSDATE - gv_history_period)
         THEN
            lv_idx := 1;

            FOR idx IN lrec_archive.COUNT .. lrec_summary.COUNT
            LOOP
               lrec_tmp_summary (lv_idx) := lrec_summary (idx);
               lv_idx := lv_idx + 1;
            END LOOP;

            lrec_summary := lrec_tmp_summary;
            lrec_tmp_summary.DELETE;
         END IF;
      END IF;

      arr_local_arc_rec := lrec_summary;

      RETURN lrec_summary;
   END setup_archive;

   FUNCTION dest_entry
      RETURN typ_dest_rec_arr
   IS
      larr_dest_rec   typ_dest_rec_arr;
   BEGIN
      quest_soo_tracing.add_debug(gc_package_name,'dest_entry',100, 'Entering dest_entry');

      IF NOT gv_param_init
      THEN
         param_init;
      END IF;

      IF gv_db_version < 10 THEN
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry',101, '9i - ' || gv_9i_query);
        -- Execute version 9 query
        execute IMMEDIATE gv_9i_query BULK COLLECT INTO larr_dest_rec;

      ELSIF gv_db_version < 10.2 THEN
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry',102, '10.1 - ' || gv_10g_query);
        -- execute 10.1 version
        execute IMMEDIATE gv_10g_query BULK COLLECT INTO larr_dest_rec USING IN gv_recovery_dest;
      ELSE
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry',103,'10.2 - ' || gv_10gr2_query);
        -- Execute 10g version
        execute IMMEDIATE gv_10gr2_query BULK COLLECT INTO larr_dest_rec USING IN gv_recovery_dest;
      END IF;

      FOR idx IN 1..larr_dest_rec.COUNT LOOP
        IF INSTR(larr_dest_rec(idx).destination_end, '\') > 0 THEN
            larr_dest_rec(idx).destination_end := UPPER(get_win_drive(larr_dest_rec(idx).destination_end));
        END IF;

        IF larr_dest_rec(idx).is_asm = 'TRUE' THEN
            IF instr(larr_dest_rec(idx).destination_end, '\') > 0 THEN
                larr_dest_rec(idx).destination_end := substr(larr_dest_rec(idx).destination_end, 1, instr(larr_dest_rec(idx).destination_end, '\') -1);
            ELSIF instr(larr_dest_rec(idx).destination_end, '/') > 0 THEN
                larr_dest_rec(idx).destination_end := substr(larr_dest_rec(idx).destination_end, 1, instr(larr_dest_rec(idx).destination_end, '/') -1);
            END IF;
        END IF;
      END LOOP;

      RETURN larr_dest_rec;
   END dest_entry;

   PROCEDURE get_dest_entries
   IS
   BEGIN
      FOR inst_idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         IF arr_instance_rec (inst_idx).db_link IS NULL
         THEN
            -- Local copy
            ar2_dest_rec (inst_idx) := dest_entry;
         ELSE
            --BEGIN
				-- Get remote copy
				EXECUTE IMMEDIATE    'DECLARE '
								  || 'lrec_dest quest_soo_archivelog.typ_dest_rec_arr@'
								  || arr_instance_rec (inst_idx).db_link
								  || ';'
								  || 'local_rec quest_soo_archivelog.typ_dest_rec_arr; '
								  || 'BEGIN '
								  || 'lrec_dest := quest_soo_archivelog.dest_entry@'
								  || arr_instance_rec (inst_idx).db_link
								  || '; '
								  || 'FOR idx IN 1..lrec_dest.COUNT LOOP '
								  || 'local_rec(idx).session_id := lrec_dest(idx).session_id ; '
								  || 'local_rec(idx).sequence_num := lrec_dest(idx).sequence_num ; '
								  || 'local_rec(idx).tree_depth := lrec_dest(idx).tree_depth ; '
								  || 'local_rec(idx).dest_name := lrec_dest(idx).dest_name ; '
								  || 'local_rec(idx).status := lrec_dest(idx).status ; '
								  || 'local_rec(idx).target := lrec_dest(idx).target ; '
								  || 'local_rec(idx).destination := lrec_dest(idx).destination ; '
								  || 'local_rec(idx).destination_end := lrec_dest(idx).destination_end; '
								  || 'local_rec(idx).BINDING := lrec_dest(idx).BINDING ; '
								  || 'local_rec(idx).log_sequence := lrec_dest(idx).log_sequence ; '
								  || 'local_rec(idx).reopen_secs := lrec_dest(idx).reopen_secs ; '
								  || 'local_rec(idx).transmit_mode := lrec_dest(idx).transmit_mode ; '
								  || 'local_rec(idx).TYPE := lrec_dest(idx).TYPE ; '
								  || 'local_rec(idx).valid_type := lrec_dest(idx).valid_type ; '
								  || 'local_rec(idx).total_mb := lrec_dest(idx).total_mb ; '
								  || 'local_rec(idx).free_mb := lrec_dest(idx).free_mb ; '
								  || 'local_rec(idx).usable_file_mb := lrec_dest(idx).usable_file_mb ; '
								  || 'local_rec(idx).reclaimable_mb := lrec_dest(idx).reclaimable_mb ; '
								  || 'local_rec(idx).is_asm := lrec_dest(idx).is_asm ; '
								  || 'local_rec(idx).is_recovery := lrec_dest(idx).is_recovery ; '
								  || 'local_rec(idx).min_record := lrec_dest(idx).min_record ; '
								  || 'local_rec(idx).time_to_failure := lrec_dest(idx).time_to_failure; '
								  || 'local_rec(idx).instance_name := lrec_dest(idx).instance_name ; '
								  || 'local_rec(idx).error := lrec_dest(idx).error; '
								  || 'local_rec(idx).archiver_status := lrec_dest(idx).archiver_status; '
								  || '    END LOOP; '
								  || '    quest_soo_archivelog.garr_tmp_dest := local_rec; '
								  || 'END;';

            ar2_dest_rec (inst_idx) := garr_tmp_dest;
            garr_tmp_dest.DELETE;
         END IF;
      END LOOP;
   END get_dest_entries;

   PROCEDURE get_archive_entries
   IS
   BEGIN
      FOR idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         IF arr_instance_rec (idx).db_link IS NULL
         THEN
            -- get local entries
            ar2_arc_summary_rec (idx) := setup_archive (idx, 1);
         ELSE
            -- Get remote entries
            EXECUTE IMMEDIATE    'DECLARE '
                              || ' lrec_tmp quest_soo_archivelog.typ_arc_rec_arr@'
                              || arr_instance_rec (idx).db_link
                              || '; '
                              || 'lrec_local quest_soo_archivelog.typ_arc_rec_arr; '
                              || 'BEGIN '
                              || 'lrec_tmp := quest_soo_archivelog.setup_archive@'
                              || arr_instance_rec (idx).db_link
                              || '(' || idx || '); '
                              || 'FOR idx IN 1..lrec_tmp.COUNT LOOP '
                              || 'lrec_local(idx).START_DATE := lrec_tmp(idx).START_DATE; '
                              || 'lrec_local(idx).end_date := lrec_tmp(idx).end_date; '
                              || 'lrec_local(idx).size_mb := lrec_tmp(idx).size_mb; '
                              || 'END LOOP; '
                              || 'quest_soo_archivelog.garr_tmp_arc := lrec_local; '
                              || 'END;';

            ar2_arc_summary_rec (idx) := garr_tmp_arc;
            garr_tmp_arc.DELETE;
         END IF;

      END LOOP;
   END get_archive_entries;

   PROCEDURE get_db_version IS
   BEGIN
        execute immediate 'SELECT TO_NUMBER(SUBSTR(version, 1, INSTR(version, ''.'', 1, 2) - 1), ''99.99'') version_num, TO_NUMBER(SUBSTR(version, INSTR(version, ''.'',1,2)+1, INSTR(version, ''.'', 1, 4) - INSTR(version, ''.'',1,2) - 1),''99.99'') patch_level, instance_name
                           FROM v$instance'
                           INTO gv_db_version, gv_db_patch_level, gv_instance_name;
   END get_db_version;

   PROCEDURE init (p_rac PLS_INTEGER)
   IS
      larr_dest_rec   typ_dest_rec_arr;
      lv_rac          PLS_INTEGER;
   BEGIN
      quest_soo_tracing.add_debug(gc_package_name,'init',100,'Entering INIT procedure. Param:' || p_rac);

      IF gv_rac_call = 1 OR p_rac = 1 THEN
        IF gv_rac_call != 1 THEN
            gv_init := 0;
        END IF;
        lv_rac := 1;
        gv_rac_call := 1;
      ELSE
        lv_rac := p_rac;
        gv_rac_call := 0;
      END IF;

      arr_instance_rec.DELETE;
      ar2_dest_rec.DELETE;
      ar2_arc_summary_rec.DELETE;

      IF lv_rac = 1
      THEN
         arr_instance_rec := quest_soo_variable.get_current_dblinks;
      ELSE
         execute immediate 'SELECT INSTANCE_number, instance_name, host_name
                            FROM v$instance' INTO arr_instance_rec (1).instance_number,
                                                  arr_instance_rec (1).instance_name,
                                                  arr_instance_rec (1).HOST;
      END IF;

      IF gv_init = 0 OR NOT gv_initialised
      THEN
         quest_soo_tracing.add_debug(gc_package_name,'init', 101, 'param init');
         param_init;
      END IF;

      FOR idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         arr_inst_reverse_idx (arr_instance_rec (idx).instance_name) := idx;
      END LOOP;

      BEGIN
         quest_soo_tracing.add_debug(gc_package_name,'init', 102, 'get dest entries');
         get_dest_entries;

         IF gv_archivelog THEN
            quest_soo_tracing.add_debug(gc_package_name,'init',103, 'archive entries');
            get_archive_entries;
         END IF;

      EXCEPTION
         WHEN OTHERS THEN
            gv_restart_count := gv_restart_count + 1;
            quest_soo_tracing.process_exception(gc_package_name,'init',104,sqlcode,sqlerrm);

            quest_soo_tracing.add_debug(gc_package_name,'init',106,'Restart count:' || gv_restart_count);
            IF gv_restart_count < 10 THEN
                init(lv_rac);
            ELSE
                RAISE;
            END IF;
      END;
      gv_restart_count := 0;

      gv_initialised := TRUE;
      gv_init := gv_init + 1;

      IF gv_init > 10
      THEN
         gv_init := 0;
      END IF;

      quest_soo_tracing.add_debug(gc_package_name,'init',107,'End of init');
   EXCEPTION
    WHEN OTHERS THEN
        quest_soo_tracing.process_exception(gc_package_name,'init',300,sqlcode,sqlerrm);
   END init;

   FUNCTION calculate_ttf (
      p_arc_summary   typ_arc_rec_arr,
      p_total_space   NUMBER,
      p_free_space    NUMBER,
      p_dest_mult     PLS_INTEGER
   )
      RETURN NUMBER
   IS
      lv_total_mb       NUMBER;
      lv_total_window   NUMBER;
      lv_ttf            NUMBER;
      lv_tmp_ttf        NUMBER;
      lv_idx            PLS_INTEGER;
   BEGIN
      IF NVL (p_free_space, 0) <= 0
      THEN
         IF NVL(p_total_space, 0) > 0 THEN
            RETURN 0;
         ELSE
            RETURN NULL;
         END IF;
      END IF;

      lv_total_mb := 0;
      lv_total_window := 0;
      lv_ttf := NULL;
      lv_idx := p_arc_summary.LAST;

      WHILE lv_idx > 0
      LOOP
         lv_total_window :=
              lv_total_window
            + (  p_arc_summary (lv_idx).end_date
               - p_arc_summary (lv_idx).start_date
              );
         lv_total_mb := lv_total_mb + p_arc_summary (lv_idx).size_mb;

         lv_tmp_ttf :=
                  (p_free_space / p_dest_mult / lv_total_mb) * lv_total_window;

         IF lv_tmp_ttf > lv_total_window OR lv_ttf IS NULL
         THEN
            lv_ttf := lv_tmp_ttf;
         ELSE
            EXIT;
         END IF;

         lv_idx := lv_idx - 1;
      END LOOP;

      RETURN lv_ttf;
   END calculate_ttf;

   FUNCTION merge_dest_entries (parr_drives typ_drive_rec_arr, p_multiplier PLS_INTEGER DEFAULT NULL)
      RETURN typ_arc_rec_arr
   IS
      arr_idx           quest_soo_archivelog.typ_drive_idx;
      arr_out_summary   quest_soo_archivelog.typ_arc_rec_arr;
      lv_start_date     DATE;
      lv_next_date      DATE;
      lv_interval       NUMBER;
      lv_prev_date      DATE;
      lv_end_date       DATE;
      lv_size_mb        NUMBER;
      lv_idx            PLS_INTEGER;
      lv_exit           BOOLEAN                              := FALSE;
      lv_first          BOOLEAN;
      lv_date_idx       PLS_INTEGER;
      lv_out_idx        PLS_INTEGER;
   BEGIN
      lv_start_date := NULL;
      lv_next_date := NULL;
      lv_prev_date := NULL;
      lv_first := TRUE;
      lv_out_idx := 0;
      lv_idx := parr_drives.FIRST;

      WHILE lv_idx IS NOT NULL
      LOOP
         arr_idx (lv_idx) := 1;
         lv_idx := parr_drives.NEXT (lv_idx);
      END LOOP;

      WHILE NOT lv_exit
      LOOP
         lv_idx := parr_drives.FIRST;

         WHILE lv_idx IS NOT NULL
         LOOP
            IF arr_idx (lv_idx) IS NOT NULL
            THEN
               IF lv_first
               THEN
                  IF    lv_start_date IS NULL
                     OR lv_start_date <
                           ar2_arc_summary_rec (lv_idx) (arr_idx (lv_idx)).start_date
                  THEN
                     lv_start_date :=
                        ar2_arc_summary_rec (lv_idx) (arr_idx (lv_idx)).start_date;
                  END IF;
               END IF;

               IF    lv_end_date IS NULL
                  OR ar2_arc_summary_rec (lv_idx) (arr_idx (lv_idx)).end_date <
                                                                   lv_end_date
               THEN
                  lv_end_date :=
                     ar2_arc_summary_rec (lv_idx) (arr_idx (lv_idx)).end_date;
                  lv_size_mb :=
                      ar2_arc_summary_rec (lv_idx) (arr_idx (lv_idx)).size_mb * NVL(p_multiplier, parr_drives(lv_idx).number_ttf);
                  lv_date_idx := lv_idx;
               END IF;
            END IF;

            lv_idx := parr_drives.NEXT (lv_idx);
         END LOOP;

         lv_first := FALSE;
         IF lv_out_idx = 0 THEN
             lv_out_idx := 1;
             arr_out_summary (lv_out_idx).start_date := lv_start_date;
             arr_out_summary (lv_out_idx).end_date := lv_end_date;
             arr_out_summary (lv_out_idx).size_mb := lv_size_mb;
         ELSE
            IF arr_out_summary(lv_out_idx).START_DATE = lv_start_date AND
                arr_out_summary(lv_out_idx).end_date = lv_end_date THEN
                arr_out_summary(lv_out_idx).size_mb := arr_out_summary(lv_out_idx).size_mb + lv_size_mb;
            ELSE
                lv_out_idx := lv_out_idx + 1;
                arr_out_summary (lv_out_idx).start_date := lv_start_date;
                arr_out_summary (lv_out_idx).end_date := lv_end_date;
                arr_out_summary (lv_out_idx).size_mb := lv_size_mb;
            END IF;
         END IF;

         arr_idx (lv_date_idx) :=
                ar2_arc_summary_rec (lv_date_idx).NEXT (arr_idx (lv_date_idx));
         lv_exit := TRUE;
         lv_idx := arr_idx.FIRST;
         lv_start_date := lv_end_date;
         lv_end_date := NULL;

         WHILE lv_idx IS NOT NULL
         LOOP
            IF arr_idx (lv_idx) IS NOT NULL
            THEN
               lv_exit := FALSE;
               EXIT;
            END IF;

            lv_idx := arr_idx.NEXT (lv_idx);
         END LOOP;
      END LOOP;

      RETURN arr_out_summary;
   END merge_dest_entries;

   PROCEDURE move_rec (p_rec IN OUT typ_drive_idx, p_start_idx PLS_INTEGER)
   IS
      lv_new_idx   PLS_INTEGER;
      lv_idx       PLS_INTEGER;
   BEGIN
      lv_new_idx := p_rec.COUNT + 1;
      lv_idx := p_rec.COUNT;

      WHILE lv_idx >= p_start_idx
      LOOP
         p_rec (lv_new_idx) := p_rec (lv_idx);
         lv_new_idx := lv_new_idx - 1;
         lv_idx := lv_idx - 1;
      END LOOP;
   END move_rec;

   -- Used for when archiving is disabled but we still want to display something
   PROCEDURE find_min_space_rec(p_dest IN OUT typ_dest_rec_arr)
   IS
     lv_min_space           NUMBER;
     lv_min_idx             PLS_INTEGER;
     lv_min_instance_space  NUMBER;
     lv_min_instance_idx    PLS_INTEGER;

   BEGIN
        lv_min_space := 0;
        lv_min_idx := 0;
        lv_min_instance_space := 0;
        lv_min_instance_idx := 0;

        FOR idx IN 1..p_dest.COUNT LOOP
            IF (lv_min_space > 0 AND p_dest(idx).usable_file_mb < lv_min_space) OR
                (lv_min_space = 0 AND p_dest(idx).usable_file_mb > 0)
            THEN
                lv_min_space := p_dest(idx).usable_file_mb;
                lv_min_idx := idx;
            END IF;

            IF p_dest(idx).instance_name = gv_instance_name AND
                ((lv_min_instance_space > 0 AND p_dest(idx).usable_file_mb < lv_min_instance_space) OR
                 (lv_min_instance_space = 0 AND p_dest(idx).usable_file_mb > 0))
            THEN
                lv_min_instance_space := p_dest(idx).usable_file_mb;
                lv_min_instance_idx := idx;
            END IF;
        END LOOP;

        IF lv_min_idx > 0 THEN
            p_dest(lv_min_idx).MIN_record := 1;
        END IF;

        IF lv_min_instance_idx > 0 THEN
            p_dest(lv_min_instance_idx).local_min_rec := 1;
        END IF;
   END find_min_space_rec;

   PROCEDURE find_min_rec(p_dest IN OUT typ_dest_rec_arr)
   IS
      lv_inst_idx       PLS_INTEGER;
      lv_idx            PLS_INTEGER;
      lv_local_idx      PLS_INTEGER;
      lv_mand_end       PLS_INTEGER;
      lv_fail_idx       PLS_INTEGER;
      lv_first_idx      PLS_INTEGER;
      lv_local_db_fail  PLS_INTEGER;
      lv_local_fail     PLS_INTEGER;
      lv_tmp_mand       PLS_INTEGER;
      lv_instance_fail  BOOLEAN;
      lv_one_worked     BOOLEAN := FALSE;
      arr_fail_idx      typ_drive_idx;
      arr_db_idx        typ_drive_idx;
      arr_first_fail    typ_drive_idx;
      arr_db_fail       typ_drive_idx;
      arr_local_fail    typ_drive_idx;
   BEGIN

        FOR inst_idx IN 1..arr_instance_rec.COUNT LOOP
            lv_idx := 1;
            lv_mand_end := NULL;
            arr_fail_idx.DELETE;
            arr_db_idx.DELETE;
            arr_local_fail.DELETE;
            lv_instance_fail := FALSE;

            FOR dest_idx IN 1..p_dest.COUNT LOOP
                IF p_dest(dest_idx).instance_name = arr_instance_rec(inst_idx).instance_name
                AND p_dest(dest_idx).time_to_failure IS NOT NULL
                AND p_dest(dest_idx).archiver_status != 'FAILED'  THEN

                    lv_one_worked := TRUE;

                    IF lv_idx = 1 THEN
                        arr_fail_idx(lv_idx) := dest_idx;
                        arr_db_idx(lv_idx) := dest_idx;
                        arr_local_fail(lv_idx) := dest_idx;

                        IF p_dest(dest_idx).BINDING = 'MANDATORY' THEN
                            lv_mand_end := lv_idx;
                        END IF;
                    ELSE
                        IF p_dest(dest_idx).BINDING = 'MANDATORY' THEN
                            IF lv_mand_end IS NULL THEN
                                move_rec(arr_fail_idx,1);
                                arr_fail_idx(1) := dest_idx;
                                move_rec(arr_local_fail,1);
                                arr_local_fail(1) := dest_idx;
                                lv_mand_end := 1;
                            ELSE
                                FOR idx IN 1..lv_mand_end LOOP
                                    lv_tmp_mand := lv_mand_end;
                                    IF p_dest(arr_fail_idx(idx)).time_to_failure < p_dest(dest_idx).time_to_failure THEN
                                        move_rec(arr_fail_idx,idx);
                                        arr_fail_idx(idx) := dest_idx;
                                        lv_mand_end := lv_mand_end + 1;

                                    ELSIF idx = lv_mand_end THEN
                                        lv_mand_end := lv_mand_end + 1;
                                        move_rec(arr_fail_idx,lv_mand_end);
                                        arr_fail_idx(lv_mand_end) := dest_idx;

                                    END IF;

                                    IF arr_instance_rec(inst_idx).instance_name = gv_instance_name
                                        AND p_dest(arr_local_fail(idx)).local_ttf < p_dest(dest_idx).local_ttf THEN

                                        move_rec(arr_local_fail,idx);
                                        arr_local_fail(idx) := dest_idx;
                                    ELSIF arr_instance_rec(inst_idx).instance_name = gv_instance_name AND idx = lv_tmp_mand
                                    THEN
                                        move_rec(arr_local_fail,lv_mand_end);
                                        arr_local_fail(lv_mand_end) := dest_idx;
                                    END IF;
                                END LOOP;
                            END IF;
                        ELSE
                            IF NVL(lv_mand_end, 0) < arr_fail_idx.COUNT THEN

                                FOR idx IN (NVL(lv_mand_end,0) + 1)..arr_fail_idx.count LOOP

                                    IF p_dest(dest_idx).time_to_failure > p_dest(arr_fail_idx(idx)).time_to_failure THEN
                                        move_rec(arr_fail_idx,idx);
                                        arr_fail_idx(idx) := dest_idx;

                                        EXIT;
                                    ELSIF idx = arr_fail_idx.COUNT THEN
                                        arr_fail_idx(lv_idx) := dest_idx;

                                    END IF;
                                END LOOP;
                                IF arr_instance_rec(inst_idx).instance_name = gv_instance_name THEN
                                    FOR idx IN (NVL(lv_mand_end,0) + 1)..arr_local_fail.count LOOP
                                        IF p_dest(dest_idx).local_ttf > p_dest(arr_local_fail(idx)).local_ttf THEN
                                            move_rec(arr_local_fail,idx);
                                            arr_local_fail(idx) := dest_idx;

                                            EXIT;
                                        ELSIF idx = arr_local_fail.COUNT THEN
                                            arr_local_fail(lv_idx) := dest_idx;

                                        END IF;
                                    END LOOP;
                                END IF;
                            ELSE
                                arr_fail_idx(lv_idx) := dest_idx;

                                IF arr_instance_rec(inst_idx).instance_name = gv_instance_name THEN
                                    arr_local_fail(lv_idx) := dest_idx;
                                END IF;
                            END IF;
                        END IF;
                    END IF;
                    lv_idx := lv_idx + 1;
                ELSIF p_dest(dest_idx).archiver_status = 'FAILED' THEN
                    lv_instance_fail := TRUE;
                END IF;

            END LOOP;

            IF lv_mand_end IS NOT NULL THEN
                IF p_dest(arr_fail_idx(lv_mand_end)).time_to_failure < p_dest(arr_fail_idx(arr_fail_idx.last)).time_to_failure THEN
                    arr_first_fail(inst_idx) := arr_fail_idx(lv_mand_end);
                ELSE
                    arr_first_fail(inst_idx) := arr_fail_idx(arr_fail_idx.last);
                END IF;

                IF lv_mand_end >= arr_min_succeed(inst_idx) THEN
                    arr_db_fail(inst_idx) := arr_fail_idx(lv_mand_end);
                ELSE
                    IF arr_fail_idx.EXISTS(arr_min_succeed(inst_idx)) THEN

                        IF p_dest(arr_fail_idx(lv_mand_end)).time_to_failure < p_dest(arr_fail_idx(arr_min_succeed(inst_idx))).time_to_failure THEN
                            arr_db_fail(inst_idx) := arr_fail_idx(lv_mand_end);
                        ELSE
                            arr_db_fail(inst_idx) := arr_fail_idx(arr_min_succeed(inst_idx));
                        END IF;
                    ELSE
                        IF arr_fail_idx.COUNT > 0 THEN
                            IF p_dest(arr_fail_idx(lv_mand_end)).time_to_failure < p_dest(arr_fail_idx(arr_fail_idx.last)).time_to_failure THEN
                                arr_db_fail(inst_idx) := arr_fail_idx(lv_mand_end);
                            ELSE
                                arr_db_fail(inst_idx) := arr_fail_idx(arr_fail_idx.last);
                            END IF;
                        ELSE
                            arr_db_fail(inst_idx) := NULL;
                        END IF;
                    END IF;
                END IF;
            ELSE
                IF arr_fail_idx.COUNT > 0 THEN
                    arr_first_fail(inst_idx) := arr_fail_idx(arr_fail_idx.last);
                ELSE
                    arr_first_fail(inst_idx) := NULL;
                END IF;
                IF arr_fail_idx.EXISTS(arr_min_succeed(inst_idx)) THEN
                    arr_db_fail(inst_idx) := arr_fail_idx(arr_min_succeed(inst_idx));
                ELSE
                    IF arr_fail_idx.COUNT > 0 THEN
                        arr_db_fail(inst_idx) := arr_fail_idx(arr_fail_idx.LAST);
                    ELSE
                        arr_db_fail(inst_idx) := NULL;
                    END IF;
                END IF;
            END IF;

            IF arr_instance_rec(inst_idx).instance_name = gv_instance_name THEN
                IF lv_instance_fail THEN
                    FOR dest_idx IN 1..p_dest.COUNT LOOP
                        IF p_dest(dest_idx).instance_name = arr_instance_rec(inst_idx).instance_name
                        AND p_dest(dest_idx).status = 'ERROR' THEN
                            p_dest(dest_idx).local_min_rec := 1;
                            EXIT;
                        END IF;
                    END LOOP;
                ELSIF lv_mand_end IS NOT NULL THEN
                    IF p_dest(arr_local_fail(lv_mand_end)).local_ttf < p_dest(arr_local_fail(arr_local_fail.last)).local_ttf THEN
                        lv_local_fail := arr_local_fail(lv_mand_end);
                    ELSE
                        lv_local_fail := arr_local_fail(arr_local_fail.last);
                    END IF;

                    IF lv_mand_end > arr_min_succeed(inst_idx) THEN
                        lv_local_db_fail := arr_local_fail(lv_mand_end);
                    ELSE
                        IF arr_local_fail.exists(arr_min_succeed(inst_idx)) THEN
                            IF p_dest(arr_local_fail(lv_mand_end)).local_ttf < p_dest(arr_local_fail(arr_min_succeed(inst_idx))).local_ttf THEN
                                lv_local_db_fail := arr_local_fail(lv_mand_end);
                            ELSE
                                lv_local_db_fail := arr_local_fail(arr_min_succeed(inst_idx));
                            END IF;
                        ELSE
                            IF arr_local_fail.COUNT > 0 THEN
                                IF p_dest(arr_local_fail(lv_mand_end)).local_ttf < p_dest(arr_local_fail(arr_local_fail.last)).local_ttf THEN
                                    lv_local_db_fail := arr_local_fail(lv_mand_end);
                                ELSE
                                    lv_local_db_fail := arr_local_fail(arr_local_fail.last);
                                END IF;
                            ELSE
                                lv_local_db_fail := NULL;
                            END IF;
                        end IF;
                    END IF;
                ELSE
                    IF arr_local_fail.COUNT > 0 THEN
                        lv_local_fail := arr_local_fail(arr_local_fail.last);
                    ELSE
                        lv_local_fail := NULL;
                    END IF;

                    IF arr_local_fail.EXISTS(arr_min_succeed(inst_idx)) THEN
                        lv_local_db_fail := arr_local_fail(arr_min_succeed(inst_idx));
                    ELSE
                        IF arr_local_fail.COUNT > 0 THEN
                            lv_local_db_fail := arr_local_fail(arr_local_fail.LAST);
                        ELSE
                            lv_local_db_fail := NULL;
                        END IF;
                    END IF;
                END IF;
            END IF;

        END LOOP;

        lv_idx := arr_db_fail.first;
        lv_first_idx := lv_idx;
        lv_fail_idx := lv_idx;
        WHILE lv_idx IS NOT NULL LOOP
            --dbms_output.put_line('Idx:' || lv_idx || ' - DB Fail:' || arr_db_fail(lv_idx) ||  );
            IF arr_db_fail(lv_idx) IS NOT NULL THEN
                IF arr_db_fail(lv_fail_idx) IS NOT NULL  AND
                    p_dest(arr_db_fail(lv_idx)).time_to_failure > p_dest(arr_db_fail(lv_fail_idx)).time_to_failure
                THEN
                    lv_fail_idx := lv_idx;
                ELSIF arr_db_fail(lv_fail_idx) IS null THEN
                    lv_fail_idx := lv_idx;
                END IF;
            END IF;

            IF arr_first_fail(lv_idx) IS NOT NULL  THEN
                IF arr_first_fail(lv_first_idx) IS NOT NULL AND
                    p_dest(arr_first_fail(lv_idx)).time_to_failure < p_dest(arr_first_fail(lv_first_idx)).time_to_failure
                THEN
                    lv_first_idx := lv_idx;
                ELSIF arr_first_fail(lv_first_idx) IS null THEN
                    lv_first_idx := lv_idx;
                END IF;
            END IF;

            lv_idx := arr_db_fail.NEXT(lv_idx);
        END LOOP;

        -- Assign first fail
        IF lv_first_idx IS NOT NULL AND arr_first_fail(lv_first_idx) IS NOT NULL THEN
            p_dest(arr_first_fail(lv_first_idx)).min_record := 2;
        END IF;

        IF lv_fail_idx IS NOT NULL AND arr_db_fail(lv_fail_idx) IS NOT NULL THEN
            p_dest(arr_db_fail(lv_fail_idx)).min_record := 1;
        END IF;

        IF lv_local_fail IS NOT NULL THEN
            p_dest(lv_local_fail).local_min_rec := 2;
        END IF;

        IF lv_local_db_fail IS NOT NULL THEN
            p_dest(lv_local_db_fail).local_min_rec := 1;
        END IF;

        IF NOT lv_one_worked THEN
            FOR idx IN 1..p_dest.COUNT LOOP
                IF p_dest(idx).total_mb > 0 AND  p_dest(idx).status = 'ERROR' THEN
                    p_dest(idx).min_record := 1;
                    lv_one_worked := TRUE;
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        IF NOT lv_one_worked THEN
            find_min_space_rec(p_dest);
        END IF;

   END find_min_rec;

   PROCEDURE generate_ttf (p_dest IN OUT typ_dest_rec_arr)
   IS
      larr_unique      typ_inst_ar2;
      lrec_drive       typ_drive_rec_arr;
      lrec_blank       typ_drive_rec_arr;
      lrec_summary     typ_arc_rec_arr;
      lv_mirror        PLS_INTEGER       := 2;
      lv_idx           PLS_INTEGER;
      lv_unique        LONG;
      lv_count         PLS_INTEGER;
      lv_count_recov   PLS_INTEGER;
      lv_inst_idx      PLS_INTEGER;
      lv_drive_free    NUMBER;
      lv_recov_ttf     NUMBER;
      lv_ttf           NUMBER;
      lv_local_inst    NUMBER;
   BEGIN

      lv_local_inst := arr_inst_reverse_idx (gv_instance_name);

      FOR idx IN 1 .. p_dest.COUNT
      LOOP
         IF p_dest (idx).dest_name IS NOT NULL AND p_dest(idx).status = 'VALID'
         THEN
            IF SUBSTR (p_dest (idx).destination_end, 1, 1) = '+'
            THEN
               -- ASM
               larr_unique (p_dest (idx).destination_end) (idx) :=
                                                   p_dest (idx).instance_name;
            ELSIF INSTR (p_dest (idx).destination_end, '/') > 0
            THEN
               -- Unix
               IF arr_drive_idx.EXISTS (   p_dest (idx).instance_name
                                        || ':'
                                        || p_dest (idx).destination_end
                                       )
               THEN
                  lv_idx :=
                     arr_drive_idx (   p_dest (idx).instance_name
                                    || ':'
                                    || p_dest (idx).destination_end
                                   );

                  IF lv_idx IS NOT NULL
                  THEN
                     IF INSTR (arr_drive_rec (lv_idx).drive, ':') > 0
                     THEN
                        larr_unique (arr_drive_rec (lv_idx).drive) (idx) :=
                                                   p_dest (idx).instance_name;
                     ELSE
                        lv_inst_idx :=
                            arr_inst_reverse_idx (p_dest (idx).instance_name);
                        larr_unique (   arr_instance_rec (lv_inst_idx).HOST
                                     || ':'
                                     || arr_drive_rec (lv_idx).drive
                                    ) (idx) := p_dest (idx).instance_name;
                     END IF;
                  END IF;
               END IF;
            ELSIF INSTR(p_dest(IDX).destination_end, '\') > 0 OR INSTR(p_dest(IDX).destination_end, ':') > 0 THEN
               -- Windows
               larr_unique (p_dest (idx).destination_end || ':'
               || p_dest(idx).instance_name) (idx) :=
                                                   p_dest (idx).instance_name;
            END IF;
         END IF;
      END LOOP;

      lv_unique := larr_unique.FIRST;

      WHILE lv_unique IS NOT NULL
      LOOP
         lv_count := larr_unique (lv_unique).COUNT;
         lv_idx := larr_unique (lv_unique).FIRST;
         lrec_drive := lrec_blank;
         lv_count_recov := 0;

         -- Find recovery and regular free space to calculate TTF from
         WHILE lv_idx IS NOT NULL
         LOOP
            lv_inst_idx :=
                         arr_inst_reverse_idx (p_dest (lv_idx).instance_name);

            IF p_dest (lv_idx).destination_end IS NULL
            THEN
               lrec_drive (lv_inst_idx).dest_id :=
                                              p_dest (lv_idx).destination_end;
            END IF;


            IF p_dest (lv_idx).is_recovery = 'TRUE'
            THEN
               lrec_drive (lv_inst_idx).recovery_total :=
                                                     p_dest (lv_idx).total_mb;
               lrec_drive (lv_inst_idx).recovery_free :=
                                               p_dest (lv_idx).usable_file_mb;
               lrec_drive (lv_inst_idx).number_recovery := 1;
               lrec_drive (lv_inst_idx).number_ttf :=
                              NVL (lrec_drive (lv_inst_idx).number_ttf, 0)
                              + 1;
               lv_count_recov := 1;
            ELSE
               lrec_drive (lv_inst_idx).total_space :=
                                                     p_dest (lv_idx).total_mb;
               lrec_drive (lv_inst_idx).free_space :=
                                               p_dest (lv_idx).usable_file_mb;
               lrec_drive (lv_inst_idx).number_ttf :=
                              NVL (lrec_drive (lv_inst_idx).number_ttf, 0)
                              + 1;
            END IF;

            lrec_drive (lv_inst_idx).instance_name :=
                                                 p_dest (lv_idx).instance_name;
            lv_idx := larr_unique (lv_unique).NEXT (lv_idx);
         END LOOP;

         IF lrec_drive.COUNT = 1
         THEN
            -- Location is specific to instance. Calculate based on single instance parameter
            -- Using archive log information from flow rates
            lv_inst_idx := lrec_drive.FIRST;

            IF ar2_arc_summary_rec (lv_inst_idx).COUNT <= 5 THEN
                lrec_drive(lv_inst_idx).message := gc_not_enough_hist;
            ELSE
                IF lrec_drive (lv_inst_idx).recovery_free IS NOT NULL
                THEN
                   lrec_drive (lv_inst_idx).recovery_ttf :=
                      calculate_ttf (ar2_arc_summary_rec (lv_inst_idx),
                                     lrec_drive(lv_inst_idx).total_space,
                                     lrec_drive (lv_inst_idx).recovery_free,
                                     1
                                    );
                   IF lv_inst_idx = lv_local_inst THEN
                        lrec_drive(lv_inst_idx).local_recov_ttf := lrec_drive (lv_inst_idx).recovery_ttf;
                   END IF;
                END IF;

                IF lrec_drive (lv_inst_idx).total_space IS NOT NULL
                THEN
                   lrec_drive (lv_inst_idx).space_ttf :=
                      calculate_ttf (ar2_arc_summary_rec (lv_inst_idx),
                                     lrec_drive(lv_inst_idx).total_space,
                                     lrec_drive (lv_inst_idx).free_space,
                                     lrec_drive (lv_inst_idx).number_ttf
                                    );

                   IF lv_inst_idx = lv_local_inst THEN
                    lrec_drive(lv_inst_idx).local_ttf := lrec_drive (lv_inst_idx).space_ttf;
                   END IF;
                END IF;
            END IF;
         ELSE
            lv_inst_idx := lrec_drive.FIRST;
            lv_count := 0;

            lv_recov_ttf := NULL;
            lv_inst_idx := lrec_drive.FIRST;

            IF lv_count_recov > 0
            THEN
               -- Merge entries from the instances into one and calculate TTF from that
               lrec_summary := merge_dest_entries (lrec_drive, 1);
               -- Calculate recovery also
               lv_recov_ttf :=
                  calculate_ttf (lrec_summary,
                                 lrec_drive(lv_inst_idx).total_space,
                                 lrec_drive (lv_inst_idx).recovery_free,
                                 1
                                );
            END IF;

            -- Merge entries from the instances into one and calculate TTF from that
            lrec_summary := merge_dest_entries (lrec_drive);
            lv_ttf :=
               calculate_ttf (lrec_summary,
                              lrec_drive(lv_inst_idx).total_space,
                              lrec_drive (lv_inst_idx).free_space,
                              1
                             );

            IF lrec_drive.EXISTS(lv_local_inst) THEN
                IF lrec_drive(lv_local_inst).recovery_free IS NOT NULL THEN
                    IF ar2_arc_summary_rec (lv_local_inst).COUNT <= 5 THEN
                        lrec_drive(lv_local_inst).message := gc_not_enough_hist;
                    ELSE
                        lrec_drive(lv_local_inst).local_recov_ttf :=
                            calculate_ttf (ar2_arc_summary_rec (lv_local_inst),
                                           lrec_drive(lv_local_inst).total_space,
                                           lrec_drive (lv_local_inst).recovery_free,
                                           1
                                           );
                    END IF;
                END IF;

                IF lrec_drive(lv_local_inst).total_space IS NOT NULL THEN
                    IF ar2_arc_summary_rec(lv_local_inst).COUNT <= 5 THEN
                        lrec_drive(lv_local_inst).message := gc_not_enough_hist;
                    ELSE
                        lrec_drive(lv_local_inst).local_ttf :=
                                calculate_ttf(ar2_arc_summary_rec(lv_local_inst),
                                              lrec_drive(lv_local_inst).total_space,
                                              lrec_drive(lv_local_inst).free_space,
                                              lrec_drive(lv_local_inst).number_ttf);
                    END IF;
                END IF;
            END IF;

            WHILE lv_inst_idx IS NOT NULL
            LOOP
               lrec_drive (lv_inst_idx).space_ttf := lv_ttf;

               IF lv_recov_ttf IS NOT NULL
               THEN
                  lrec_drive (lv_inst_idx).recovery_ttf := lv_recov_ttf;
               END IF;

               IF ar2_arc_summary_rec(lv_inst_idx).COUNT <= 5 THEN
                    lrec_drive(lv_inst_idx).message := gc_not_enough_hist;
               END IF;

               lv_inst_idx := lrec_drive.NEXT (lv_inst_idx);
            END LOOP;
         END IF;

         lv_idx := larr_unique (lv_unique).FIRST;

         WHILE lv_idx IS NOT NULL
         LOOP
            lv_inst_idx :=
                         arr_inst_reverse_idx (p_dest (lv_idx).instance_name);

            IF p_dest (lv_idx).is_recovery = 'TRUE'
            THEN
               p_dest (lv_idx).time_to_failure :=
                                        lrec_drive (lv_inst_idx).recovery_ttf;
               IF lv_inst_idx = lv_local_inst THEN
                    p_dest(lv_idx).local_ttf := lrec_drive(lv_inst_idx).local_recov_ttf;
               END IF;
            ELSE
               p_dest (lv_idx).time_to_failure :=
                                           lrec_drive (lv_inst_idx).space_ttf;
               IF lv_inst_idx = lv_local_inst THEN
                    p_dest(lv_idx).LOCAL_ttf := lrec_drive(lv_inst_idx).local_ttf;
               END IF;
            END IF;

            IF p_dest(lv_idx).message IS NULL THEN
            	p_dest(lv_idx).message := lrec_drive(lv_inst_idx).message;
            END IF;

            lv_idx := larr_unique (lv_unique).NEXT (lv_idx);
         END LOOP;

         lv_unique := larr_unique.NEXT (lv_unique);
      -- Now calculate TTF
      END LOOP;
   END generate_ttf;

   FUNCTION build_list RETURN quest_soo_arc_dest_list_typ
   IS
      lrec_dest       typ_dest_rec_arr;
      lv_dest         VARCHAR2 (300);
      lv_idx          PLS_INTEGER;
      lv_drive_idx    PLS_INTEGER;
      lv_header_idx   PLS_INTEGER;
      lv_flash_recov  NUMBER(16,2);
      lv_display_all  BOOLEAN := TRUE;
      lv_dest_fail    NUMBER(1);
      lv_local_dest_fail NUMBER(1);
      lv_archiver_fail NUMBER(1);
      lv_local_arc_fail NUMBER(1);

      lnt             QUEST_SOO_ARC_DEST_LIST_TYP;
   BEGIN
      lv_idx := 1;
      quest_soo_tracing.add_debug(gc_package_name,'build_list', 100, 'Entering build_list');

      IF NOT gv_initialised THEN
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry',101, 'Not initialised');
        RETURN NEW quest_soo_arc_dest_list_typ();
      END IF;

      lv_flash_recov := 0;

      FOR inst_idx IN 1 .. arr_instance_rec.COUNT
      LOOP
         FOR idx IN 1 .. ar2_dest_rec (inst_idx).COUNT
         LOOP

            lv_header_idx := lv_idx;
            lv_idx := lv_idx + 1;
            lrec_dest (lv_header_idx) := ar2_dest_rec (inst_idx) (idx);

            IF SUBSTR (ar2_dest_rec (inst_idx) (idx).destination_end, 1, 1) =
                                                                          '+'
            THEN
               lv_dest := ar2_dest_rec (inst_idx) (idx).destination_end;
            ELSE
               lv_dest :=
                     arr_instance_rec (inst_idx).instance_name
                  || ':'
                  || ar2_dest_rec (inst_idx) (idx).destination_end;
            END IF;

            IF arr_drive_idx.EXISTS (lv_dest)
            THEN
               lv_drive_idx := arr_drive_idx (lv_dest);
               lrec_dest (lv_header_idx).sequence_num := lv_idx;
               lrec_dest (lv_header_idx).tree_depth := 1;
               lrec_dest(lv_header_idx).message := arr_drive_rec(lv_drive_idx).message;
               IF upper(lrec_dest(lv_header_idx).destination) != 'USE_DB_RECOVERY_FILE_DEST'
               THEN
                   lrec_dest (lv_header_idx).total_mb :=
                                        arr_drive_rec (lv_drive_idx).total_space;
                   lrec_dest (lv_header_idx).free_mb :=
                                        arr_drive_rec (lv_drive_idx).free_space;
                   lrec_dest (lv_header_idx).usable_file_mb :=
                                        arr_drive_rec (lv_drive_idx).usable_space;
               ELSIF arr_drive_rec(lv_drive_idx).total_space > 0
               THEN
                   lrec_dest (lv_header_idx).free_mb := LEAST(lrec_dest (lv_header_idx).free_mb,
                                          arr_drive_rec (lv_drive_idx).free_space);
                   lrec_dest (lv_header_idx).usable_file_mb := LEAST(lrec_dest (lv_header_idx).usable_file_mb,
                                        arr_drive_rec (lv_drive_idx).usable_space);

               END IF;
               lrec_dest (lv_header_idx).time_to_failure :=
                                ar2_dest_rec (inst_idx) (idx).time_to_failure;
            ELSE
                lv_display_all := FALSE;
                quest_soo_tracing.add_debug(gc_package_name,'dest_entry',103, 'Destination ' || lrec_dest(lv_header_idx).instance_name || '.' ||
                                    lrec_dest(lv_header_idx).dest_name || ' for dest_end ' || lv_dest || ' does not exist in drive details');
            END IF;
           IF lrec_dest(lv_header_idx).destination = 'USE_DB_RECOVERY_FILE_DEST' THEN
               IF lv_flash_recov = 0 THEN
                  lv_flash_recov := NVL(get_flash_recov, 0);
               END IF;
               lrec_dest(lv_header_idx).usable_file_mb := NVL(lrec_dest(lv_header_idx).usable_file_mb, 0) +
                                                            lv_flash_recov +
                                                            lrec_dest(lv_header_idx).reclaimable_mb;
           END IF;
         END LOOP;
      END LOOP;

      quest_soo_tracing.add_debug(gc_package_name,'dest_entry', 110, 'Have drive details');

      FOR idx IN 1 .. lrec_dest.COUNT
      LOOP
         lrec_dest (idx).sequence_num := idx;
      END LOOP;


      IF gv_archivelog THEN
         quest_soo_tracing.add_debug(gc_package_name,'dest_entry', 111, 'Generate ttf');
         generate_ttf (lrec_dest);
         quest_soo_tracing.add_debug(gc_package_name,'dest_entry', 112, 'Find min rec');
         find_min_rec (lrec_dest);
      ELSE
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry', 113, 'Find min space');
         find_min_space_rec(lrec_dest);
      END IF;

      lnt := NEW quest_soo_arc_dest_list_typ();

      IF NOT lv_display_all THEN
        quest_soo_tracing.add_debug(gc_package_name,'dest_entry', 104, 'Not all exist so return');
        RETURN lnt;
      END IF;

      lnt.extend(lrec_dest.COUNT);

      FOR idx in 1..lrec_dest.COUNT LOOP

         IF lrec_dest(idx).total_mb = 0 THEN
            lrec_dest(idx).total_mb := NULL;
            lrec_dest(idx).free_mb := NULL;
            lrec_dest(idx).usable_file_mb := NULL;
         end IF;

         IF lrec_dest(idx).usable_file_mb < 0 AND lrec_dest(idx).error IS NULL THEN
            lrec_dest(idx).error := 'Negative usable space. Time-to-failure not calculated';
         end if;

         quest_soo_tracing.add_debug(gc_package_name,'dest_entry',105,
                                     lrec_dest(idx).instance_name || '.' ||
                                     lrec_dest(idx).dest_name || ':' ||
                                     lrec_dest(idx).total_mb || ':' ||
                                     lrec_dest(idx).free_mb || ':' ||
                                     lrec_dest(idx).usable_file_mb || ':' ||
                                     lrec_dest(idx).time_to_failure || ':' ||
                                     lrec_dest(idx).local_ttf || ':' ||
                                     lrec_dest(idx).error || ':' ||
                                     lrec_dest(idx).message);

         lv_dest_fail    := NULL;
         lv_local_dest_fail := NULL;
         lv_archiver_fail := NULL;
         lv_local_arc_fail := NULL;

         IF lrec_dest(idx).status = 'ERROR' THEN
            lv_dest_fail := 0;
            IF lrec_dest(idx).instance_name = gv_instance_name THEN
                lv_local_dest_fail := 0;
            END IF;
         END IF;

         IF lrec_dest(idx).archiver_status = 'FAILED' THEN
            lv_archiver_fail := 0;
            IF lrec_dest(idx).instance_name = gv_instance_name THEN
                lv_local_arc_fail := 0;
            END IF;
         END IF;

         lnt(idx) := quest_soo_archive_dest_typ(lrec_dest(idx).sequence_num,
                                                 lrec_dest(idx).dest_name,
                                                 lrec_dest(idx).status,
                                                 lrec_dest(idx).target,
                                                 lrec_dest(idx).destination,
                                                 lrec_dest(idx).destination_end,
                                                 lrec_dest(idx).binding,
                                                 lrec_dest(idx).log_sequence,
                                                 lrec_dest(idx).reopen_secs,
                                                 lrec_dest(idx).transmit_mode,
                                                 lrec_dest(idx).TYPE,
                                                 lrec_dest(idx).valid_type,
                                                 lrec_dest(idx).total_mb,
                                                 lrec_dest(idx).free_mb,
                                                 lrec_dest(idx).usable_file_mb,
                                                 lrec_dest(idx).is_asm,
                                                 lrec_dest(idx).is_recovery,
                                                 lrec_dest(idx).min_record,
                                                 lrec_dest(idx).time_to_failure,
                                                 lrec_dest(idx).instance_name,
                                                 lrec_dest(idx).local_ttf,
                                                 lrec_dest(idx).local_min_rec,
                                                 lrec_dest(idx).error,
                                                 lrec_dest(idx).message,
                                                 lrec_dest(idx).archiver_status,
                                                 lv_dest_fail,
                                                 lv_local_dest_fail,
                                                 lv_archiver_fail,
                                                 lv_local_arc_fail,
                                                 gv_instance_name);
      END LOOP;

      RETURN lnt;

   END build_list;
END quest_soo_archivelog;
/
