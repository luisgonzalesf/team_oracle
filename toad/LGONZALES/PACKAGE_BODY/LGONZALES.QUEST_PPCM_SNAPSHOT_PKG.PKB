CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_ppcm_snapshot_pkg
IS
-----------------------------------------
-- Global private variables
-----------------------------------------
   g_current_snapshot_id   INTEGER;
   g_instance_id           INTEGER;
   g_prev_snapshot_id      INTEGER;
   g_snapshot_duration     NUMBER;             -- seconds since last snapshot
   g_db_restart_flag       NUMBER  := 0;       -- 1 if DB has restarted since
                                               -- last snapshot
   g_snapshot_type         VARCHAR2(10) := 'SQL';
   g_start_number_date    DATE := TO_DATE('30/12/1899 00:00:00', 'DD/MM/YYYY HH24:MI:SS');

   gc_package_name       CONSTANT  VARCHAR2(50) := 'QUEST_PPCM_SNAPSHOT_PKG';

   TYPE num_tab_typ IS TABLE OF NUMBER
      INDEX BY BINARY_INTEGER;

   FUNCTION job_interval_hrs (p_dbms_job_interval VARCHAR2)
      RETURN NUMBER
   IS
      v_sqltext   VARCHAR2 (1000);
      v_hours     NUMBER;
   BEGIN
      v_sqltext :=
                'SELECT (' || p_dbms_job_interval || '-sysdate)*24 from dual';

      EXECUTE IMMEDIATE v_sqltext
                   INTO v_hours;

      RETURN (v_hours);
   END;

   /* The next three functions support calculating a p value (probability)
       from a t (student-t) distribution.  I converted them from the javascript
       underlying the page http://members.aol.com/johnp71/pdfs.html and don't
       totally understand how they work, but I have checked that they return the
       correct results*/

   /* Statcom is a supporting function for the t_prob function*/
   FUNCTION statcom (q NUMBER, i NUMBER, j NUMBER, b NUMBER)
      RETURN NUMBER
   IS
      zz   NUMBER;
      z    NUMBER;
      k    NUMBER;
   BEGIN
      zz := 1;
      z := zz;
      k := i;

      WHILE (k <= j)
      LOOP
         zz := zz * q * k / (k - b);
         z := z + zz;
         k := k + 2;
      END LOOP;

      RETURN (z);
   END;

   /* Return the probability for a given student t-value for a given
      d.f (degrees of freedom) (two-tailed)*/
   FUNCTION t_prob (p_t NUMBER, p_df NUMBER)
      RETURN NUMBER
   IS
      w        NUMBER;
      th       NUMBER;
      sth      NUMBER;
      cth      NUMBER;
      pi       NUMBER := 3.1415926;
      t        NUMBER;
      n        NUMBER;
      prob_t   NUMBER;
   BEGIN
      n := p_df;
      t := ABS (p_t);
      w := t / SQRT (n);
      th := ATAN (w);

      IF (n = 1)
      THEN
         RETURN (1 - th / (pi / 4));
      END IF;

      sth := SIN (th);
      cth := COS (th);

      IF (MOD (n, 2) = 1)
      THEN
         prob_t :=
            (1
             - (th + sth * cth * statcom (cth * cth, 2, n - 3, -1))
               / (pi / 2)
            );
      ELSE
         prob_t := (1 - sth * statcom (cth * cth, 1, n - 3, -1));
      END IF;

      /*DBMS_OUTPUT.put_line (   'Probability of t value  '
                            || p_t
                            || ', df '
                            || p_df
                            || ' ='
                            || prob_t
                           );*/
      RETURN (prob_t);
   END;

   /* Return the probability that a given r (correlation) value
      is due to random chance alone (two tailed)*/
   FUNCTION prob_r (
      p_n   NUMBER /* number of records*/,
      p_r   NUMBER                                /* correlation coefficient*/
   )
      RETURN NUMBER
   IS
      l_t   NUMBER;                                      /* Student-t value*/
      l_p   NUMBER;                                    /* probability value*/
   BEGIN
      -- Calculate the student t value for the r value
      l_t := p_r * SQRT ((p_n - 2) / (1 - POWER (p_r, 2)));
      --DBMS_OUTPUT.put_line ('T value for ' || p_r || '=' || l_t);
      -- Get the probability for the r value
      l_p := t_prob (l_t, p_n - 2);
       /*DBMS_OUTPUT.put_line ('P for r= ' || p_r || ' n=' || p_n || ' IS '
                            || l_p
                           );*/
      /* value returned is the probability that the correlation could
         be random.  Value of .01 indicates the chances of this are 1 in
         100 */
      RETURN (l_p);
   END;

 -----------------------------------------
-- return DB start time
-----------------------------------------
   FUNCTION db_start_time
      RETURN DATE
   IS
      l_db_start_time   DATE;
   BEGIN
      execute immediate 'SELECT startup_time
                         FROM v$instance' INTO l_db_start_time;

      RETURN (l_db_start_time);
   END;

   -- Return a version string for the db
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
   END;                                                   --function dbversion

--------------------------------------
-- Get/Set the current instance id
--------------------------------------
   FUNCTION get_instance_id
      RETURN INTEGER
   IS
      l_instance_id   INTEGER;
      v_count         NUMBER;
   BEGIN
      --
      -- The old implemenation (below) creates a "quest" isntance_id
      -- which would be neccessary if this repository were to hold data
      -- across databases.  However, the current implementation needs to
      -- synchronize instance_ids within a cluster, so we use the oracle
      -- instance id
      --
      /*
         BEGIN
            SELECT instance_id
              INTO l_instance_id
              FROM quest_ppcm_instance JOIN v$instance
                   USING (host_name, instance_name)
                   ;
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               LOCK TABLE quest_ppcm_instance IN EXCLUSIVE MODE;

               SELECT NVL (MAX (instance_id), 0) + 1
                 INTO l_instance_id
                 FROM quest_ppcm_instance;

               INSERT INTO quest_ppcm_instance
                           (instance_id, instance_name, host_name)
                  SELECT l_instance_id, instance_name, host_name
                    FROM v$instance;
         END;

         */
      SELECT USERENV ('instance')
        INTO l_instance_id
        FROM DUAL;

      SELECT COUNT (*)
        INTO v_count
        FROM quest_ppcm_instance
       WHERE instance_id = l_instance_id;

      IF v_count = 0
      THEN
         execute immediate 'INSERT INTO quest_ppcm_instance
                            (instance_id, instance_name, host_name)
                            SELECT l_instance_id, instance_name, host_name
                            FROM v$instance';

         COMMIT;
      END IF;

      g_instance_id := l_instance_id;
      RETURN (l_instance_id);
   END;

-----------------------------------------
-- get previous snapshot details
-----------------------------------------
   FUNCTION prev_snapshot (
      p_snapshot_id          OUT   INTEGER,
      p_snapshot_timestamp   OUT   DATE
   )
      RETURN BOOLEAN
   IS
      l_is_prev_snapshot   BOOLEAN := TRUE;
   BEGIN
      BEGIN
         SELECT snapshot_id, snapshot_timestamp
           INTO p_snapshot_id, p_snapshot_timestamp
           FROM quest_ppcm_snapshot
          WHERE snapshot_id = (SELECT MAX (snapshot_id)
                                 FROM quest_ppcm_snapshot
                                WHERE NVL(snapshot_type, g_snapshot_type)  = g_snapshot_type);
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            l_is_prev_snapshot := FALSE;
      END;

      RETURN (l_is_prev_snapshot);
   END;

-----------------------------------------
-- No of seconds between two dates
-----------------------------------------
   FUNCTION seconds_between (p_hi_date DATE, p_low_date DATE)
      RETURN FLOAT
   IS
   BEGIN
      RETURN ((p_hi_date - p_low_date) * 24 * 60 * 60);
   END;

-----------------------------------------
-- get a new snapshot id
-----------------------------------------
   FUNCTION next_snapshot_id
      RETURN INTEGER
   IS
      l_snapshot_id   INTEGER;
   BEGIN
      SELECT quest_ppcm_snapshot_id_s.NEXTVAL
        INTO l_snapshot_id
        FROM DUAL;

      RETURN (l_snapshot_id);
   END;

-- ----------------------------------------
--  Set a parameter in the parameters table
-- ----------------------------------------
  PROCEDURE set_ppcm_parameter (
      p_parameter_name VARCHAR2,
      p_parameter_value VARCHAR2
  )
  IS
     v_count  NUMBER;
  BEGIN

      BEGIN
         SELECT count(*)
           INTO v_count
           FROM quest_ppcm_parameters
           WHERE parameter_name = UPPER(p_parameter_name);

         IF v_count = 0
         THEN
            INSERT INTO quest_ppcm_parameters
               (parameter_name, parameter_value)
            VALUES
               (UPPER(p_parameter_name), p_parameter_value);
         ELSE
            UPDATE quest_ppcm_parameters
              SET parameter_value = p_parameter_value
            WHERE
               parameter_name = UPPER(p_parameter_name);
         END IF;

         COMMIT;
      END;
  END;

-- ----------------------------------------------
--  Return a parameter from the parameters table
-- ----------------------------------------------
   FUNCTION ppcm_parameter (p_parameter_name VARCHAR2)
      RETURN VARCHAR2
   IS
      l_value   quest_ppcm_parameters.parameter_value%TYPE;
   BEGIN
      BEGIN
         SELECT parameter_value
           INTO l_value
           FROM quest_ppcm_parameters
          WHERE parameter_name = p_parameter_name;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            NULL;
      END;

      RETURN l_value;
   END;

----------------------------------------------------
--- Delete a snapshot
----------------------------------------------------
   PROCEDURE delete_snapshot (p_snapshot_id NUMBER)
   IS
   BEGIN
      DELETE FROM quest_ppcm_snapshot CASCADE
            WHERE snapshot_id = p_snapshot_id;

      COMMIT;
   END;

----------------------------------------------------
-- Delete a trend change
----------------------------------------------------
   PROCEDURE delete_trend_change(p_id NUMBER)
   IS
   BEGIN
   	 DELETE FROM quest_ppcm_trend_change
   	       WHERE tc_id = p_id;
   END;

----------------------------------------------------
-- Delete a trend change exclusion
----------------------------------------------------
   PROCEDURE delete_tcx(p_id NUMBER)
   IS
   BEGIN
     DELETE FROM quest_ppcm_tca_exclusion
           WHERE id = p_id;
   END;
----------------------------------------------------
--- Purge snapshots based on retention policy
----------------------------------------------------
   PROCEDURE purge_snapshots
   IS
      l_snapshot_retention_days   NUMBER;
      l_snapshot_list             num_tab_typ;
      l_snapshot_date_number 	  NUMBER;
   BEGIN
      l_snapshot_retention_days := ppcm_parameter ('SNAPSHOT_RETENTION_DAYS');

      IF NVL(l_snapshot_retention_days, 0) > 0
      THEN
         SELECT snapshot_id
         BULK COLLECT INTO l_snapshot_list
           FROM quest_ppcm_snapshot s
          WHERE s.instance_id > 0
            AND s.snapshot_timestamp < SYSDATE - l_snapshot_retention_days
            AND NVL(s.snapshot_type, g_snapshot_type) = g_snapshot_type;

         FOR i IN 1 .. l_snapshot_list.COUNT
         LOOP
            delete_snapshot (l_snapshot_list (i));
         END LOOP;

         l_snapshot_list.DELETE;
         l_snapshot_date_number := (sysdate - l_snapshot_retention_days) - g_start_number_date;

         SELECT tc_id
		 BULK COLLECT INTO 	l_snapshot_list
		   FROM quest_ppcm_trend_change
		  WHERE X_VALUE < l_snapshot_date_number
		    AND at_code LIKE 'SQL%';

         FOR i IN 1..l_snapshot_list.COUNT
         LOOP
         	delete_trend_change(l_snapshot_list(i));
         END LOOP;

         l_snapshot_list.DELETE;

         SELECT id
         BULK COLLECT INTO l_snapshot_list
           FROM quest_ppcm_tca_exclusion
          WHERE at_code LIKE 'SQL%'
            AND expiry_date < (sysdate - l_snapshot_retention_days);

         FOR i IN 1..l_snapshot_list.COUNT
         LOOP
         	delete_tcx(l_snapshot_list(i));
         END LOOP;

		 DELETE
		   FROM quest_ppcm_sql_text txt
		  WHERE instance_id >= 0
		    AND NOT EXISTS (SELECT 1
						      FROM quest_ppcm_sql_snapshot snap
						     WHERE snap.snapshot_id > 0
						       AND snap.instance_id= txt.instance_id
						       AND snap.sql_id = txt.sql_id);


         COMMIT;
      END IF;
   END;

---------------------------------------------------------
--- Create main snapshot row
---------------------------------------------------------
   PROCEDURE init_snapshot_internal (p_reset BOOLEAN := FALSE)
   IS
      l_snapshot_timestamp        DATE    := SYSDATE;
      l_prev_snapshot_timestamp   DATE;
      l_db_start_time             DATE;
      l_instance_id               INTEGER;
   BEGIN
      g_current_snapshot_id := next_snapshot_id ();
      l_instance_id := get_instance_id ();
      l_snapshot_timestamp := SYSDATE;
      l_db_start_time := db_start_time ();
      g_db_restart_flag := 0;

      IF     prev_snapshot (g_prev_snapshot_id, l_prev_snapshot_timestamp)
         AND (l_prev_snapshot_timestamp > l_db_start_time)
         AND (p_reset = FALSE)
      THEN
         g_snapshot_duration :=
            seconds_between (l_snapshot_timestamp, l_prev_snapshot_timestamp);
      ELSE           -- instance restart since last snapshot or first snapshot
         g_db_restart_flag := 1;
         g_snapshot_duration :=
                      seconds_between (l_snapshot_timestamp, l_db_start_time);
      END IF;

      IF g_snapshot_duration > 0 AND g_snapshot_duration < 1
      THEN
         raise_application_error (-20010,
                                  'Less than 1 second  between snapshots '
                                 );
      END IF;

      INSERT INTO quest_ppcm_snapshot
                  (snapshot_id, instance_id,
                   snapshot_timestamp, db_start_time,
                   snapshot_duration, db_restart_flag,
                   snapshot_type
                  )
           VALUES (g_current_snapshot_id, l_instance_id,
                   l_snapshot_timestamp, l_db_start_time,
                   g_snapshot_duration, g_db_restart_flag,
                   g_snapshot_type
                  );
   END;

   -- Take a snapshot, calc rates
   PROCEDURE init_snapshot
   IS
   BEGIN
      init_snapshot_internal (FALSE);
   END;

   -- Take a snapshot, no rates
   PROCEDURE init_snapshot_reset
   IS
   BEGIN
      init_snapshot_internal (p_reset => TRUE);
   END;

----------------------------------------------------
-- take snapshot of v$system_event/sys_time_model
----------------------------------------------------
   PROCEDURE event_snapshot
   IS
   BEGIN
      NULL;
   /* -----------------------------------------------------
      This routine not implemented in 10.0;  View is
      version dependent
      ------------------------------------------------------
   IF g_db_restart_flag = 1             -- First snapshot since DB restart
   THEN
      INSERT INTO quest_ppcm_event_snapshot
                  (snapshot_id, category_id, raw_waits, delta_waits,
                   wait_rate, raw_time, delta_time, time_rate)
         SELECT g_current_snapshot_id, category_id, total_waits raw_waits,
                total_waits delta_waits,
                total_waits / g_snapshot_duration wait_rate,
                time_waited_micro / 1000 raw_time,
                time_waited_micro / 1000 delta_time,
                (time_waited_micro / 1000) / g_snapshot_duration
                                                                time_rate
           FROM quest_ppcm_category_stats_view;
   ELSE
      INSERT INTO quest_ppcm_event_snapshot
                  (snapshot_id, category_id, raw_waits, delta_waits,
                   wait_rate, raw_time, delta_time, time_rate)
         SELECT g_current_snapshot_id, category_id,
                s2.raw_waits raw_waits,
                s2.raw_waits - s1.raw_waits delta_waits,
                  (s2.raw_waits - s1.raw_waits)
                / g_snapshot_duration wait_rate,
                s2.raw_time raw_time,
                s2.raw_time - s1.raw_time delta_time,
                  (s2.raw_time - s1.raw_time)
                / g_snapshot_duration time_rate
           FROM quest_ppcm_event_snapshot s1
                JOIN
                (SELECT category_id, total_waits raw_waits,
                        total_waits delta_waits,
                        total_waits / g_snapshot_duration wait_rate,
                        time_waited_micro / 1000 raw_time,
                        time_waited_micro / 1000 delta_time,
                          (time_waited_micro / 1000)
                        / g_snapshot_duration time_rate
                   FROM quest_ppcm_category_stats_view) s2 USING (category_id)
          WHERE snapshot_id = g_prev_snapshot_id;
   END IF; */
   END;

   FUNCTION sql_filter_clause
      RETURN VARCHAR2
   IS
      TYPE varchar_tab_typ IS TABLE OF VARCHAR (1000)
         INDEX BY BINARY_INTEGER;

      l_where_text   varchar_tab_typ;
      l_output       VARCHAR2 (2000);
   BEGIN
      FOR r IN (SELECT *
                  FROM quest_ppcm_sql_criteria)
      LOOP
         IF LENGTH (r.parsing_user_include_list) > 0
         THEN
            l_where_text (l_where_text.COUNT + 1) :=
                          'u.name in (' || r.parsing_user_include_list || ')';
         ELSIF LENGTH (r.parsing_user_exclude_list) > 0
         THEN
            l_where_text (l_where_text.COUNT + 1) :=
                      'u.name not in (' || r.parsing_user_exclude_list || ')';
         END IF;

         IF r.minimum_executions IS NOT NULL
         THEN
            l_where_text (l_where_text.COUNT + 1) :=
                                    's.executions > ' || r.minimum_executions;
         END IF;

         IF r.minimum_gets_per_exec IS NOT NULL
         THEN
            l_where_text (l_where_text.COUNT + 1) :=
                  'executions>0 and s.buffer_gets/s.executions > '
               || r.minimum_gets_per_exec;
         END IF;
      END LOOP;

      IF l_where_text.COUNT > 0
      THEN
         l_output := ' where ' || l_where_text (1);
      END IF;

      FOR i IN 2 .. l_where_text.COUNT
      LOOP
         l_output := l_output || ' and ' || l_where_text (i);
      END LOOP;

      DBMS_OUTPUT.put_line (l_output);
      RETURN (l_output);
   END;

-----------------------------------------
-- Generate the dynamic SQL to query v$sql
-- Query contains WHERE criteria from
--   quest_ppcm_sql_criteria
-----------------------------------------
   FUNCTION get_sql_query
      RETURN VARCHAR2
   IS
      l_sql_text    VARCHAR2 (4000);
      l_sql_text2   VARCHAR2 (1000);
      i             NUMBER          := 1;
   BEGIN
      IF dbversion LIKE '9.%'
      THEN
         l_sql_text :=
            '
        SELECT s.hash_value, s.executions executions, s.buffer_gets buffer_gets,
            s.elapsed_time elapsed_time, s.disk_reads disk_reads,
            s.cpu_time cpu_time, s.user_io_wait_time user_io_wait_time,
            s.concurrency_wait_time concurrency_wait_time,
            s.cluster_wait_time cluster_wait_time,
            s.application_wait_time application_wait_time,
            pss.executions prev_executions, pss.buffer_gets prev_buffer_gets,
            pss.elapsed_time prev_elapsed_time, pss.disk_reads prev_disk_reads,
            pss.cpu_time prev_cpu_time,
            pss.user_io_wait_time prev_user_io_wait_time,
            pss.concurrency_wait_time prev_concurrency_wait_time,
            pss.cluster_wait_time prev_cluster_wait_time,
            pss.application_wait_time prev_application_wait_time,
            null avg_plan_hash_value
           FROM (SELECT   hash_value,SUM (executions) executions,
                 SUM (buffer_gets) buffer_gets,
                 SUM (elapsed_time) elapsed_time, SUM (disk_reads) disk_reads,
                 SUM (cpu_time) cpu_time,
                 null user_io_wait_time,
                 null concurrency_wait_time,
                 null cluster_wait_time,
                 null application_wait_time
            FROM v$sql s JOIN sys.user$ u ON (s.parsing_user_id=u.user#)  ';
         l_sql_text2 :=
            '
             GROUP BY hash_value
             HAVING SUM(executions)>0 ) s
             LEFT OUTER JOIN
                quest_ppcm_sql_snapshot pss
             ON (pss.instance_id=:1 AND s.hash_value = pss.sql_id AND pss.snapshot_id = NVL (:2, -1))
              ';
      ELSE
         l_sql_text :=
            '

        SELECT s.sql_id, s.executions executions, s.buffer_gets buffer_gets,
              s.elapsed_time elapsed_time, s.disk_reads disk_reads,
              s.cpu_time cpu_time, s.user_io_wait_time user_io_wait_time,
              s.concurrency_wait_time concurrency_wait_time,
              s.cluster_wait_time cluster_wait_time,
               s.application_wait_time application_wait_time,
               pss.executions prev_executions, pss.buffer_gets prev_buffer_gets,
               pss.elapsed_time prev_elapsed_time, pss.disk_reads prev_disk_reads,
               pss.cpu_time prev_cpu_time,
               pss.user_io_wait_time prev_user_io_wait_time,
              pss.concurrency_wait_time prev_concurrency_wait_time,
              pss.cluster_wait_time prev_cluster_wait_time,
              pss.application_wait_time prev_application_wait_time,
              s.avg_plan_hash_value
          FROM (SELECT   sql_id,SUM (executions) executions,
                         SUM (buffer_gets) buffer_gets,
                         SUM (elapsed_time) elapsed_time, SUM (disk_reads) disk_reads,
                         SUM (cpu_time) cpu_time,
                         SUM (user_io_wait_time) user_io_wait_time,
                         SUM (concurrency_wait_time) concurrency_wait_time,
                         SUM (cluster_wait_time) cluster_wait_time,
                         SUM (application_wait_time) application_wait_time,
                         AVG(plan_hash_value) avg_plan_hash_value
                  FROM v$sql s JOIN sys.user$ u ON (s.parsing_user_id=u.user# )
                   ';
         l_sql_text2 :=
            '
                GROUP BY sql_id
                 HAVING SUM(executions)>0 ) s
             LEFT OUTER JOIN
                quest_ppcm_sql_snapshot pss
                 ON (pss.instance_id=:1 AND s.sql_id = pss.sql_id AND pss.snapshot_id = NVL (:2, -1))
              ';
      END IF;

      i := 1;
      l_sql_text := l_sql_text || sql_filter_clause () || l_sql_text2;
      DBMS_OUTPUT.put_line (l_sql_text);
      RETURN (l_sql_text);
   END;

   PROCEDURE remove_snapshot_job
   IS
      CURSOR c_jobs
      IS
         SELECT job
           FROM all_jobs
          WHERE what LIKE '%Quest SOO PPCM job%' AND broken = 'N';
   BEGIN
      FOR r IN c_jobs
      LOOP
         DBMS_OUTPUT.put_line ('Removing ' || r.job);
         DBMS_JOB.remove (r.job);
      END LOOP;

      COMMIT;
   END;

   FUNCTION submit_snapshot_job (
      p_first_time_hhmm   VARCHAR2,
      p_interval_hrs      INTEGER
   )
      RETURN NUMBER
   IS
      v_job_str         VARCHAR2 (1000);
      v_job_no          NUMBER;
      v_interval_days   NUMBER;
      v_comment_text    VARCHAR2 (2000);
      v_first_time      DATE;

      TYPE num_typ IS TABLE OF NUMBER
         INDEX BY BINARY_INTEGER;

      v_instance_list   num_typ;
   BEGIN
      remove_snapshot_job;

      IF p_interval_hrs = 0.0
      THEN
         RETURN (0);
      END IF;

      v_first_time :=
         TO_DATE (TO_CHAR (SYSDATE, 'DDMMYY') || p_first_time_hhmm,
                  'DDMMYYHH24MI'
                 );
      v_job_str :=
            'BEGIN /*Quest SOO PPCM job */ '
         || ' quest_ppcm_snapshot_pkg.take_snapshot; END;';
      v_interval_days := p_interval_hrs / 24;
      v_first_time :=
         TO_DATE (TO_CHAR (SYSDATE, 'DDMMYY') || p_first_time_hhmm,
                  'DDMMYYHH24MI'
                 );

      IF v_first_time < SYSDATE
      THEN
         v_first_time := v_first_time + 1;
      END IF;

      SELECT inst_number
      BULK COLLECT INTO v_instance_list
        FROM v$active_instances;

      IF v_instance_list.COUNT () = 0
      THEN                                     /* Single instance of Oracle */
         DBMS_JOB.submit (job            => v_job_no,
                          what           => v_job_str,
                          next_date      => v_first_time,
                          INTERVAL       =>    'SYSDATE+'
                                            || to_char(ROUND (v_interval_days, 4), '9999.9999'),
                          INSTANCE       => userenv('instance')
                         );
      ELSE             /* Create a job for each instance in the RAC cluster */
         FOR i IN 1 .. v_instance_list.COUNT ()
         LOOP
            DBMS_JOB.submit (job            => v_job_no,
                             what           => v_job_str,
                             next_date      => v_first_time,
                             INTERVAL       =>    'SYSDATE+'
                                               || to_char(ROUND (v_interval_days, 4), '9999.9999'),
                             INSTANCE       => v_instance_list (i)
                            );
         END LOOP;
      END IF;

      COMMIT;
      RETURN (v_job_no);
   END;

------------------------------------------------------
-- save the sql_text if it isn't already there....
------------------------------------------------------
   FUNCTION check_sql_text (p_sql_id VARCHAR2) RETURN BOOLEAN
   IS
      l_count      INTEGER;
      l_version    VARCHAR2 (20);
      l_sql_stmt   VARCHAR2 (1000);
   BEGIN
      SELECT COUNT (*)
        INTO l_count
        FROM quest_ppcm_sql_text
       WHERE instance_id = g_instance_id AND sql_id = p_sql_id;

      IF l_count = 0
      THEN
         l_version := dbversion;

         IF l_version LIKE '9%'
         THEN
            l_sql_stmt :=
               ' INSERT INTO quest_ppcm_sql_text
                        (instance_id, sql_id, sql_text, sql_fulltext,parsing_user_name )
                SELECT :instance_id,hash_value, sql_text, sql_text,user$.name
                  FROM v$sql join sys.user$ on (v$sql.parsing_user_id=user$.user#)
                 WHERE hash_value = :sql_id AND child_number =
                 (select min(child_number) from v$sql where hash_value=:sql_id)
                 AND rownum = 1';
         ELSE
            l_sql_stmt :=
               'INSERT INTO quest_ppcm_sql_text
                        (instance_id, sql_id, sql_text, sql_fulltext,parsing_user_name)
                SELECT :instance_id, sql_id, sql_text, sql_fulltext,user$.name
                  FROM v$sql join sys.user$ on (v$sql.parsing_user_id=user$.user#)
                 WHERE sql_id = :sql_id AND child_number =
                    (select min(child_number) from v$sql where sql_id=:sql_id)
                    AND rownum = 1';
         END IF;

         EXECUTE IMMEDIATE l_sql_stmt
                     USING g_instance_id, p_sql_id, p_sql_id;

         IF SQL%ROWCOUNT = 0 THEN
            RETURN FALSE;
         ELSE
            RETURN TRUE;
         END IF;
      ELSE
         RETURN TRUE;
      END IF;
   END;

-----------------------------------------
-- Create a snapshot of SQL activity
-----------------------------------------
   PROCEDURE sql_snapshot
   IS
      TYPE sqlcurtyp IS REF CURSOR;

      TYPE numlist IS TABLE OF NUMBER
         INDEX BY BINARY_INTEGER;

      TYPE varlist IS TABLE OF VARCHAR2 (1000)
         INDEX BY BINARY_INTEGER;

      sql_cv                         sqlcurtyp;
      l_sql_id                       varlist;
      l_executions                   numlist;
      l_buffer_gets                  numlist;
      l_elapsed_time                 numlist;
      l_disk_reads                   numlist;
      l_cpu_time                     numlist;
      l_user_io_wait_time            numlist;
      l_concurrency_wait_time        numlist;
      l_cluster_wait_time            numlist;
      l_application_wait_time        numlist;
      l_prev_executions              numlist;
      l_prev_buffer_gets             numlist;
      l_prev_elapsed_time            numlist;
      l_prev_disk_reads              numlist;
      l_prev_cpu_time                numlist;
      l_prev_user_io_wait_time       numlist;
      l_prev_concurrency_wait_time   numlist;
      l_prev_cluster_wait_time       numlist;
      l_prev_application_wait_time   numlist;
      l_avg_plan_hash_value          numlist;
      l_sql_text                     VARCHAR (4000);
   BEGIN
      l_sql_text := get_sql_query ();

      OPEN sql_cv FOR l_sql_text USING g_instance_id, g_prev_snapshot_id;

      FETCH sql_cv
      BULK COLLECT INTO l_sql_id, l_executions, l_buffer_gets,
             l_elapsed_time, l_disk_reads, l_cpu_time, l_user_io_wait_time,
             l_concurrency_wait_time, l_cluster_wait_time,
             l_application_wait_time, l_prev_executions, l_prev_buffer_gets,
             l_prev_elapsed_time, l_prev_disk_reads, l_prev_cpu_time,
             l_prev_user_io_wait_time, l_prev_concurrency_wait_time,
             l_prev_cluster_wait_time, l_prev_application_wait_time,
             l_avg_plan_hash_value;

      CLOSE sql_cv;

      FOR i IN 1 .. l_sql_id.COUNT ()
      LOOP
         IF l_prev_executions (i) IS NULL OR g_db_restart_flag = 1
         THEN
            --No previous record of this SQL or the db has had a restart
            IF l_prev_executions (i) IS NULL
            THEN
               IF check_sql_text (l_sql_id (i)) THEN
                  INSERT INTO quest_ppcm_sql_snapshot
                           (snapshot_id, instance_id, sql_id,
                            executions, buffer_gets,
                            elapsed_time, disk_reads,
                            cpu_time, user_io_wait_time,
                            concurrency_wait_time,
                            cluster_wait_time, application_wait_time,
                            avg_plan_hash_value
                           )
                    VALUES (g_current_snapshot_id, g_instance_id, l_sql_id (i),
                            l_executions (i), l_buffer_gets (i),
                            l_elapsed_time (i), l_disk_reads (i),
                            l_cpu_time (i), l_user_io_wait_time (i),
                            l_concurrency_wait_time (i),
                            l_cluster_wait_time (i), l_application_wait_time (i),
                            l_avg_plan_hash_value(i)
                           );
               END IF;
            END IF;

         ELSE
            INSERT INTO quest_ppcm_sql_snapshot
                        (snapshot_id, instance_id, sql_id,
                         executions, buffer_gets,
                         elapsed_time, disk_reads,
                         cpu_time, user_io_wait_time,
                         concurrency_wait_time,
                         cluster_wait_time,
                         application_wait_time,
                         executions_rate,
                         buffer_gets_rate,
                         elapsed_time_rate,
                         disk_reads_rate,
                         cpu_time_rate,
                         user_io_wait_time_rate,
                         concurrency_wait_time_rate,
                         cluster_wait_time_rate,
                         application_wait_time_rate,
                         avg_plan_hash_value
                        )
                 VALUES (g_current_snapshot_id, g_instance_id, l_sql_id (i),
                         l_executions (i), l_buffer_gets (i),
                         l_elapsed_time (i), l_disk_reads (i),
                         l_cpu_time (i), l_user_io_wait_time (i),
                         l_concurrency_wait_time (i),
                         l_cluster_wait_time (i),
                         l_application_wait_time (i),
                           (l_executions (i) - l_prev_executions (i)
                           )
                         / g_snapshot_duration,
                           (l_buffer_gets (i) - l_prev_buffer_gets (i)
                           )
                         / g_snapshot_duration,
                           (l_elapsed_time (i) - l_prev_elapsed_time (i)
                           )
                         / g_snapshot_duration,
                           (l_disk_reads (i) - l_prev_disk_reads (i)
                           )
                         / g_snapshot_duration,
                           (l_cpu_time (i) - l_prev_cpu_time (i)
                           )
                         / g_snapshot_duration,
                           (  l_user_io_wait_time (i)
                            - l_prev_user_io_wait_time (i)
                           )
                         / g_snapshot_duration,
                           (  l_concurrency_wait_time (i)
                            - l_prev_concurrency_wait_time (i)
                           )
                         / g_snapshot_duration,
                           (  l_cluster_wait_time (i)
                            - l_prev_cluster_wait_time (i)
                           )
                         / g_snapshot_duration,
                           (  l_application_wait_time (i)
                            - l_prev_application_wait_time (i)
                           )
                         / g_snapshot_duration,
                         l_avg_plan_hash_value(i)
                        );
         END IF;
      END LOOP;
   END;

-----------------------------------------
-- Take a snapshot of various "statistics"
-- Not SQLs, and not event based
-----------------------------------------
   PROCEDURE stat_snapshot
   IS
   BEGIN
      NULL;
   /* ------------------------------------------------------------
      Not implemented in 1.0; version dependencies
      -----------------------------------------------------------
   IF g_db_restart_flag = 1
   THEN
      INSERT INTO quest_ppcm_statistic_snap
                  (snapshot_id, statistic_id, raw_value)
         SELECT g_current_snapshot_id, statistic_id, VALUE
           FROM quest_ppcm_other_stats_view;
   ELSE
      INSERT INTO quest_ppcm_statistic_snap
                  (snapshot_id, statistic_id, raw_value, delta_value,
                   rate_value)
         SELECT g_current_snapshot_id, v.statistic_id, v.VALUE,
                v.VALUE - s.raw_value,
                (v.VALUE - s.raw_value) / g_snapshot_duration
           FROM quest_ppcm_other_stats_view v LEFT OUTER JOIN quest_ppcm_statistic_snap s
                ON (    v.statistic_id = s.statistic_id
                    AND s.snapshot_id = g_prev_snapshot_id
                   )
                ;
   END IF; */
   END;


-----------------------------------------
--  Take a standard snapshot
-----------------------------------------
   PROCEDURE take_snapshot_internal (reset_flag BOOLEAN)
   IS
   BEGIN
      /* Disable parallel query CR 9869 */
      BEGIN
         EXECUTE IMMEDIATE 'alter session disable parallel query';
      EXCEPTION
         WHEN OTHERS THEN
            null;
      END;

      IF (reset_flag = TRUE)
      THEN
         init_snapshot_reset;
      ELSE
         init_snapshot ();
      END IF;

      event_snapshot ();
      stat_snapshot ();
      sql_snapshot ();
      COMMIT;
      purge_snapshots; -- Remove old snapshots
      EXCEPTION WHEN OTHERS THEN
         /* Log exception and continue - this stops errors appearing in the alert log */
         quest_soo_tracing.process_exception(gc_package_name,'TAKE_SNAPSHOT_INTERNAL',0,sqlcode,sqlerrm);
   END;

   PROCEDURE take_snapshot
   IS
   BEGIN
      take_snapshot_internal (reset_flag => FALSE);
   END;

   PROCEDURE take_snapshot_reset
   IS
   BEGIN
      take_snapshot_internal (reset_flag => TRUE);
   END;
END;
/
