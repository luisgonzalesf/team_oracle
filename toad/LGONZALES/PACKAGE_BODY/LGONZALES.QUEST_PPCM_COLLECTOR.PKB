CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_ppcm_collector
IS
   gc_job_prefix CONSTANT   VARCHAR2 (20) := 'QUEST_PPCM_JOB_';
   gc_retention_days_param CONSTANT VARCHAR2 (30)
         := 'SNAPSHOT_RETENTION_DAYS' ;
   gc_package_name       CONSTANT  VARCHAR2(50) := 'QUEST_PPCM_COLLECTOR';

   /*
     Generate a new snapshot ID based off the sequence
   */
   FUNCTION new_snapshot_id
      RETURN PLS_INTEGER
   IS
      l_snapshot_id   PLS_INTEGER;
   BEGIN
      SELECT   quest_ppcm_snapshot_id_s.NEXTVAL INTO l_snapshot_id FROM DUAL;

      RETURN (l_snapshot_id);
   END new_snapshot_id;

   /*
     Get the instance ID of the current connection
     Check if the instance has been added to quest_ppcm_instance, if not then insert it
   */

   FUNCTION get_instance_id
      RETURN PLS_INTEGER
   IS
      l_instance_id   NUMBER;
      l_count         NUMBER;
   BEGIN
      l_instance_id := USERENV ('Instance');

      SELECT   COUNT ( * )
        INTO   l_count
        FROM   quest_ppcm_instance
       WHERE   instance_id = l_instance_id;

      IF l_count = 0
      THEN
        EXECUTE IMMEDIATE 'INSERT INTO quest_ppcm_instance (instance_id, instance_name, host_name)
                                SELECT   :l_instance_id, instance_name, host_name
                                FROM   v$instance' USING l_instance_id;
      END IF;

      RETURN l_instance_id;
   END get_instance_id;

   /*
     Get the time that the current instance was started up
   */

   FUNCTION get_instance_start_time
      RETURN DATE
   IS
      l_instance_start_time   DATE;
   BEGIN
      EXECUTE IMMEDIATE 'SELECT startup_time FROM v$instance'
            INTO l_instance_start_time;

      RETURN l_instance_start_time;
   END get_instance_start_time;

   /*
     Get the previous snapshot based on the snapshot type given and optionally the snapshot ID
     If no snapshot ID is specified it will get the latest one taken
   */

   FUNCTION get_prev_snapshot (i_snapshot_type    VARCHAR2,
                               i_snapshot_id      NUMBER := NULL)
      RETURN quest_ppcm_snapshot%ROWTYPE
   IS
      l_cur_snapshot_timestamp   DATE;
      l_prev_snapshot            quest_ppcm_snapshot%ROWTYPE;
      l_instance_id              NUMBER;
   BEGIN
      /* Get the date of the snapshot ID given, or if no snapshot ID is given, set it to now */
      IF i_snapshot_id IS NULL
      THEN
         l_cur_snapshot_timestamp := SYSDATE;
      ELSE
         SELECT   snapshot_timestamp
           INTO   l_cur_snapshot_timestamp
           FROM   quest_ppcm_snapshot
          WHERE   snapshot_id = i_snapshot_id;
      END IF;

      l_instance_id := get_instance_id;

      /* Get the record for the previous snapshot, or if it cannot be found, return null. This could happen when it is the first snapshot taken */
      BEGIN
         SELECT   *
           INTO   l_prev_snapshot
           FROM   (  SELECT   *
                       FROM   quest_ppcm_snapshot
                      WHERE       snapshot_timestamp < l_cur_snapshot_timestamp
                              AND snapshot_type = i_snapshot_type
                              AND instance_id = l_instance_id
                   ORDER BY   snapshot_timestamp DESC)
          WHERE   ROWNUM = 1;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            RETURN NULL;
      END;

      RETURN l_prev_snapshot;
   END get_prev_snapshot;

   /*
     Create a new snapshot of the given type - this will create the header record and return the details of both the current and previous snapshot which need to be used to insert the child records
   */

   PROCEDURE create_snapshot (
      i_snapshot_type   IN            VARCHAR2,
      o_new_snapshot       OUT NOCOPY quest_ppcm_snapshot%ROWTYPE,
      o_prev_snapshot      OUT NOCOPY quest_ppcm_snapshot%ROWTYPE
   )
   IS
   BEGIN
      /* Get values for previous snapshot which are needed to calculate the duration between snapshots and whether the database has been restarted */
      o_prev_snapshot := get_prev_snapshot (i_snapshot_type);

      /* Initialize the current snapshot values */
      o_new_snapshot.snapshot_type := i_snapshot_type;
      o_new_snapshot.snapshot_id := new_snapshot_id;
      o_new_snapshot.instance_id := get_instance_id;
      o_new_snapshot.db_start_time := get_instance_start_time;
      o_new_snapshot.snapshot_timestamp := SYSDATE;
      o_new_snapshot.snapshot_duration :=
         NVL (
            o_new_snapshot.snapshot_timestamp
            - o_prev_snapshot.snapshot_timestamp,
            0
         )
         * 24
         * 60
         * 60;

      IF o_prev_snapshot.db_start_time = o_new_snapshot.db_start_time
      THEN
         o_new_snapshot.db_restart_flag := 0;
      ELSE
         o_new_snapshot.db_restart_flag := 1;
      END IF;

      /* Save the newly generated snapshot to the database */

      INSERT INTO quest_ppcm_snapshot
        VALUES   o_new_snapshot;
   END create_snapshot;

   /*
     Take a snapshot of a given type, create the header record then call the appropriate procedure to capture details
   */

   PROCEDURE take_snapshot (i_snapshot_type IN VARCHAR2)
   IS
      l_prev_snapshot   quest_ppcm_snapshot%ROWTYPE;
      l_new_snapshot    quest_ppcm_snapshot%ROWTYPE;
      l_statistics_level       VARCHAR2 (4000);
      l_db_cache_advice        VARCHAR2 (4000);
      l_timed_statistics       VARCHAR2 (4000);
   BEGIN
      /* Disable parallel query CR 9869 */
      BEGIN
         EXECUTE IMMEDIATE 'alter session disable parallel query';
      EXCEPTION
         WHEN OTHERS THEN
            null;
      END;

      /* Get parameter values to be checked */
      EXECUTE IMMEDIATE 'SELECT   UPPER (VALUE)
                         FROM   v$parameter
                         WHERE   name = ''statistics_level'''
              INTO l_statistics_level;

      EXECUTE IMMEDIATE 'SELECT   UPPER (VALUE)
                         FROM   v$parameter
                         WHERE   name = ''db_cache_advice'''
              INTO l_db_cache_advice;

      EXECUTE IMMEDIATE 'SELECT   UPPER (VALUE)
                         FROM   v$parameter
                         WHERE   name = ''timed_statistics'''
              INTO l_timed_statistics;

      IF     l_timed_statistics = 'TRUE'
         AND l_statistics_level <> 'BASIC'
         AND l_db_cache_advice = 'ON'
      THEN
         /* Create the header for the snapshot */
         create_snapshot (i_snapshot_type, l_new_snapshot, l_prev_snapshot);

         IF i_snapshot_type = 'PM'
         THEN
            /* Performance Modelling */
            quest_ppcm_collector_pm.take_snapshot (l_new_snapshot,
                                                   l_prev_snapshot);
         ELSE
            raise_application_error (en_invalid_snapshot_type,
                                     'Invalid snapshot type');
         END IF;

         IF l_prev_snapshot.snapshot_timestamp IS NOT NULL
            AND (TRUNC (l_new_snapshot.snapshot_timestamp)
                 - TRUNC (l_prev_snapshot.snapshot_timestamp)) >= 1
         THEN
            purge_snapshots (i_snapshot_type);
         END IF;

         COMMIT;
      END IF;

      EXCEPTION WHEN OTHERS THEN
         /* Log exception and continue - this stops errors appearing in the alert log */
         quest_soo_tracing.process_exception(gc_package_name,'TAKE_SNAPSHOT',0,sqlcode,sqlerrm);
   END take_snapshot;

   /*
     Remove the job all together
   */

   PROCEDURE remove_job (i_snapshot_type IN VARCHAR2)
   IS
      l_job_action VARCHAR2 (4000)
            :=    'BEGIN quest_ppcm_collector.take_snapshot('''
               || i_snapshot_type
               || '''); END;' ;

      $IF DBMS_DB_VERSION.ver_le_10 $THEN
         /* Use dbms_job for 10g */
         CURSOR c_jobs
         IS
            SELECT   job
              FROM   user_jobs
             WHERE   what = l_job_action;

      $ELSE
         /* Use dbms_scheduler for versions newer than 10g */
         CURSOR c_jobs
         IS
            SELECT   job_name
              FROM   user_scheduler_jobs
             WHERE   job_name =
                        gc_job_prefix || i_snapshot_type || '_' || instance_id;
      $END
   BEGIN
      IF i_snapshot_type NOT IN ('PM') OR i_snapshot_type IS NULL
      THEN
         raise_application_error (en_invalid_snapshot_type,
                                  'Invalid snapshot type');
      END IF;

      FOR r IN c_jobs
      LOOP
         $IF DBMS_DB_VERSION.ver_le_10 $THEN
            /* Use dbms_job for 10g */
            DBMS_JOB.remove (r.job);
         $ELSE
            /* Use dbms_scheduler for versions newer than 10g */
            DBMS_SCHEDULER.drop_job (r.job_name);
         $END
      END LOOP;

      COMMIT;
   END remove_job;

   /*
     Setup the job for a given snapshot type. If the job does not exist it will be created, if it does exist it will be updated.
       i_repeat_minutes - the number of minutes between collections - if this is 0 then the job will be deleted
       i_start_date     - the date/time at which the collection should start
   */

   PROCEDURE setup_job (i_snapshot_type    IN VARCHAR2,
                        i_repeat_minutes   IN NUMBER,
                        i_start_date       IN timestamp WITH TIME ZONE)
   IS
      TYPE number_table
      IS
         TABLE OF NUMBER
            INDEX BY PLS_INTEGER;

      TYPE typ_jobs_record
      IS
         RECORD (
            instance_id       NUMBER,
            job_action        VARCHAR2 (4000),
            job_type          VARCHAR2 (16),
            repeat_interval   VARCHAR2 (4000),
            START_DATE        timestamp
         );

      l_job_name        VARCHAR2 (30);
      l_job_action VARCHAR2 (4000)
            :=    'BEGIN quest_ppcm_collector.take_snapshot('''
               || i_snapshot_type
               || '''); END;' ;
      l_job_type        VARCHAR2 (16) := 'PLSQL_BLOCK';
      l_repeat_interval VARCHAR2 (4000)
            := 'FREQ=MINUTELY;INTERVAL=' || i_repeat_minutes ;
      l_job_record      typ_jobs_record;
      l_instance_list   number_table;
      l_job_no          NUMBER;
   BEGIN
      /* If the i_repeat_minutes is null or less than or equal to zero, then remove the job instead */
      IF i_repeat_minutes IS NULL OR i_repeat_minutes <= 0
      THEN
         remove_job (i_snapshot_type);
      ELSE
         /* If it is 10g then remove the job - it will be re-created */
         $IF DBMS_DB_VERSION.ver_le_10 $THEN
         remove_job (i_snapshot_type);

         $END
         /* Get a list of active instances for RAC */
         SELECT   inst_number
           BULK   COLLECT
           INTO   l_instance_list
           FROM   v$active_instances;

         /* If no active instances found (ie - database is not a RAC) then add the current instance to the collection */
         IF l_instance_list.COUNT = 0
         THEN
            l_instance_list (1) := USERENV ('instance');
         END IF;

         /* Create / modify the job for each instance */
         FOR i IN 1 .. l_instance_list.COUNT
         LOOP
            /* Use dbms_job for 10g */
            $IF DBMS_DB_VERSION.ver_le_10 $THEN
            DBMS_JOB.submit (
               job         => l_job_no,
               what        => l_job_action,
               next_date   => CAST (i_start_date AS date),
               INTERVAL    => 'SYSDATE+(' || i_repeat_minutes || ' / (24*60))',
               INSTANCE    => l_instance_list (i)
            );
            $ELSE

            /* Use dbms_scheduler for versions newer than 10g */
            l_job_name :=
               gc_job_prefix || i_snapshot_type || '_' || l_instance_list (i);

            BEGIN
               /* Select the job for the instance, if it cannot be found then raise exception */
               SELECT   instance_id,
                        job_action,
                        job_type,
                        repeat_interval,
                        start_date
                 INTO   l_job_record
                 FROM   user_scheduler_jobs
                WHERE   job_name = l_job_name;

               /* If the instance_id attribute is not set or is incorrect, then set it */
               IF l_job_record.instance_id IS NULL
                  OR l_job_record.instance_id <> l_instance_list (i)
               THEN
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'INSTANCE_ID',
                                                l_instance_list (i));
               END IF;

               /* If the job action is not set or is incorrect then set it */
               IF    l_job_record.job_type IS NULL
                  OR l_job_record.job_action IS NULL
                  OR l_job_record.job_type <> l_job_type
                  OR l_job_record.job_action <> l_job_action
               THEN
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'JOB_TYPE',
                                                l_job_type);
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'JOB_ACTION',
                                                l_job_action);
               END IF;

               /* If the repeat interval is not set or is incorrect then set it */
               IF l_job_record.repeat_interval IS NULL
                  OR l_job_record.repeat_interval <> l_repeat_interval
               THEN
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'REPEAT_INTERVAL',
                                                l_repeat_interval);
               END IF;

               /* If the start date is not set or is incorrect then set it */
               IF l_job_record.start_date IS NULL
                  OR l_job_record.start_date <> i_start_date
               THEN
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'START_DATE',
                                                i_start_date);
               END IF;
            EXCEPTION
               WHEN NO_DATA_FOUND
               THEN
                  /* When the job cannot be found, then create it and set the instance_id attribute */

                  DBMS_SCHEDULER.create_job (
                     job_name          => l_job_name,
                     job_type          => l_job_type,
                     job_action        => l_job_action,
                     start_date        => i_start_date,
                     repeat_interval   => l_repeat_interval,
                     enabled           => FALSE,
                     auto_drop         => FALSE
                  );
                  DBMS_SCHEDULER.set_attribute (l_job_name,
                                                'INSTANCE_ID',
                                                l_instance_list (i));
            END;

            /* Now the job is set up correctly, enable it */
            DBMS_SCHEDULER.enable (l_job_name);
         $END
         END LOOP;
      END IF;

      COMMIT;
   END setup_job;

   /*
     Get the job repeat interval in minutes based off the start date and calendar string from dba_scheduler_jobs
   */

   FUNCTION get_job_repeat_minutes (
      i_start_date        IN timestamp WITH TIME ZONE,
      i_calendar_string   IN VARCHAR2
   )
      RETURN NUMBER
   IS
      l_next_run_date   timestamp WITH TIME ZONE;
   BEGIN
      DBMS_SCHEDULER.evaluate_calendar_string (
         calendar_string     => i_calendar_string,
         start_date          => i_start_date,
         return_date_after   => i_start_date,
         next_run_date       => l_next_run_date
      );
      RETURN   (CAST (l_next_run_date AS date) - CAST (i_start_date AS date))
             * 24
             * 60;
   END;

   /*
     Get the job repeat interval in minutes based off the interval string from dba_jobs
   */

   FUNCTION get_job_interval_minutes (i_job_interval IN VARCHAR2)
      RETURN NUMBER
   IS
      l_sql_exec   VARCHAR2 (200);
      l_interval   NUMBER;
   BEGIN
      l_sql_exec :=
         'SELECT (' || i_job_interval || ' - sysdate) * 60 * 24 from dual';

      EXECUTE IMMEDIATE l_sql_exec
              INTO l_interval;

      RETURN l_interval;
   END get_job_interval_minutes;

   /*
     Set a PPCM parameter
   */

   PROCEDURE set_ppcm_parameter (i_parameter_name     VARCHAR2,
                                 i_parameter_value    VARCHAR2)
   IS
      l_count               NUMBER;
   BEGIN

      BEGIN
         SELECT   COUNT ( * )
           INTO   l_count
           FROM   quest_ppcm_parameters
          WHERE   parameter_name = UPPER (i_parameter_name);

         IF l_count = 0
         THEN
            INSERT INTO quest_ppcm_parameters (
                                                  parameter_name,
                                                  parameter_value
                       )
              VALUES   (UPPER (i_parameter_name), i_parameter_value);
         ELSE
            UPDATE   quest_ppcm_parameters
               SET   parameter_value = i_parameter_value
             WHERE   parameter_name = UPPER (i_parameter_name);
         END IF;

         COMMIT;
      END;
   END;

   /*
     Get a PPCM parameter
   */

   FUNCTION get_ppcm_parameter (i_parameter_name VARCHAR2)
      RETURN VARCHAR2
   IS
      l_value   quest_ppcm_parameters.parameter_value%TYPE;
   BEGIN
      BEGIN
         SELECT   parameter_value
           INTO   l_value
           FROM   quest_ppcm_parameters
          WHERE   parameter_name = i_parameter_name;
      EXCEPTION
         WHEN NO_DATA_FOUND
         THEN
            NULL;
      END;

      RETURN l_value;
   END;

   /*
     Purge old snapshots
   */

   PROCEDURE purge_snapshots (i_snapshot_type IN VARCHAR2)
   IS
      l_snapshot_retention_days   NUMBER;
   BEGIN
      IF i_snapshot_type NOT IN ('PM') OR i_snapshot_type IS NULL
      THEN
         raise_application_error (en_invalid_snapshot_type,
                                  'Invalid snapshot type');
      END IF;

      l_snapshot_retention_days :=
         TO_NUMBER(get_ppcm_parameter (
                      i_snapshot_type || '_' || gc_retention_days_param
                   ));

      IF l_snapshot_retention_days IS NOT NULL
         AND l_snapshot_retention_days > 0
      THEN
         /* Delete all snapshots of this type, that are not sample data, and are older than the retention period.
            This should cascade down the constraints to delete all the data.
         */
         DELETE FROM   quest_ppcm_snapshot
               WHERE   snapshot_type = i_snapshot_type AND instance_id > 0
                       AND snapshot_timestamp <
                             TRUNC (SYSDATE) - l_snapshot_retention_days;
      END IF;
   END purge_snapshots;
END quest_ppcm_collector;
/
