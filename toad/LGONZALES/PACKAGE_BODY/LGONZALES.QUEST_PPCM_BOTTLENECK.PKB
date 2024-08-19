CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_ppcm_bottleneck
AS
   FUNCTION get_statistic_id (p_statistic_name VARCHAR2, p_level NUMBER)
      RETURN NUMBER;

   TYPE typ_category_rec IS RECORD (
      category_level   NUMBER (1),
      CATEGORY         VARCHAR2 (100),
      microseconds     NUMBER,
      total_waits      NUMBER,
      avg_wait         NUMBER,
      pct              NUMBER,
      total_sum        NUMBER
   );

   TYPE typ_time_statistic_rec IS TABLE OF quest_ppcm_timed_statistic%ROWTYPE
      INDEX BY BINARY_INTEGER;

   TYPE typ_time_snap_rec IS TABLE OF quest_ppcm_time_snap%ROWTYPE
      INDEX BY BINARY_INTEGER;

   TYPE typ_reverse_idx IS TABLE OF PLS_INTEGER
      INDEX BY VARCHAR2 (100);

   TYPE typ_category_rec_arr IS TABLE OF typ_category_rec
      INDEX BY BINARY_INTEGER;

   TYPE typ_idx_idx IS TABLE OF PLS_INTEGER
      INDEX BY BINARY_INTEGER;

   garr_timed_statistic_rec       typ_time_statistic_rec;
   garr_new_timed_statistic_rec   typ_time_statistic_rec;
   garr_time_snap_rec             typ_time_snap_rec;
   garr_prev_time_snap_rec        typ_time_snap_rec;
   garr_stat_reverse_idx          typ_reverse_idx;
   garr_prev_snap_stat_idx        typ_idx_idx;
   garr_category_rec              typ_category_rec_arr;
   grec_ppcm_snapshot             quest_ppcm_snapshot%ROWTYPE;
   grec_prev_ppcm_snapshot        quest_ppcm_snapshot%ROWTYPE;
   gv_new_timed_statistic_idx     PLS_INTEGER;
   gv_instance_id                 PLS_INTEGER;
   gv_previous_snapshot           PLS_INTEGER;
   gv_snapshot_type               VARCHAR2 (50)                 := 'BNECK';
   gv_start_number_date           DATE
                   := TO_DATE ('30/12/1899 00:00:00', 'DD/MM/YYYY HH24:MI:SS');
   gv_snapshot_reset              BOOLEAN                       := FALSE;
   gc_package_name       CONSTANT  VARCHAR2(50) := 'QUEST_PPCM_BOTTLENECK';


   TYPE rc is  REF CURSOR;
   -- if true, then ignore previous
   --     snapshot data
   str_statistic_csr VARCHAR2(4000) :=
      'WITH time_model AS
           (
              SELECT /*+ materialize */
                     SUM
                        (CASE
                            WHEN stat_name IN
                                           (''DB time'', ''background cpu time'')
                               THEN VALUE
                         END
                        ) AS cpu_time,
                     SUM
                        (CASE
                            WHEN stat_name IN
                                       (''background elapsed time'', ''DB time'')
                               THEN VALUE
                         END
                        ) AS active_time
                FROM v$sys_time_model
               WHERE stat_name IN
                        (''DB time'',
                         ''DB CPU'',
                         ''background elapsed time'',
                         ''background cpu time''
                        )),
           wait_interface AS
           (
              SELECT /*+ materialize */
                     CASE topcategory
                        WHEN ''Other''
                           THEN ''Other wait''
                        ELSE topcategory || '' - '' || subcategory
                     END waitcategory,
                     e.event, time_waited_micro microseconds,
                     total_waits total_waits
                FROM quest_soo_event_categories c JOIN v$system_event e
                     ON (e.event = c.NAME)
               WHERE topcategory <> ''Idle'')
      SELECT   category_level, CATEGORY, microseconds, total_waits,
               ROUND (microseconds / total_waits) avg_wait,
               ROUND
                    (  microseconds
                     * 100
                     / SUM (microseconds) OVER (PARTITION BY category_level),
                     2
                    ) pct,
               SUM (microseconds) OVER (PARTITION BY category_level)
                                                                    total_sum
          FROM (SELECT 2 category_level, event CATEGORY, microseconds,
                       total_waits
                  FROM wait_interface
                UNION
                SELECT   1 category_level, waitcategory CATEGORY,
                         SUM (microseconds) microseconds,
                         SUM (total_waits) total_waits
                    FROM wait_interface
                GROUP BY waitcategory
                UNION
                SELECT 1, ''CPU'', cpu_time, NULL
                  FROM time_model
                UNION
                SELECT 1, ''Other'',
                       GREATEST (active_time - cpu_time - wait_time,
                                 0
                                ) other_time,
                       NULL
                  FROM time_model
                       CROSS JOIN
                       (SELECT SUM (microseconds) wait_time
                          FROM wait_interface) w
                       )
      ORDER BY 1, 3 DESC';

   -- Do delta calculations for 2 snapshot runs
   FUNCTION calculate_delta (p_value1 NUMBER, p_value2 NUMBER)
      RETURN NUMBER
   IS
      lv_delta   NUMBER;
   BEGIN
      IF p_value1 IS NULL OR p_value2 IS NULL
      THEN
         RETURN 0;
      END IF;

      RETURN (p_value2 - p_value1);
   END calculate_delta;

   -- Calculate rate
   FUNCTION calculate_rate (p_delta NUMBER, p_time_seconds NUMBER)
      RETURN NUMBER
   IS
      lv_rate   NUMBER;
   BEGIN
      IF p_delta IS NULL
      THEN
      	 RETURN NULL;
      END IF;

      IF p_time_seconds = 0 OR p_delta = 0
      THEN
         RETURN 0;
      END IF;

      RETURN ROUND (p_delta / p_time_seconds, 2);
   END calculate_rate;

   -- Load all entries for time snapshot
   PROCEDURE load_statistic_data
   IS
     statistic_csr rc;
   BEGIN

      OPEN statistic_csr for str_statistic_csr;

      FETCH statistic_csr
      BULK COLLECT INTO garr_category_rec;

      CLOSE statistic_csr;
   END load_statistic_data;

   -- Load previous data to calculate delta's and rates
   PROCEDURE load_previous_snap (
      p_prev_snapshot_id   NUMBER,
      p_instance_id        NUMBER
   )
   IS
   BEGIN
      IF grec_ppcm_snapshot.db_restart_flag = 1 OR p_prev_snapshot_id = 0
      THEN
         RETURN;
      END IF;

      SELECT *
      BULK COLLECT INTO garr_prev_time_snap_rec
        FROM quest_ppcm_time_snap
       WHERE snapshot_id = p_prev_snapshot_id;

      FOR idx IN 1 .. garr_prev_time_snap_rec.COUNT
      LOOP
         garr_prev_snap_stat_idx (garr_prev_time_snap_rec (idx).statistic_id) :=
                                                                          idx;
      END LOOP;
   END load_previous_snap;

   FUNCTION get_count_delta (p_statistic_id NUMBER, p_count NUMBER)
      RETURN NUMBER
   IS
   BEGIN
      IF p_count IS NULL
      THEN
         RETURN NULL;
      END IF;

      IF grec_ppcm_snapshot.db_restart_flag = 1
      THEN
         RETURN p_count;
      END IF;

      IF NOT garr_prev_snap_stat_idx.EXISTS (p_statistic_id)
      THEN
         RETURN NULL;
      END IF;

      RETURN calculate_delta
               (garr_prev_time_snap_rec
                                      (garr_prev_snap_stat_idx (p_statistic_id)
                                      ).raw_count,
                p_count
               );
   END get_count_delta;

   FUNCTION get_ms_delta (p_statistic_id NUMBER, p_ms NUMBER)
      RETURN NUMBER
   IS
   BEGIN
      IF p_ms IS NULL
      THEN
         RETURN 0;
      END IF;

      IF grec_ppcm_snapshot.db_restart_flag = 1
      THEN
         RETURN p_ms;
      END IF;

      IF NOT garr_prev_snap_stat_idx.EXISTS (p_statistic_id)
      THEN
         RETURN 0;
      END IF;

      RETURN calculate_delta
               (garr_prev_time_snap_rec
                                      (garr_prev_snap_stat_idx (p_statistic_id)
                                      ).raw_microseconds,
                p_ms
               );
   END get_ms_delta;

   -- Loop through and process all the statistics
   PROCEDURE process_statistics
   IS
      lv_idx         PLS_INTEGER;
      lv_time_diff   PLS_INTEGER;
   BEGIN
      lv_idx := 1;

      FOR idx IN 1 .. garr_category_rec.COUNT
      LOOP
         garr_time_snap_rec (lv_idx).snapshot_id :=
                                               grec_ppcm_snapshot.snapshot_id;
         garr_time_snap_rec (lv_idx).statistic_id :=
            get_statistic_id (garr_category_rec (idx).CATEGORY,
                              garr_category_rec (idx).category_level
                             );
         garr_time_snap_rec (lv_idx).raw_count :=
                                           garr_category_rec (idx).total_waits;
         garr_time_snap_rec (lv_idx).raw_microseconds :=
                                          garr_category_rec (idx).microseconds;

         IF NOT gv_snapshot_reset
         THEN            -- Only calculate deltas if reset flag is not current
            garr_time_snap_rec (lv_idx).delta_count :=
               get_count_delta (garr_time_snap_rec (lv_idx).statistic_id,
                                garr_time_snap_rec (lv_idx).raw_count
                               );
            garr_time_snap_rec (lv_idx).rate_count :=
               calculate_rate (garr_time_snap_rec (lv_idx).delta_count,
                               grec_ppcm_snapshot.snapshot_duration
                              );
            garr_time_snap_rec (lv_idx).delta_microseconds :=
               get_ms_delta (garr_time_snap_rec (lv_idx).statistic_id,
                             garr_category_rec (idx).microseconds
                            );
            garr_time_snap_rec (lv_idx).rate_microseconds :=
               calculate_rate (garr_time_snap_rec (lv_idx).delta_microseconds,
                               grec_ppcm_snapshot.snapshot_duration
                              );
         END IF;

         lv_idx := lv_idx + 1;
      END LOOP;
   END process_statistics;

   -- Load statistic defintions so can easily get statistic_id from name
   -- Only need to load once per execution
   PROCEDURE load_statistic_defs
   IS
   BEGIN
      SELECT   *
      BULK COLLECT INTO garr_timed_statistic_rec
          FROM quest_ppcm_timed_statistic
      ORDER BY statistic_id;

      FOR idx IN 1 .. garr_timed_statistic_rec.COUNT
      LOOP
         garr_stat_reverse_idx (garr_timed_statistic_rec (idx).NAME) := idx;
      END LOOP;
   END load_statistic_defs;

   -- Create a new statistic row
   FUNCTION create_statistic (p_statistic_name VARCHAR2, p_level NUMBER)
      RETURN quest_ppcm_timed_statistic%ROWTYPE
   IS
      lv_row   quest_ppcm_timed_statistic%ROWTYPE;
   BEGIN
      SELECT quest_ppcm_snapshot_id_s.NEXTVAL
        INTO lv_row.statistic_id
        FROM DUAL;

      lv_row.statistic_depth := p_level;

      IF INSTR (p_statistic_name, '-') > 0 AND p_level = 1
      THEN
         lv_row.statistic_source := 'QUEST_SOO_EVENT_CATEGORIES';
      ELSIF p_level = 2
      THEN
         lv_row.statistic_source := 'V$SYSTEM_EVENT';
      ELSE
         lv_row.statistic_source := 'V$SYS_TIME_MODEL';
      END IF;

      lv_row.NAME := p_statistic_name;
      RETURN lv_row;
   END create_statistic;

   -- From a statistic name get statistic_id
   FUNCTION get_statistic_id (p_statistic_name VARCHAR2, p_level NUMBER)
      RETURN NUMBER
   IS
      lv_statistic_id   NUMBER;
   BEGIN
      IF garr_stat_reverse_idx.EXISTS (p_statistic_name)
      THEN
         RETURN garr_timed_statistic_rec
                                     (garr_stat_reverse_idx (p_statistic_name)
                                     ).statistic_id;
      END IF;

      -- Statistic doesn't exist. Need to create a new entry for it
      gv_new_timed_statistic_idx := gv_new_timed_statistic_idx + 1;
      -- Create row
      garr_new_timed_statistic_rec (gv_new_timed_statistic_idx) :=
                                  create_statistic (p_statistic_name, p_level);
      -- Add to main array
      garr_timed_statistic_rec (garr_timed_statistic_rec.COUNT + 1) :=
                     garr_new_timed_statistic_rec (gv_new_timed_statistic_idx);
      -- Create reverse index for it
      garr_stat_reverse_idx (p_statistic_name) :=
                                                garr_timed_statistic_rec.COUNT;
      RETURN garr_new_timed_statistic_rec (gv_new_timed_statistic_idx).statistic_id;
   END get_statistic_id;

   -- Save snapshot statistic defintions
   PROCEDURE save_statistic_def
   IS
   BEGIN
      FORALL idx IN 1 .. garr_new_timed_statistic_rec.COUNT
         INSERT INTO quest_ppcm_timed_statistic
              VALUES garr_new_timed_statistic_rec (idx);
   END save_statistic_def;

   -- Save timed results
   PROCEDURE save_time_snap
   IS
   BEGIN
      FORALL idx IN 1 .. garr_time_snap_rec.COUNT
         INSERT INTO quest_ppcm_time_snap
              VALUES garr_time_snap_rec (idx);
   END save_time_snap;

   -- Cleanup internal arrays
   PROCEDURE cleanup
   IS
   BEGIN
      gv_new_timed_statistic_idx := 0;
      garr_timed_statistic_rec.DELETE;
      garr_new_timed_statistic_rec.DELETE;
      garr_time_snap_rec.DELETE;
      garr_prev_time_snap_rec.DELETE;
      garr_stat_reverse_idx.DELETE;
      garr_prev_snap_stat_idx.DELETE;
      garr_category_rec.DELETE;
   END cleanup;

   -- Get current instance ID
   FUNCTION get_instance_id
      RETURN NUMBER
   IS
      lv_instance   NUMBER;
      lv_count      PLS_INTEGER;
   BEGIN
      lv_instance := SYS_CONTEXT ('userenv', 'instance');

      SELECT COUNT (*)
        INTO lv_count
        FROM quest_ppcm_instance
       WHERE instance_id = lv_instance;

      IF lv_count = 0
      THEN
         EXECUTE IMMEDIATE 'INSERT INTO quest_ppcm_instance
                            (instance_id, instance_name, host_name)
                                SELECT instance_number, instance_name, host_name
                                FROM v$instance';
--         COMMIT;
      END IF;

      RETURN lv_instance;
   END get_instance_id;

   -- Get next snapshot ID
   FUNCTION next_snapshot_id
      RETURN PLS_INTEGER
   IS
      lv_snapshot_id   PLS_INTEGER;
   BEGIN
      SELECT quest_ppcm_snapshot_id_s.NEXTVAL
        INTO lv_snapshot_id
        FROM DUAL;

      RETURN (lv_snapshot_id);
   END;

   -- Return DB start time
   FUNCTION db_start_time
      RETURN DATE
   IS
      lv_db_start_time   DATE;
   BEGIN
      EXECUTE IMMEDIATE 'SELECT startup_time
                         FROM v$instance'
   	      INTO lv_db_start_time;

      RETURN (lv_db_start_time);
   END;

   -- Get snapshot header data
   PROCEDURE get_snapshot_data (p_snapshot_id NUMBER)
   IS
   BEGIN
      SELECT *
        INTO grec_ppcm_snapshot
        FROM quest_ppcm_snapshot
       WHERE snapshot_id = p_snapshot_id AND snapshot_type = gv_snapshot_type;
   END get_snapshot_data;

   -- Find previous snapshot ID so can do data comparisons for delta/rate
   PROCEDURE get_previous_snapshot (p_snapshot_id NUMBER, p_instance_id NUMBER)
   IS
   BEGIN
      BEGIN
         SELECT *
           INTO grec_prev_ppcm_snapshot
           FROM quest_ppcm_snapshot
          WHERE snapshot_id =
                   (SELECT MAX (snapshot_id)
                      FROM quest_ppcm_snapshot
                     WHERE instance_id = p_instance_id
                       AND snapshot_id < p_snapshot_id
                       AND snapshot_type = gv_snapshot_type);
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            NULL;
      END;
   END get_previous_snapshot;

   FUNCTION seconds_between (p_start_date DATE, p_end_date DATE)
      RETURN PLS_INTEGER
   IS
      lv_seconds   PLS_INTEGER;
   BEGIN
      lv_seconds := (p_end_date - p_start_date) * 60 * 60 * 24;
      RETURN lv_seconds;
   END seconds_between;

   -- Create new snapshot header and save
   PROCEDURE create_snapshot_header
   IS
      l_snapshot_timestamp        DATE    := SYSDATE;
      l_prev_snapshot_timestamp   DATE;
      l_db_start_time             DATE;
      l_instance_id               INTEGER;
   BEGIN
      grec_ppcm_snapshot.snapshot_id := next_snapshot_id ();
      grec_ppcm_snapshot.instance_id := gv_instance_id;
      grec_ppcm_snapshot.snapshot_timestamp := SYSDATE;
      grec_ppcm_snapshot.db_start_time := db_start_time ();

      IF gv_snapshot_reset
      THEN
         grec_ppcm_snapshot.db_restart_flag := 1;
      ELSE
         grec_ppcm_snapshot.db_restart_flag := 0;
      END IF;

      grec_ppcm_snapshot.snapshot_type := gv_snapshot_type;
      get_previous_snapshot (grec_ppcm_snapshot.snapshot_id,
                             grec_ppcm_snapshot.instance_id
                            );

      IF     grec_prev_ppcm_snapshot.snapshot_timestamp IS NOT NULL
         AND grec_prev_ppcm_snapshot.snapshot_timestamp >
                                              grec_ppcm_snapshot.db_start_time
      THEN
         grec_ppcm_snapshot.snapshot_duration :=
            seconds_between (grec_prev_ppcm_snapshot.snapshot_timestamp,
                             grec_ppcm_snapshot.snapshot_timestamp
                            );
      ELSIF grec_prev_ppcm_snapshot.snapshot_timestamp IS NOT NULL
      THEN
         grec_ppcm_snapshot.snapshot_duration :=
            seconds_between (grec_ppcm_snapshot.db_start_time,
                             grec_ppcm_snapshot.snapshot_timestamp
                            );
      ELSE
         grec_ppcm_snapshot.snapshot_duration := 0;
      END IF;

      INSERT INTO quest_ppcm_snapshot
           VALUES grec_ppcm_snapshot;
   END create_snapshot_header;

   PROCEDURE collect_data_reset
   IS
   BEGIN
      gv_snapshot_reset := TRUE;
      collect_data;
      gv_snapshot_reset := FALSE;
   END;

   -- Main entry point to collect and calculate data
   PROCEDURE collect_data (p_snapshot_id NUMBER DEFAULT NULL)
   IS
   BEGIN
      /* Disable parallel query CR 9869 */
      BEGIN
         EXECUTE IMMEDIATE 'alter session disable parallel query';
      EXCEPTION
         WHEN OTHERS THEN
            null;
      END;

      -- Any new statistics are added to a new array
      -- Initialise variable for index
      gv_new_timed_statistic_idx := 0;
      -- Get current instance id
      gv_instance_id := get_instance_id;

      -- Load snashot data
      IF p_snapshot_id IS NULL
      THEN
         create_snapshot_header;
      ELSE
         get_snapshot_data (p_snapshot_id);
         -- Get previous snapshot id
         get_previous_snapshot (p_snapshot_id, gv_instance_id);
      END IF;

      -- Load all existing statistics
      load_statistic_defs;
      -- Load previous snapshot data
      load_previous_snap (grec_prev_ppcm_snapshot.snapshot_id, gv_instance_id);
      -- Load data for processing
      load_statistic_data;
      -- Process data
      process_statistics;
      -- Save data off
      save_statistic_def;
      save_time_snap;

      IF     grec_prev_ppcm_snapshot.snapshot_timestamp IS NOT NULL
         AND (  TRUNC (grec_ppcm_snapshot.snapshot_timestamp)
              - TRUNC (grec_prev_ppcm_snapshot.snapshot_timestamp)
             ) >= 1
      THEN
         purge_snapshots;
      END IF;

      -- Cleanup internal arrays
      cleanup;
      EXCEPTION WHEN OTHERS THEN
         /* Log exception and continue - this stops errors appearing in the alert log */
         quest_soo_tracing.process_exception(gc_package_name,'COLLECT_DATA',0,sqlcode,sqlerrm);
   END collect_data;

   PROCEDURE run_calculation
   IS
   BEGIN
      NULL;
   END;

   -- Remove existing snapshot jobs for this user
   PROCEDURE remove_snapshot_job
   IS
      CURSOR c_jobs
      IS
         SELECT job
           FROM user_jobs
          WHERE what LIKE '%Quest PPCM Bottleneck job%';
   BEGIN
      FOR r IN c_jobs
      LOOP
         DBMS_JOB.remove (r.job);
      END LOOP;

      COMMIT;
   END;

   -- Create a job to do automatic job snapshots
   FUNCTION submit_snapshot_job (
      p_first_time_hhmm   VARCHAR2,
      p_interval_min      INTEGER
   )
      RETURN NUMBER
   IS
      l_job_str            VARCHAR2 (1000);
      l_job_no             NUMBER;
      l_interval_days      VARCHAR2 (50);
      l_comment_text       VARCHAR2 (2000);
      l_first_time         DATE;

      TYPE num_typ IS TABLE OF NUMBER
         INDEX BY BINARY_INTEGER;

      larr_instance_list   num_typ;
   BEGIN
      remove_snapshot_job;

      IF p_interval_min = 0.0
      THEN
         RETURN (0);
      END IF;

      l_first_time :=
         TO_DATE (TO_CHAR (SYSDATE, 'DDMMYY') || p_first_time_hhmm,
                  'DDMMYYHH24MI'
                 );
      l_job_str :=
            'BEGIN /*Quest PPCM Bottleneck job */ '
         || ' quest_ppcm_bottleneck.collect_data; END;';
      l_interval_days := '(' || p_interval_min || ' / (24*60))';
      l_first_time :=
         TO_DATE (TO_CHAR (SYSDATE, 'DDMMYY') || p_first_time_hhmm,
                  'DDMMYYHH24MI'
                 );

      IF l_first_time < SYSDATE
      THEN
         l_first_time := l_first_time + 1;
      END IF;

      SELECT inst_number
      BULK COLLECT INTO larr_instance_list
        FROM v$active_instances;

      IF larr_instance_list.COUNT () = 0
      THEN                                     /* Single instance of Oracle */
         DBMS_JOB.submit (job            => l_job_no,
                          what           => l_job_str,
                          next_date      => l_first_time,
                          INTERVAL       => 'SYSDATE+' || l_interval_days,
                          INSTANCE       => USERENV ('instance')
                         );
      ELSE             /* Create a job for each instance in the RAC cluster */
         FOR i IN 1 .. larr_instance_list.COUNT
         LOOP
            DBMS_JOB.submit (job            => l_job_no,
                             what           => l_job_str,
                             next_date      => l_first_time,
                             INTERVAL       => 'SYSDATE+' || l_interval_days,
                             INSTANCE       => larr_instance_list (i)
                            );
         END LOOP;
      END IF;

      COMMIT;
      RETURN (l_job_no);
   END;

   -- Find interval in minutes for existing job.
   FUNCTION job_interval_min (p_dbms_job_interval VARCHAR2)
      RETURN NUMBER
   IS
      l_sql_exec   VARCHAR2 (200);
      l_interval   NUMBER;
   BEGIN
      l_sql_exec :=
         'SELECT (' || p_dbms_job_interval
         || ' - sysdate) * 60 * 24 from dual';

      EXECUTE IMMEDIATE l_sql_exec
                   INTO l_interval;

      RETURN ROUND (l_interval, 2);
   END job_interval_min;

   FUNCTION param_name (p_parameter VARCHAR2)
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN 'BNECK_' || p_parameter;
   END param_name;

   -- Get value of parameter from PPCM bottlenecks
   FUNCTION ppcm_parameter (p_parameter_name VARCHAR2)
      RETURN VARCHAR2
   IS
      l_parameter_value   quest_ppcm_parameters.parameter_value%TYPE;
      l_parameter_name    quest_ppcm_parameters.parameter_name%TYPE;
   BEGIN
      l_parameter_name := param_name (p_parameter_name);

      BEGIN
         SELECT parameter_value
           INTO l_parameter_value
           FROM quest_ppcm_parameters
          WHERE parameter_name = l_parameter_name;
      EXCEPTION
         WHEN OTHERS
         THEN
            NULL;
      END;

      RETURN l_parameter_value;
   END ppcm_parameter;

   -- Set PPCM parameter
   PROCEDURE set_ppcm_parameter (
      p_parameter_name    VARCHAR2,
      p_parameter_value   VARCHAR2
   )
   IS
      l_parameter_name   quest_ppcm_parameters.parameter_name%TYPE;
   BEGIN
      l_parameter_name := param_name (p_parameter_name);

      UPDATE quest_ppcm_parameters
         SET parameter_value = p_parameter_value
       WHERE parameter_name = l_parameter_name;

      IF SQL%ROWCOUNT = 0
      THEN
         INSERT INTO quest_ppcm_parameters
                     (parameter_name, parameter_value
                     )
              VALUES (l_parameter_name, p_parameter_value
                     );
      END IF;

      COMMIT;
   END set_ppcm_parameter;

   -- Purge past snapshots
   PROCEDURE purge_snapshots
   IS
      TYPE typ_snapshot_id IS TABLE OF quest_ppcm_snapshot.snapshot_id%TYPE
         INDEX BY BINARY_INTEGER;

      arr_snapshot_id      typ_snapshot_id;
      l_retention_period   NUMBER;
      l_start_number       NUMBER;
   BEGIN
      l_retention_period :=
                       TO_NUMBER (ppcm_parameter ('SNAPSHOT_RETENTION_DAYS'));

      IF NVL (l_retention_period, 0) > 0
      THEN
         SELECT snapshot_id
         BULK COLLECT INTO arr_snapshot_id
           FROM quest_ppcm_snapshot
          WHERE instance_id > 0
            AND snapshot_timestamp < (SYSDATE - l_retention_period)
            AND snapshot_type = gv_snapshot_type;

         l_start_number :=
                         (SYSDATE - l_retention_period) - gv_start_number_date;
         FORALL idx IN 1 .. arr_snapshot_id.COUNT
            DELETE      quest_ppcm_time_snap
                  WHERE snapshot_id = arr_snapshot_id (idx);
         FORALL idx IN 1 .. arr_snapshot_id.COUNT
            DELETE      quest_ppcm_snapshot
                  WHERE snapshot_id = arr_snapshot_id (idx);

         DELETE      quest_ppcm_trend_change
               WHERE x_value <= l_start_number AND at_code LIKE 'BNECK%';

         DELETE      quest_ppcm_tca_exclusion
               WHERE expiry_date <= (SYSDATE - l_retention_period)
                 AND at_code LIKE 'BNECK%';
      END IF;

      COMMIT;
   END purge_snapshots;
END;
/
