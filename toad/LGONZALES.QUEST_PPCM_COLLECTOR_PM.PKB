CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_ppcm_collector_pm
IS
   g_memory_usage_id    NUMBER;

   TYPE rc is REF CURSOR;

   /*
     This function will determine if an SQL ID already exists for the given SQL, or if one does not exist, then create one
   */

   FUNCTION get_custom_sql_id (i_custom_sql_type   IN VARCHAR2,
                               i_sql_text          IN VARCHAR2,
                               i_custom_sql_name   IN VARCHAR2)
      RETURN NUMBER
   IS
      l_custom_sql_id       NUMBER;
      l_custom_sql_result   NUMBER;
   BEGIN
      /* Make sure a custom sql type and sql text have been passed, otherwise return null */
      IF i_custom_sql_type IS NOT NULL AND i_sql_text IS NOT NULL
      THEN
         BEGIN
            /* Get the custom sql ID for this SQL - if it is not found this will raise the no_data_found exception */
            SELECT   custom_sql_id
              INTO   l_custom_sql_id
              FROM   quest_ppcm_custom_sql
             WHERE   custom_sql_type = i_custom_sql_type
                     AND sql_text = i_sql_text;

            /* If an ID is found then update the SQL name to the newly entered name */
            UPDATE   quest_ppcm_custom_sql
               SET   custom_sql_name = i_custom_sql_name
             WHERE   custom_sql_id = l_custom_sql_id;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               /* When no data is found - this is a new SQL, so run it to make sure it is valid */
               l_custom_sql_result :=
                  quest_ppcm_collector_pm.run_custom_sql (i_sql_text);

               /* Lock the table so we can find the next number for the SQL ID */
               EXECUTE IMMEDIATE 'lock table quest_ppcm_custom_sql in exclusive mode';

               /* Get the next SQL ID */
               SELECT   NVL (MAX (custom_sql_id), 0) + 1
                 INTO   l_custom_sql_id
                 FROM   quest_ppcm_custom_sql;

               /* Insert the new SQL - automatically set the apply indicator to Y */
               INSERT INTO quest_ppcm_custom_sql (custom_sql_id,
                                                  custom_sql_type,
                                                  sql_text,
                                                  custom_sql_name,
                                                  apply_ind,
                                                  last_execution_date,
                                                  last_execution_error)
                 VALUES   (l_custom_sql_id,
                           i_custom_sql_type,
                           i_sql_text,
                           i_custom_sql_name,
                           'Y',
                           NULL,
                           NULL);
         END;

         /* Return either the newly created custom SQL ID, or the existing one */
         RETURN l_custom_sql_id;
      ELSE
         RETURN NULL;
      END IF;
   END get_custom_sql_id;

   /*
     This procedure will return the attributes for a custom SQL given a custom sql type - it will get the one that currently applies
   */

   PROCEDURE get_custom_sql (
      i_custom_sql_type   IN     quest_ppcm_custom_sql.custom_sql_type%TYPE,
      o_custom_sql_id        OUT quest_ppcm_custom_sql.custom_sql_id%TYPE,
      o_sql_text             OUT quest_ppcm_custom_sql.sql_text%TYPE,
      o_custom_sql_name      OUT quest_ppcm_custom_sql.custom_sql_name%TYPE
   )
   IS
   BEGIN
      /* Get the custom sql ID from the parameter */
      o_custom_sql_id :=
         quest_ppcm_collector.get_ppcm_parameter (i_custom_sql_type);

      IF o_custom_sql_id IS NOT NULL
      THEN
         /* If the custom sql ID exists, then get the sql text and the sql name */
         BEGIN
            SELECT   sql_text, custom_sql_name
              INTO   o_sql_text, o_custom_sql_name
              FROM   quest_ppcm_custom_sql
             WHERE   custom_sql_id = o_custom_sql_id;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               o_custom_sql_id := NULL;
         END;
      END IF;
   END get_custom_sql;

   PROCEDURE get_custom_concurrency (o_custom_sql_id       OUT NUMBER,
                                     o_custom_sql_result   OUT NUMBER)
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      l_custom_sql        VARCHAR2 (4000);
      l_error_msg         VARCHAR2 (512);
      l_custom_sql_name   VARCHAR2 (128);
   BEGIN
      /* Get the custom SQL ID and text the user has entered. If one is not configured this will return null */
      get_custom_sql ('PM_CUSTOM_CONCURRENCY',
                      o_custom_sql_id,
                      l_custom_sql,
                      l_custom_sql_name);

      /* Run the custom SQL if it is configured and return the value, if it was not configured return null */
      IF l_custom_sql IS NOT NULL
      THEN
         BEGIN
            o_custom_sql_result := run_custom_sql (l_custom_sql);

            UPDATE   quest_ppcm_custom_sql
               SET   last_execution_date = SYSDATE,
                     last_execution_error = NULL
             WHERE   custom_sql_id = o_custom_sql_id;
         EXCEPTION
            WHEN OTHERS
            THEN
               l_error_msg := SQLERRM;

               UPDATE   quest_ppcm_custom_sql
                  SET   last_execution_date = SYSDATE,
                        last_execution_error = l_error_msg
                WHERE   custom_sql_id = o_custom_sql_id;

               COMMIT;
               RAISE;
         END;
      ELSE
         o_custom_sql_id := NULL;
         o_custom_sql_result := NULL;
      END IF;

      COMMIT;
   END get_custom_concurrency;

   /*
     Snapshot statistics and calculate deltas and rates
   */

   PROCEDURE snap_statistic (
      i_cur_snapshot    IN quest_ppcm_snapshot%ROWTYPE,
      i_prev_snapshot   IN quest_ppcm_snapshot%ROWTYPE
   )
   IS
      TYPE typ_statistic_snap_prev IS RECORD (
                                         statistic_id      NUMBER,
                                         raw_value         NUMBER,
                                         cumulative_flag   NUMBER
                                      );

      TYPE typ_statistic_snap_prev_rows
      IS
         TABLE OF typ_statistic_snap_prev
            INDEX BY PLS_INTEGER;

      TYPE typ_statistic_snap_cur
      IS
         RECORD (statistic_id NUMBER, raw_value   NUMBER);

      TYPE typ_statistic_snap_cur_rows
      IS
         TABLE OF typ_statistic_snap_cur
            INDEX BY PLS_INTEGER;

      TYPE typ_statistic_snap_rows
      IS
         TABLE OF quest_ppcm_statistic_snap%ROWTYPE
            INDEX BY PLS_INTEGER;

      TYPE typ_statistic_name
      IS
         RECORD (statistic_id  NUMBER, statistic_name VARCHAR2 (100));

      TYPE typ_statistic_name_rows
      IS
         TABLE OF typ_statistic_name
            INDEX BY PLS_INTEGER;

      l_prev_statistic_snap_res       typ_statistic_snap_prev_rows;
      l_cur_statistic_snap_res        typ_statistic_snap_cur_rows;
      l_cur_statistic_snap_names      typ_statistic_name_rows;
      l_prev_statistic_snap           typ_statistic_snap_prev_rows;
      l_cur_statistic_snap            typ_statistic_snap_rows;
      l_cur_statistic_snap_iterator   PLS_INTEGER := 0;

      cur_statistic_snap rc;

      str_cur_statistic_snap VARCHAR2(512) :=
              'SELECT pst.statistic_id, psts.raw_value, pst.cumulative_flag
               FROM   quest_ppcm_statistic_snap psts, quest_ppcm_statistic pst
               WHERE  psts.snapshot_id = :prev_snapshot_id
                       AND pst.statistic_id = psts.statistic_id';


      cur_sysstat rc;
      str_cur_sysstat VARCHAR2(512) :=
               'SELECT pst.statistic_id, ss.VALUE
                FROM   quest_ppcm_statistic pst, v$sysstat ss
                WHERE  ss.name = pst.statistic_name
                       AND pst.statistic_source = ''V$SYSSTAT''';

      cur_sys_time_model  rc;
      str_cur_sys_time_model  VARCHAR2(512) :=
               'SELECT pst.statistic_id, stm.VALUE
                FROM   v$sys_time_model stm, quest_ppcm_statistic pst
                WHERE  pst.statistic_source = ''V$SYS_TIME_MODEL''
                       AND pst.statistic_name = stm.stat_name';

      cur_osstat rc;
      str_cur_osstat VARCHAR2(512) :=
               'SELECT pst.statistic_id, os.VALUE
                FROM   quest_ppcm_statistic pst, v$osstat os
                WHERE  os.stat_name = pst.statistic_name
                       AND pst.statistic_source = ''V$OSSTAT''';

      cur_sgastat rc;
      str_cur_sgastat VARCHAR2(4000) :=
         'SELECT   statistic_id, NVL (bytes, 0) bytes
           FROM   (SELECT   statistic_id,
                            pool,
                            name,
                            CASE
                               WHEN pool IS NULL AND name IS NULL
                               THEN
                                  SUM(CASE
                                         WHEN statistic_id IS NULL THEN bytes
                                      END)
                                     OVER ()
                               ELSE
                                  bytes
                            END
                               bytes
                     FROM   (  SELECT   MAX (ps.statistic_id) statistic_id,
                                        NVL (ps.pool, sga.pool) pool,
                                        CASE
                                           WHEN ps.statistic_id IS NULL
                                                AND sga.pool IS NOT NULL
                                           THEN
                                              NULL
                                           ELSE
                                              NVL (ps.name, sga.name)
                                        END
                                           name,
                                        SUM (sga.bytes) bytes
                                 FROM      (SELECT   ps.statistic_id,
                                                     SUBSTR (
                                                        ps.statistic_name,
                                                        1,
                                                        INSTR (
                                                           ps.statistic_name,
                                                           ''/''
                                                        )
                                                        - 1
                                                     )
                                                        pool,
                                                     SUBSTR (
                                                        ps.statistic_name,
                                                        INSTR (
                                                           ps.statistic_name,
                                                           ''/''
                                                        )
                                                        + 1
                                                     )
                                                        name
                                              FROM   quest_ppcm_statistic ps
                                             WHERE   ps.statistic_source =
                                                        ''V$SGASTAT'') ps
                                        FULL OUTER JOIN
                                           v$sgastat sga
                                        ON (ps.pool = sga.pool
                                            AND ps.name = sga.name)
                             GROUP BY   NVL (ps.pool, sga.pool),
                                        CASE
                                           WHEN ps.statistic_id IS NULL
                                                AND sga.pool IS NOT NULL
                                           THEN
                                              NULL
                                           ELSE
                                              NVL (ps.name, sga.name)
                                        END))
          WHERE   statistic_id IS NOT NULL';

      cur_pgastat rc;
      str_cur_pgastat VARCHAR2(512) :=
         'SELECT   pst.statistic_id, pga.VALUE
           FROM   quest_ppcm_statistic pst, v$pgastat pga
          WHERE   pst.statistic_source = ''V$PGASTAT''
                  AND pga.name = pst.statistic_name';

      cur_quest_ppcm_collector_pm rc;
      s_cur_quest_ppcm_collector_pm VARCHAR2(512) :=
            'SELECT   pst.statistic_id, pst.statistic_name
                FROM   quest_ppcm_statistic pst
                WHERE   pst.statistic_source = ''QUEST_PPCM_COLLECTOR_PM''';

      /*
        Move the statistic snapshot from the temporary result set into the list of statistics to be saved
      */

      PROCEDURE move_statistic_snap_vals
      IS
      BEGIN
         FOR i IN 1 .. l_cur_statistic_snap_res.COUNT
         LOOP
            l_cur_statistic_snap_iterator := l_cur_statistic_snap_iterator + 1;
            l_cur_statistic_snap (l_cur_statistic_snap_iterator).statistic_id :=
               l_cur_statistic_snap_res (i).statistic_id;
            l_cur_statistic_snap (l_cur_statistic_snap_iterator).raw_value :=
               l_cur_statistic_snap_res (i).raw_value;
         END LOOP;

         l_cur_statistic_snap_res.delete;
      END;
   BEGIN
      /* Get statistics from the previous snapshot and put them into a collection indexed by statistic ID to be referenced later */
      OPEN cur_statistic_snap FOR str_cur_statistic_snap USING i_prev_snapshot.snapshot_id;

      LOOP
         FETCH cur_statistic_snap
            BULK COLLECT INTO   l_prev_statistic_snap_res
            LIMIT 25;

         EXIT WHEN l_prev_statistic_snap_res.COUNT = 0;

         FOR i IN 1 .. l_prev_statistic_snap_res.COUNT
         LOOP
            l_prev_statistic_snap (
               l_prev_statistic_snap_res (i).statistic_id
            ) :=
               l_prev_statistic_snap_res (i);
         END LOOP;
      END LOOP;

      CLOSE cur_statistic_snap;

      /* Get values from v$sysstat */
      OPEN cur_sysstat for str_cur_sysstat;

      FETCH cur_sysstat BULK COLLECT INTO   l_cur_statistic_snap_res;

      CLOSE cur_sysstat;

      move_statistic_snap_vals;

      /* Get values from v$sys_time_model */

      OPEN cur_sys_time_model for str_cur_sys_time_model;

      FETCH cur_sys_time_model BULK COLLECT INTO   l_cur_statistic_snap_res;

      CLOSE cur_sys_time_model;

      move_statistic_snap_vals;

      /* Get values from v$osstat */

      OPEN cur_osstat for str_cur_osstat;

      FETCH cur_osstat BULK COLLECT INTO   l_cur_statistic_snap_res;

      CLOSE cur_osstat;

      move_statistic_snap_vals;

      /* Get values from v$sgastat */

      OPEN cur_sgastat for str_cur_sgastat;

      FETCH cur_sgastat BULK COLLECT INTO   l_cur_statistic_snap_res;

      CLOSE cur_sgastat;

      move_statistic_snap_vals;

      /* Get values from v$pgastat */

      OPEN cur_pgastat for str_cur_pgastat;

      FETCH cur_pgastat BULK COLLECT INTO   l_cur_statistic_snap_res;

      CLOSE cur_pgastat;

      move_statistic_snap_vals;

      /* Get values that should be collected by quest_ppcm_collector_pm - ie - this package */

      OPEN cur_quest_ppcm_collector_pm for s_cur_quest_ppcm_collector_pm;

      FETCH cur_quest_ppcm_collector_pm
         BULK COLLECT INTO   l_cur_statistic_snap_names;

      CLOSE cur_quest_ppcm_collector_pm;

      DECLARE
         l_custom_sql_result   NUMBER;
         l_custom_sql_id       NUMBER;
      BEGIN
         BEGIN
            get_custom_concurrency (l_custom_sql_id, l_custom_sql_result);
         EXCEPTION
            WHEN OTHERS
            THEN
               NULL;
         END;

         FOR i IN 1 .. l_cur_statistic_snap_names.COUNT
         LOOP
            DECLARE
               l_result   NUMBER;
            BEGIN
               IF l_cur_statistic_snap_names (i).statistic_name =
                     'CUSTOM_CONCURRENCY'
               THEN
                  l_result := l_custom_sql_result;
               ELSIF l_cur_statistic_snap_names (i).statistic_name = 'CUSTOM_CONCURRENCY_SQL_ID'
               THEN
                  l_result := l_custom_sql_id;
               END IF;

               IF l_result IS NOT NULL
               THEN
                  l_cur_statistic_snap_res (
                     l_cur_statistic_snap_res.COUNT + 1
                  ).statistic_id :=
                     l_cur_statistic_snap_names (i).statistic_id;
                  l_cur_statistic_snap_res (
                     l_cur_statistic_snap_res.COUNT
                  ).raw_value :=
                     l_result;
               END IF;
            EXCEPTION
               WHEN OTHERS
               THEN
                  NULL;
            END;
         END LOOP;
      END;

      move_statistic_snap_vals;



      /* Loop through the statistics to get the values from the previous snapshot in order to calculate the delta and the rate */
      FOR i IN 1 .. l_cur_statistic_snap.COUNT
      LOOP
         l_cur_statistic_snap (i).snapshot_id := i_cur_snapshot.snapshot_id;

         IF (l_prev_statistic_snap.EXISTS (
                l_cur_statistic_snap (i).statistic_id
             )
             AND l_prev_statistic_snap (
                   l_cur_statistic_snap (i).statistic_id
                ).cumulative_flag = 1)
         THEN
            l_cur_statistic_snap (i).delta_value :=
               l_cur_statistic_snap (i).raw_value
               - l_prev_statistic_snap (
                    l_cur_statistic_snap (i).statistic_id
                 ).raw_value;

            IF i_cur_snapshot.snapshot_duration > 0
            THEN
               l_cur_statistic_snap (i).rate_value :=
                  l_cur_statistic_snap (i).delta_value
                  / i_cur_snapshot.snapshot_duration;
            END IF;
         END IF;
      END LOOP;

      /* Insert the statistics into quest_ppcm_statistic_snap */
      FORALL indx IN INDICES OF l_cur_statistic_snap
         INSERT INTO quest_ppcm_statistic_snap
           VALUES   l_cur_statistic_snap (indx);
   END snap_statistic;

   /*
     Snapshot IO statistics and calculate deltas and rates
   */

   PROCEDURE snap_iostat (i_cur_snapshot    IN quest_ppcm_snapshot%ROWTYPE,
                          i_prev_snapshot   IN quest_ppcm_snapshot%ROWTYPE)
   IS
      TYPE typ_iostat_snap_prev
      IS
         RECORD (
            iostat_id                 NUMBER,
            small_read_megabytes      NUMBER,
            small_write_megabytes     NUMBER,
            large_read_megabytes      NUMBER,
            large_write_megabytes     NUMBER,
            small_read_reqs           NUMBER,
            small_write_reqs          NUMBER,
            small_sync_read_reqs      NUMBER,
            large_read_reqs           NUMBER,
            large_write_reqs          NUMBER,
            small_read_servicetime    NUMBER,
            small_write_servicetime   NUMBER,
            small_sync_read_latency   NUMBER,
            large_read_servicetime    NUMBER,
            large_write_servicetime   NUMBER,
            retries_on_error          NUMBER,
            small_read_blocks         NUMBER,
            large_read_blocks         NUMBER,
            small_write_blocks        NUMBER,
            large_write_blocks        NUMBER
         );

      TYPE typ_iostat_snap_prev_rows
      IS
         TABLE OF typ_iostat_snap_prev
            INDEX BY PLS_INTEGER;

      TYPE typ_iostat_snap_rows
      IS
         TABLE OF quest_ppcm_iostat_snap%ROWTYPE
            INDEX BY PLS_INTEGER;

      l_prev_iostat_snap_res       typ_iostat_snap_prev_rows;
      l_prev_iostat_snap           typ_iostat_snap_prev_rows;

      l_cur_iostat_snap_res        typ_iostat_snap_prev_rows;
      l_cur_iostat_snap            typ_iostat_snap_rows;
      l_cur_iostat_snap_iterator   PLS_INTEGER := 0;


      cur_iostat_snap rc;
      str_cur_iostat_snap varchar2(2000) :=
         'SELECT   iostat_id,
                  small_read_megabytes,
                  small_write_megabytes,
                  large_read_megabytes,
                  large_write_megabytes,
                  small_read_reqs,
                  small_write_reqs,
                  small_sync_read_reqs,
                  large_read_reqs,
                  large_write_reqs,
                  small_read_servicetime,
                  small_write_servicetime,
                  small_sync_read_latency,
                  large_read_servicetime,
                  large_write_servicetime,
                  retries_on_error,
                  small_read_blocks,
                  large_read_blocks,
                  small_write_blocks,
                  large_write_blocks
           FROM   quest_ppcm_iostat_snap
          WHERE   snapshot_id = :prev_snapshot_id';

      /* Define the cursor for IO statistics, in 10g this is based on v$filestat and v$tempstat, in 11g this is based off v$iostat_file */


      cur_iostat rc;
      str_cur_iostat varchar2(5000) :=
          'SELECT   pio.iostat_id,
                    SUM (iof.small_read_megabytes) small_read_megabytes,
                    SUM (iof.small_write_megabytes) small_write_megabytes,
                    SUM (iof.large_read_megabytes) large_read_megabytes,
                    SUM (iof.large_write_megabytes) large_write_megabytes,
                    SUM (iof.small_read_reqs) small_read_reqs,
                    SUM (iof.small_write_reqs) small_write_reqs,
                    SUM (iof.small_sync_read_reqs) small_sync_read_reqs,
                    SUM (iof.large_read_reqs) large_read_reqs,
                    SUM (iof.large_write_reqs) large_write_reqs,
                    SUM (iof.small_read_servicetime) small_read_servicetime,
                    SUM (iof.small_write_servicetime) small_write_servicetime,
                    SUM (iof.small_sync_read_latency) small_sync_read_latency,
                    SUM (iof.large_read_servicetime) large_read_servicetime,
                    SUM (iof.large_write_servicetime) large_write_servicetime,
                    SUM (iof.retries_on_error) retries_on_error,
                    SUM (
                       (iof.small_read_megabytes * 1024 * 1024) / t.block_size
                    )
                       small_read_blocks,
                    SUM (
                       (iof.large_read_megabytes * 1024 * 1024) / t.block_size
                    )
                       large_read_blocks,
                    SUM (
                       (iof.small_write_megabytes * 1024 * 1024) / t.block_size
                    )
                       small_write_blocks,
                    SUM (
                       (iof.large_write_megabytes * 1024 * 1024) / t.block_size
                    )
                       large_write_blocks
             FROM   v$iostat_file iof,
                    quest_ppcm_iostat pio,
                    dba_data_files df,
                    dba_tablespaces t
            WHERE       pio.iostat_source = ''V$IOSTAT_FILE''
                    AND pio.iostat_name = iof.filetype_name
                    AND pio.iostat_name = ''Data File''
                    AND df.file_id = iof.file_no
                    AND t.tablespace_name = df.tablespace_name
         GROUP BY   pio.iostat_id
         UNION ALL
           SELECT   pio.iostat_id,
                    SUM (iof.small_read_megabytes) small_read_megabytes,
                    SUM (iof.small_write_megabytes) small_write_megabytes,
                    SUM (iof.large_read_megabytes) large_read_megabytes,
                    SUM (iof.large_write_megabytes) large_write_megabytes,
                    SUM (iof.small_read_reqs) small_read_reqs,
                    SUM (iof.small_write_reqs) small_write_reqs,
                    SUM (iof.small_sync_read_reqs) small_sync_read_reqs,
                    SUM (iof.large_read_reqs) large_read_reqs,
                    SUM (iof.large_write_reqs) large_write_reqs,
                    SUM (iof.small_read_servicetime) small_read_servicetime,
                    SUM (iof.small_write_servicetime) small_write_servicetime,
                    SUM (iof.small_sync_read_latency) small_sync_read_latency,
                    SUM (iof.large_read_servicetime) large_read_servicetime,
                    SUM (iof.large_write_servicetime) large_write_servicetime,
                    SUM (iof.retries_on_error) retries_on_error,
                    SUM (
                       (iof.small_read_megabytes * 1024 * 1024) / t.block_size
                    )
                       small_read_blocks,
                    SUM (
                       (iof.large_read_megabytes * 1024 * 1024) / t.block_size
                    )
                       large_read_blocks,
                    SUM (
                       (iof.small_write_megabytes * 1024 * 1024) / t.block_size
                    )
                       small_write_blocks,
                    SUM (
                       (iof.large_write_megabytes * 1024 * 1024) / t.block_size
                    )
                       large_write_blocks
             FROM   v$iostat_file iof,
                    quest_ppcm_iostat pio,
                    dba_temp_files tf,
                    dba_tablespaces t
            WHERE       pio.iostat_source = ''V$IOSTAT_FILE''
                    AND pio.iostat_name = iof.filetype_name
                    AND pio.iostat_name = ''Temp File''
                    AND tf.file_id = iof.file_no
                    AND t.tablespace_name = tf.tablespace_name
         GROUP BY   pio.iostat_id';

      /*
        Move IO statistic snapshot from the temporary result set into the list of IO statistics to be saved and calculate the deltas and rates
      */

      PROCEDURE move_iostat_snap_vals
      IS
      BEGIN
         FOR i IN 1 .. l_cur_iostat_snap_res.COUNT
         LOOP
            l_cur_iostat_snap_iterator := l_cur_iostat_snap_iterator + 1;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).snapshot_id :=
               i_cur_snapshot.snapshot_id;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).iostat_id :=
               l_cur_iostat_snap_res (i).iostat_id;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_read_megabytes :=
               l_cur_iostat_snap_res (i).small_read_megabytes;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_write_megabytes :=
               l_cur_iostat_snap_res (i).small_write_megabytes;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).large_read_megabytes :=
               l_cur_iostat_snap_res (i).large_read_megabytes;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).large_write_megabytes :=
               l_cur_iostat_snap_res (i).large_write_megabytes;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).small_read_reqs :=
               l_cur_iostat_snap_res (i).small_read_reqs;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).small_write_reqs :=
               l_cur_iostat_snap_res (i).small_write_reqs;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_sync_read_reqs :=
               l_cur_iostat_snap_res (i).small_sync_read_reqs;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).large_read_reqs :=
               l_cur_iostat_snap_res (i).large_read_reqs;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).large_write_reqs :=
               l_cur_iostat_snap_res (i).large_write_reqs;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_read_servicetime :=
               l_cur_iostat_snap_res (i).small_read_servicetime;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_write_servicetime :=
               l_cur_iostat_snap_res (i).small_write_servicetime;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).small_sync_read_latency :=
               l_cur_iostat_snap_res (i).small_sync_read_latency;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).large_read_servicetime :=
               l_cur_iostat_snap_res (i).large_read_servicetime;
            l_cur_iostat_snap (
               l_cur_iostat_snap_iterator
            ).large_write_servicetime :=
               l_cur_iostat_snap_res (i).large_write_servicetime;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).retries_on_error :=
               l_cur_iostat_snap_res (i).retries_on_error;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).small_read_blocks :=
               l_cur_iostat_snap_res (i).small_read_blocks;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).large_read_blocks :=
               l_cur_iostat_snap_res (i).large_read_blocks;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).small_write_blocks :=
               l_cur_iostat_snap_res (i).small_write_blocks;
            l_cur_iostat_snap (l_cur_iostat_snap_iterator).large_write_blocks :=
               l_cur_iostat_snap_res (i).large_write_blocks;

            IF i_cur_snapshot.db_restart_flag = 0
               AND i_cur_snapshot.snapshot_duration <> 0
               AND l_prev_iostat_snap.EXISTS (
                     l_cur_iostat_snap_res (i).iostat_id
                  )
            THEN
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_read_megabytes_rate :=
                  (l_cur_iostat_snap_res (i).small_read_megabytes
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_read_megabytes)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_write_megabytes_rate :=
                  (l_cur_iostat_snap_res (i).small_write_megabytes
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_write_megabytes)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_read_megabytes_rate :=
                  (l_cur_iostat_snap_res (i).large_read_megabytes
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_read_megabytes)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_write_megabytes_rate :=
                  (l_cur_iostat_snap_res (i).large_write_megabytes
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_write_megabytes)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_read_reqs_rate :=
                  (l_cur_iostat_snap_res (i).small_read_reqs
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_read_reqs)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_write_reqs_rate :=
                  (l_cur_iostat_snap_res (i).small_write_reqs
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_write_reqs)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_sync_read_reqs_rate :=
                  (l_cur_iostat_snap_res (i).small_sync_read_reqs
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_sync_read_reqs)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_read_reqs_rate :=
                  (l_cur_iostat_snap_res (i).large_read_reqs
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_read_reqs)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_write_reqs_rate :=
                  (l_cur_iostat_snap_res (i).large_write_reqs
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_write_reqs)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_read_servicetime_rate :=
                  (l_cur_iostat_snap_res (i).small_read_servicetime
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_read_servicetime)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_write_servicetime_rate :=
                  (l_cur_iostat_snap_res (i).small_write_servicetime
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_write_servicetime)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_sync_read_latency_rate :=
                  (l_cur_iostat_snap_res (i).small_sync_read_latency
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_sync_read_latency)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_read_servicetime_rate :=
                  (l_cur_iostat_snap_res (i).large_read_servicetime
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_read_servicetime)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_write_servicetime_rate :=
                  (l_cur_iostat_snap_res (i).large_write_servicetime
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_write_servicetime)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).retries_on_error_rate :=
                  (l_cur_iostat_snap_res (i).retries_on_error
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).retries_on_error)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_read_blocks_rate :=
                  (l_cur_iostat_snap_res (i).small_read_blocks
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_read_blocks)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_read_blocks_rate :=
                  (l_cur_iostat_snap_res (i).large_read_blocks
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_read_blocks)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).small_write_blocks_rate :=
                  (l_cur_iostat_snap_res (i).small_write_blocks
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).small_write_blocks)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_iostat_snap (
                  l_cur_iostat_snap_iterator
               ).large_write_blocks_rate :=
                  (l_cur_iostat_snap_res (i).large_write_blocks
                   - l_prev_iostat_snap (
                        l_cur_iostat_snap_res (i).iostat_id
                     ).large_write_blocks)
                  / i_cur_snapshot.snapshot_duration;
            END IF;
         END LOOP;
      END;
   BEGIN
      /* Get IO statistics from the previous snapshot and put them into a collection indexed by iostat ID to be referenced later */
      OPEN cur_iostat_snap for str_cur_iostat_snap USING i_prev_snapshot.snapshot_id;

      LOOP
         FETCH cur_iostat_snap
            BULK COLLECT INTO   l_prev_iostat_snap_res
            LIMIT 25;

         EXIT WHEN l_prev_iostat_snap_res.COUNT = 0;

         FOR i IN 1 .. l_prev_iostat_snap_res.COUNT
         LOOP
            l_prev_iostat_snap (l_prev_iostat_snap_res (i).iostat_id) :=
               l_prev_iostat_snap_res (i);
         END LOOP;
      END LOOP;

      CLOSE cur_iostat_snap;

      /* Get IO statistics from cursor defined above */
      OPEN cur_iostat for str_cur_iostat;

      FETCH cur_iostat BULK COLLECT INTO   l_cur_iostat_snap_res;

      CLOSE cur_iostat;

      move_iostat_snap_vals;

      /* Insert the statistics into quest_ppcm_iostat_snap */
      FORALL indx IN INDICES OF l_cur_iostat_snap
         INSERT INTO quest_ppcm_iostat_snap
           VALUES   l_cur_iostat_snap (indx);
   END snap_iostat;

   /*
     Snapshot memory advisories
   */

   PROCEDURE snap_advisory (i_cur_snapshot    IN quest_ppcm_snapshot%ROWTYPE,
                            i_prev_snapshot   IN quest_ppcm_snapshot%ROWTYPE)
   IS
      TYPE typ_advisory_snap_prev
      IS
         RECORD (
            advisory_id            NUMBER,
            memory_size_factor     NUMBER,
            memory_size            NUMBER,
            estd_time              NUMBER,
            estd_overalloc_count   NUMBER
         );

      TYPE typ_advisory_snap_prev_res_rw
      IS
         TABLE OF typ_advisory_snap_prev
            INDEX BY PLS_INTEGER;

      TYPE typ_advisory_snap_prev_rows
      IS
         TABLE OF typ_advisory_snap_prev
            INDEX BY VARCHAR2 (255);

      TYPE typ_advisory_rows
      IS
         TABLE OF quest_ppcm_advisory%ROWTYPE
            INDEX BY PLS_INTEGER;

      cur_advisory_snap rc;
      str_cur_advisory_snap VARCHAR2(512) :=
         'SELECT   advisory_id,
                  memory_size_factor,
                  memory_size,
                  estd_time,
                  estd_overalloc_count
           FROM   quest_ppcm_advisory_snap
          WHERE   snapshot_id = :prev_snapshot_id';

      cur_quest_ppcm_advisory rc;
      str_cur_quest_ppcm_advisory VARCHAR2(512) :=
         'SELECT   * FROM quest_ppcm_advisory';

      l_advisory_list                typ_advisory_rows;

      cur_db_cache_advice rc;
      str_cur_db_cache_advice VARCHAR2(512) :=
         'SELECT   dbca.name,
                  dbca.block_size,
                  dbca.size_factor,
                  dbca.size_for_estimate,
                  dbca.estd_physical_reads,
                  NULL
           FROM   v$db_cache_advice dbca';


      cur_pga_target_advice rc;
      str_cur_pga_target_advice varchar2(512) :=
         'SELECT   '' '',
                  0,
                  pga.pga_target_factor,
                  pga.pga_target_for_estimate / 1024 / 1024,
                  pga.estd_extra_bytes_rw,
                  pga.estd_overalloc_count
           FROM   v$pga_target_advice pga';

      TYPE typ_advisory_snap_cur
      IS
         RECORD (
            pool_name              VARCHAR2 (30),
            pool_block_size        NUMBER,
            memory_size_factor     NUMBER,
            memory_size            NUMBER,
            estd_time              NUMBER,
            estd_overalloc_count   NUMBER
         );

      TYPE typ_advisory_snap_cur_rows
      IS
         TABLE OF typ_advisory_snap_cur
            INDEX BY PLS_INTEGER;

      l_cur_advisory_snap_res        typ_advisory_snap_cur_rows;

      TYPE typ_advisory_snap_rows
      IS
         TABLE OF quest_ppcm_advisory_snap%ROWTYPE
            INDEX BY PLS_INTEGER;

      l_prev_advisory_snap_res       typ_advisory_snap_prev_res_rw;
      l_prev_advisory_snap           typ_advisory_snap_prev_rows;

      l_cur_advisory_snap            typ_advisory_snap_rows;
      l_cur_advisory_snap_iterator   PLS_INTEGER := 0;

      l_db_cache_advice              VARCHAR2 (4000);

      /* Get the advisory ID for a given combination of values. This loops through the cached array in memory to find the ID.
         If an ID cannot be found then one is generated and inserted into the table */

      FUNCTION get_advisory_id (i_advisory_source   IN VARCHAR2,
                                i_advisory_name     IN VARCHAR2,
                                i_pool_name         IN VARCHAR2,
                                i_pool_block_size   IN NUMBER)
         RETURN NUMBER
      IS
         l_advisory_list_cnt   PLS_INTEGER;
         l_max_advisory_id     NUMBER := 0;
         l_new_advisory_row    quest_ppcm_advisory%ROWTYPE;
      BEGIN
         l_advisory_list_cnt := l_advisory_list.COUNT;

         FOR i IN 1 .. l_advisory_list_cnt
         LOOP
            /* Find the maximum advisory ID so if the loop cannot find one, we know what the next ID will be */
            IF l_max_advisory_id < l_advisory_list (i).advisory_id
            THEN
               l_max_advisory_id := l_advisory_list (i).advisory_id;
            END IF;

            /* If a match is found, then return the match */
            IF     l_advisory_list (i).advisory_source = i_advisory_source
               AND l_advisory_list (i).advisory_name = i_advisory_name
               AND l_advisory_list (i).pool_name = i_pool_name
               AND l_advisory_list (i).pool_block_size = i_pool_block_size
            THEN
               RETURN l_advisory_list (i).advisory_id;
            END IF;
         END LOOP;

         /* If it gets to here then no match was found, so setup a record with the new values */
         l_new_advisory_row.advisory_id := l_max_advisory_id + 1;
         l_new_advisory_row.advisory_source := i_advisory_source;
         l_new_advisory_row.advisory_name := i_advisory_name;
         l_new_advisory_row.pool_name := i_pool_name;
         l_new_advisory_row.pool_block_size := i_pool_block_size;

         /* Insert this advisory ID into the table and return it */
         INSERT INTO quest_ppcm_advisory
           VALUES   l_new_advisory_row;

         l_advisory_list (l_max_advisory_id + 1) := l_new_advisory_row;
         RETURN l_max_advisory_id + 1;
      END get_advisory_id;

      /*
        Move advisory snapshot from the temporary result set into the list of advisories to be saved
      */
      PROCEDURE move_advisory_snap_vals (i_advisory_name     IN VARCHAR2,
                                         i_advisory_source   IN VARCHAR2)
      IS
         l_prev_advisory_key   VARCHAR2 (255);
      BEGIN
         FOR i IN 1 .. l_cur_advisory_snap_res.COUNT
         LOOP
            l_cur_advisory_snap_iterator := l_cur_advisory_snap_iterator + 1;
            l_cur_advisory_snap (l_cur_advisory_snap_iterator).snapshot_id :=
               i_cur_snapshot.snapshot_id;
            l_cur_advisory_snap (l_cur_advisory_snap_iterator).advisory_id :=
               get_advisory_id (i_advisory_source,
                                i_advisory_name,
                                l_cur_advisory_snap_res (i).pool_name,
                                l_cur_advisory_snap_res (i).pool_block_size);
            l_cur_advisory_snap (
               l_cur_advisory_snap_iterator
            ).memory_size_factor :=
               l_cur_advisory_snap_res (i).memory_size_factor;
            l_cur_advisory_snap (l_cur_advisory_snap_iterator).memory_size :=
               l_cur_advisory_snap_res (i).memory_size;
            l_cur_advisory_snap (l_cur_advisory_snap_iterator).estd_time :=
               l_cur_advisory_snap_res (i).estd_time;
            l_cur_advisory_snap (
               l_cur_advisory_snap_iterator
            ).estd_overalloc_count :=
               l_cur_advisory_snap_res (i).estd_overalloc_count;
            l_prev_advisory_key :=
               TO_CHAR (
                  l_cur_advisory_snap (
                     l_cur_advisory_snap_iterator
                  ).advisory_id,
                  'TM'
               )
               || '/'
               || TO_CHAR (
                     l_cur_advisory_snap (
                        l_cur_advisory_snap_iterator
                     ).memory_size_factor,
                     'TM'
                  );

            IF     i_cur_snapshot.db_restart_flag = 0
               AND i_cur_snapshot.snapshot_duration <> 0
               AND l_prev_advisory_snap.EXISTS (l_prev_advisory_key)
               AND l_prev_advisory_snap (l_prev_advisory_key).memory_size =
                     l_cur_advisory_snap (
                        l_cur_advisory_snap_iterator
                     ).memory_size
            THEN
               l_cur_advisory_snap (
                  l_cur_advisory_snap_iterator
               ).estd_time_rate :=
                  (l_cur_advisory_snap (
                      l_cur_advisory_snap_iterator
                   ).estd_time
                   - l_prev_advisory_snap (l_prev_advisory_key).estd_time)
                  / i_cur_snapshot.snapshot_duration;
               l_cur_advisory_snap (
                  l_cur_advisory_snap_iterator
               ).estd_overalloc_count_rate :=
                  (l_cur_advisory_snap (
                      l_cur_advisory_snap_iterator
                   ).estd_overalloc_count
                   - l_prev_advisory_snap (
                        l_prev_advisory_key
                     ).estd_overalloc_count)
                  / i_cur_snapshot.snapshot_duration;
            END IF;
         END LOOP;
      END;
   BEGIN
      /* Get advisory statistics from the previous snapshot and put them into a collection indexed by advisory ID /  to be referenced later */
      OPEN cur_advisory_snap for str_cur_advisory_snap USING i_prev_snapshot.snapshot_id;

      LOOP
         FETCH cur_advisory_snap
            BULK COLLECT INTO   l_prev_advisory_snap_res
            LIMIT 25;

         EXIT WHEN l_prev_advisory_snap_res.COUNT = 0;

         FOR i IN 1 .. l_prev_advisory_snap_res.COUNT
         LOOP
            l_prev_advisory_snap(TO_CHAR (
                                    l_prev_advisory_snap_res (
                                       i
                                    ).advisory_id,
                                    'TM'
                                 )
                                 || '/'
                                 || TO_CHAR (
                                       l_prev_advisory_snap_res (
                                          i
                                       ).memory_size_factor,
                                       'TM'
                                    )) :=
               l_prev_advisory_snap_res (i);
         END LOOP;
      END LOOP;

      CLOSE cur_advisory_snap;

      /* Get the list of advisory IDs to be used later for retrieving the ID */
      OPEN cur_quest_ppcm_advisory for str_cur_quest_ppcm_advisory;

      FETCH cur_quest_ppcm_advisory BULK COLLECT INTO   l_advisory_list;

      CLOSE cur_quest_ppcm_advisory;

      /* Get the values from v$db_cache_advice */

      OPEN cur_db_cache_advice for str_cur_db_cache_advice;

      FETCH cur_db_cache_advice BULK COLLECT INTO   l_cur_advisory_snap_res;

      CLOSE cur_db_cache_advice;

      move_advisory_snap_vals ('DBCACHE', 'V$DB_CACHE_ADVICE');

      /* Get the values from v$pga_target_advice */

      OPEN cur_pga_target_advice for str_cur_pga_target_advice;

      FETCH cur_pga_target_advice
         BULK COLLECT INTO   l_cur_advisory_snap_res;

      CLOSE cur_pga_target_advice;

      move_advisory_snap_vals ('PGA', 'V$PGA_TARGET_ADVICE');

      /* Save the advisory snapshots into quest_ppcm_advisory_snap */
      FORALL indx IN INDICES OF l_cur_advisory_snap
         INSERT INTO quest_ppcm_advisory_snap
           VALUES   l_cur_advisory_snap (indx);
   END snap_advisory;

   /*
     Take a snapshot by calling the procedures above
   */

   PROCEDURE take_snapshot (i_cur_snapshot    IN quest_ppcm_snapshot%ROWTYPE,
                            i_prev_snapshot   IN quest_ppcm_snapshot%ROWTYPE)
   IS
   BEGIN
      snap_statistic (i_cur_snapshot, i_prev_snapshot);
      snap_iostat (i_cur_snapshot, i_prev_snapshot);
      snap_advisory (i_cur_snapshot, i_prev_snapshot);
   END take_snapshot;

   FUNCTION get_memory_usage (i_snapshot_id IN NUMBER)
      RETURN NUMBER
   IS
      TYPE typ_advisory_snap
      IS
         RECORD (
            advisory_id            NUMBER,
            memory_size            NUMBER,
            estd_time              NUMBER,
            estd_overalloc_count   NUMBER
         );

      TYPE typ_advisory_snap_rows
      IS
         TABLE OF typ_advisory_snap
            INDEX BY PLS_INTEGER;

      l_advisory_rows                typ_advisory_snap_rows;

      TYPE typ_number_table
      IS
         TABLE OF NUMBER
            INDEX BY PLS_INTEGER;

      l_advisory_points              typ_number_table;

      l_total_memory                 NUMBER := 0;
      l_advisory_points_iterator     PLS_INTEGER;

      l_cur_time_rate                NUMBER;
      l_cur_time_rate_delta          NUMBER;
      l_cur_time_rate_delta_delta    NUMBER;

      l_prev_time_rate               NUMBER;
      l_prev_time_rate_delta         NUMBER;
      l_prev_time_rate_delta_delta   NUMBER;

      l_max_time_rate_delta          NUMBER;
      l_find_time_rate_delta_delta   BOOLEAN := FALSE;
   BEGIN
        /* Fetch the advisory points into the local array - they need to be sorted correctly */
        SELECT   advisory_id,
                 memory_size,
                 ABS (estd_time_rate),
                 ABS (estd_overalloc_count_rate)
          BULK   COLLECT
          INTO   l_advisory_rows
          FROM   quest_ppcm_advisory_snap pas
         WHERE   pas.snapshot_id = i_snapshot_id
      ORDER BY   pas.advisory_id ASC, pas.memory_size ASC;

      /* Loop through the sorted array to perform delta calculations and find the memory "sweet spots" */
      FOR i IN 1 .. l_advisory_rows.COUNT
      /* Make sure that the array of points is initialized for all points in order to iterate through it later - just in case no point is found */
      LOOP
         IF (NOT l_advisory_points.EXISTS (l_advisory_rows (i).advisory_id))
         THEN
            l_advisory_points (l_advisory_rows (i).advisory_id) := NULL;
         END IF;

         /* If this is the first row for this advisory - then reset all the delta variables and previous variables */
         IF ( (NOT l_advisory_rows.EXISTS (i - 1))
             OR (l_advisory_rows.EXISTS (i - 1)
                 AND l_advisory_rows (i).advisory_id <>
                       l_advisory_rows (i - 1).advisory_id))
         THEN
            l_max_time_rate_delta := NULL;
            l_prev_time_rate := NULL;
            l_prev_time_rate_delta := NULL;
            l_prev_time_rate_delta_delta := NULL;
            l_cur_time_rate := NULL;
            l_cur_time_rate_delta := NULL;
            l_cur_time_rate_delta_delta := NULL;

            /* If it is the first row and the time is 0 - then use this as the point, as can't get better than no time */
            IF l_advisory_rows (i).estd_time = 0
            THEN
               l_advisory_points (l_advisory_rows (i).advisory_id) :=
                  l_advisory_rows (i).memory_size;
            END IF;
         ELSE
            /* Calculate the time / memory rate */
            l_cur_time_rate :=
               (l_advisory_rows (i).estd_time
                - l_advisory_rows (i - 1).estd_time)
               / (l_advisory_rows (i).memory_size
                  - l_advisory_rows (i - 1).memory_size);
            /* Calculate the delta of the previous variable */
            l_cur_time_rate_delta := l_cur_time_rate - l_prev_time_rate;
            /* And the delta of the delta */
            l_cur_time_rate_delta_delta :=
               l_cur_time_rate_delta - l_prev_time_rate_delta;

            /*
               If the maximum delta of the rate has not been set, or if the current row is bigger than the previous maximum, then
               set the new maximum, and if the previous delta of the delta of the rate has been calculated, then set the boolean
               to find the point where the delta of the delta of the rate crosses 0
            */
            IF (    l_cur_time_rate_delta IS NOT NULL
                AND l_cur_time_rate_delta <> 0
                AND l_max_time_rate_delta IS NULL)
               OR l_cur_time_rate_delta > l_max_time_rate_delta
            THEN
               l_max_time_rate_delta := l_cur_time_rate_delta;

               IF l_prev_time_rate_delta_delta IS NOT NULL
               THEN
                  l_find_time_rate_delta_delta := TRUE;
               END IF;
            END IF;
         END IF;

         /* If the point where the delta of the delta of the rate crosses 0 should be found, and it is crossing 0, then
         set the boolean to no longer find it, and set the advisory point for the current advisory to be the point where it crosses 0
         this assumes a straight line between the current and previous points. If the line is flat it will use the current point. */

         IF     l_find_time_rate_delta_delta
            AND NVL (l_prev_time_rate_delta_delta, 0) >= 0
            AND NVL (l_cur_time_rate_delta_delta, 0) <= 0
         THEN
            l_find_time_rate_delta_delta := FALSE;

            IF (ABS (l_prev_time_rate_delta_delta)
                + ABS (l_cur_time_rate_delta_delta)) <> 0
            THEN
               l_advisory_points (l_advisory_rows (i).advisory_id) :=
                  (l_advisory_rows (i - 1).memory_size)
                  + (ABS (l_prev_time_rate_delta_delta)
                     / (ABS (l_prev_time_rate_delta_delta)
                        + ABS (l_cur_time_rate_delta_delta)))
                    * (l_advisory_rows (i).memory_size
                       - l_advisory_rows (i - 1).memory_size);
            ELSE
               l_advisory_points (l_advisory_rows (i).advisory_id) :=
                  l_advisory_rows (i).memory_size;
            END IF;
         END IF;

         /* For PGA advisories, if this is the first point where the estd_overalloc_count reaches 0, then use this point */

         IF (    l_advisory_rows.EXISTS (i - 1)
             AND l_advisory_rows (i - 1).estd_overalloc_count > 0
             AND l_advisory_rows (i).estd_overalloc_count = 0)
         THEN
            l_advisory_points (l_advisory_rows (i).advisory_id) :=
               l_advisory_rows (i).memory_size;
         END IF;

         /* Set the previous values to the current values ready for the next iteration */

         l_prev_time_rate := l_cur_time_rate;
         l_prev_time_rate_delta := l_cur_time_rate_delta;
         l_prev_time_rate_delta_delta := l_cur_time_rate_delta_delta;

         /* If this is the last iteration for the current advisory and the memory size has not yet been found or the point at which the
            delta of the delta of the rate is yet to be found, then set the memory size to the current iterations size, as the "sweet spot"
            must be beyond this */

         IF (l_advisory_points (l_advisory_rows (i).advisory_id) IS NULL
             OR l_find_time_rate_delta_delta)
            AND ( (l_advisory_rows.EXISTS (i + 1)
                   AND (l_advisory_rows (i).advisory_id <>
                           l_advisory_rows (i + 1).advisory_id
                        OR l_advisory_rows (i).estd_time =
                             l_advisory_rows (i + 1).estd_time))
                 OR (NOT l_advisory_rows.EXISTS (i + 1)))
         THEN
            l_advisory_points (l_advisory_rows (i).advisory_id) :=
               l_advisory_rows (i).memory_size;
         END IF;
      END LOOP;

      /* Loop through the advisories and add the memory sizes together to get the total memory size to pass back to the caller */

      l_advisory_points_iterator := l_advisory_points.FIRST;

      WHILE l_advisory_points_iterator IS NOT NULL
      LOOP
         l_total_memory :=
            l_total_memory + l_advisory_points (l_advisory_points_iterator);
         l_advisory_points_iterator :=
            l_advisory_points.NEXT (l_advisory_points_iterator);
      END LOOP;

      RETURN l_total_memory;
   END get_memory_usage;

   FUNCTION calc_memory_usage (i_snapshot_id IN NUMBER)
      RETURN NUMBER
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      /* This is run inside a select statement so needs to be an isolated transaction */

      l_memory_usage   NUMBER;
   BEGIN
      /* Get the memory usage from the advisory data */
      l_memory_usage := get_memory_usage (i_snapshot_id);

      IF g_memory_usage_id IS NULL
      THEN
         BEGIN
            SELECT   statistic_id
              INTO   g_memory_usage_id
              FROM   quest_ppcm_statistic
             WHERE   statistic_name = 'MEMORY_USAGE'
                     AND statistic_source = 'QUEST_PPCM_COLLECTOR_PM';
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               /* Cannot find the statistic_id to store the memory usage value against - assume it shouldn't be cached */
               ROLLBACK;
               g_memory_usage_id := -1;
               RETURN l_memory_usage;
         END;
      ELSIF g_memory_usage_id = -1
      THEN
         /* Cannot find the statistic_id to store the memory usage value against - assume it shouldn't be cached */
         ROLLBACK;
         RETURN l_memory_usage;
      END IF;

      /* Cache the value in the quest_ppcm_statistic_snap table so it can be used again later without re-calculating it */
      BEGIN
         INSERT INTO quest_ppcm_statistic_snap (snapshot_id,
                                                statistic_id,
                                                raw_value,
                                                delta_value,
                                                rate_value)
           VALUES   (i_snapshot_id,
                     g_memory_usage_id,
                     l_memory_usage,
                     NULL,
                     NULL);
      EXCEPTION
         WHEN DUP_VAL_ON_INDEX
         THEN
            UPDATE   quest_ppcm_statistic_snap
               SET   raw_value = l_memory_usage,
                     delta_value = NULL,
                     rate_value = NULL
             WHERE   snapshot_id = i_snapshot_id
                     AND statistic_id = g_memory_usage_id;
      END;

      COMMIT;
      RETURN l_memory_usage;
   END calc_memory_usage;


   FUNCTION run_custom_sql (i_sql_text IN VARCHAR2)
      RETURN NUMBER
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      /* Isolate this transaction so we can set it to read only to stop the user from modifying data in here.
         Also don't want to affect the transaction of anything calling this */
      datatype_exc exception;
      PRAGMA EXCEPTION_INIT (datatype_exc, -932);
      l_result   NUMBER;
   BEGIN
      /* Set the transaction to read only to stop any data modification. */
      SET TRANSACTION READ ONLY;

      /* Only allow select statements to be run. */
      IF REGEXP_LIKE (i_sql_text, '^\s*select\s', 'i')
      THEN
         /* Execute the statement into the return variable. This must be a one column select that returns one row and is a number. */
         BEGIN
            EXECUTE IMMEDIATE i_sql_text INTO   l_result;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               raise_application_error (
                  en_custom_sql_no_rows,
                  'Custom SQL returned no rows - the SQL must return one row'
               );
            WHEN TOO_MANY_ROWS
            THEN
               raise_application_error (
                  en_custom_sql_multi_rows,
                  'Custom SQL returned multiple rows - the SQL must only return one row'
               );
            WHEN datatype_exc
            THEN
               raise_application_error (
                  en_custom_sql_datatype,
                  'Custom SQL returned wrong data type - the SQL must return a NUMBER, and must return only ONE column'
               );
         END;

         /* This doesn't raise the no_data_found exception - so manually raise it if no rows are returned as we want one row. */
         IF SQL%ROWCOUNT = 0
         THEN
            RAISE NO_DATA_FOUND;
         END IF;
      ELSE
         raise_application_error (
            -20000,
            'Statement does not appear to be a select statement.'
         );
      END IF;

      ROLLBACK;
      RETURN l_result;
   EXCEPTION
      WHEN OTHERS
      THEN
         ROLLBACK;
         RAISE;
   END run_custom_sql;

   /*
     This procedure will set a custom SQL - it will find an existing SQL ID, or create a new one, then save this ID in the parameters
   */

   PROCEDURE set_custom_sql (
      i_custom_sql_type   IN quest_ppcm_custom_sql.custom_sql_type%TYPE,
      i_sql_text          IN quest_ppcm_custom_sql.sql_text%TYPE,
      i_custom_sql_name   IN quest_ppcm_custom_sql.custom_sql_name%TYPE
   )
   IS
      l_custom_sql_id   NUMBER;
   BEGIN
      /* If there is a SQL text, then find the SQL ID to use */
      IF i_sql_text IS NOT NULL
      THEN
         l_custom_sql_id :=
            get_custom_sql_id (UPPER (i_custom_sql_type),
                               i_sql_text,
                               i_custom_sql_name);
      END IF;

      /* Set the parameter - if no SQL text was entered, this parameter would be set to null - therefore disabling collection of custom SQL */
      quest_ppcm_collector.set_ppcm_parameter (UPPER (i_custom_sql_type),
                                               l_custom_sql_id);
      COMMIT;
   END set_custom_sql;
END quest_ppcm_collector_pm;
/
