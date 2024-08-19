CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_variable
AS
   gv_local_instance        varchar2(64);
   gv_dblink_test           PLS_INTEGER := 0;
   gv_dblink_retry          PLS_INTEGER := 0;
   EXCP_SEVERE_ERROR        EXCEPTION;
   PRAGMA EXCEPTION_INIT(EXCP_SEVERE_ERROR, -2068);

   GC_PACKAGE_NAME CONSTANT VARCHAR2(50) := 'QUEST_SOO_VARIABLE';

   FUNCTION create_dblink (p_target VARCHAR2)
      RETURN VARCHAR2
   IS
      lv_dblink   VARCHAR2 (100);

      LC_PROC_NAME CONSTANT VARCHAR2(50) := 'CREATE_DBLINK';
   BEGIN
      quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, 100, 'CREATE DATABASE link quest_soo_'
                            || p_target
                            || ' using '''
                            || p_target
                            || '''');
      BEGIN
          EXECUTE IMMEDIATE    'CREATE DATABASE link quest_soo_'
                            || p_target
                            || ' using '''
                            || p_target
                            || '''';
      EXCEPTION
        WHEN OTHERS THEN
        quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, SQLCODE, SQLERRM);
      END;

      BEGIN
      SELECT db_link
        INTO lv_dblink
        FROM user_db_links
       WHERE HOST = p_target AND db_link LIKE 'QUEST_SOO_%';
      EXCEPTION
        WHEN no_data_found THEN
            NULL;
      END;
      quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, 102, 'DB LINK:' || lv_dblink);

      IF lv_dblink IS NULL AND gv_dblink_retry < 5 THEN
          gv_dblink_retry := gv_dblink_retry + 1;
          lv_dblink := create_dblink(p_target);
      END IF;

      RETURN lv_dblink;
   END create_dblink;

   PROCEDURE populate_data IS
      LC_PROC_NAME CONSTANT VARCHAR2(50) := 'POPULATE_DATA';
   BEGIN
       quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, 100, 'Entry point');

       execute immediate 'SELECT instance_number,
                                  instance_name,
                                  host_name,
                                  db_link
                            FROM gv$instance inst, user_db_links dblink
                            WHERE logins = ''ALLOWED''
                              AND database_status = ''ACTIVE''
                              AND dblink.HOST(+) = instance_name
                              AND dblink.db_link(+) LIKE ''QUEST_SOO_%'''
               BULK COLLECT INTO grec_db_instance;

       execute immediate 'SELECT instance_name
                          FROM v$INSTANCE'
               INTO gv_local_instance ;

       quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, 101, 'Local instance:' || gv_local_instance);

       FOR idx IN 1 .. grec_db_instance.COUNT
       LOOP
          IF grec_db_instance (idx).instance_name =
                                         gv_local_instance
          THEN
             -- Set DB link to null;
             grec_db_instance (idx).db_link := NULL;
          ELSIF grec_db_instance (idx).db_link IS NULL
          THEN
             -- Set retry count to 0 so will try up to 5 times to create DB link
             gv_dblink_retry := 0;
             quest_soo_tracing.add_debug(GC_PACKAGE_NAME, LC_PROC_NAME, 102, 'Creating DB link for' || grec_db_instance (idx).instance_name);
             -- Create DB link and assign name
             grec_db_instance (idx).db_link :=
                             create_dblink (grec_db_instance (idx).instance_name);
          END IF;
       END LOOP;
   EXCEPTION
        WHEN others THEN
            quest_soo_tracing.process_exception(GC_PACKAGE_NAME, LC_PROC_NAME, 101, SQLCODE, SQLERRM);
   END populate_data;

   FUNCTION get_current_dblinks RETURN typ_db_rec_arr IS
        lrec    typ_db_rec_arr;
        lv_idx  PLS_INTEGER := 1;
        lv_test PLS_INTEGER;

        LC_PROC_NAME CONSTANT VARCHAR2(50) := 'GET_CURRENT_DBLINKS';
   BEGIN
        FOR idx IN 1..grec_db_instance.COUNT LOOP
            IF grec_db_instance(idx).db_link IS NULL THEN
                lrec(lv_idx) := grec_db_instance(idx);
                lv_idx := lv_idx + 1;
            ELSE
                BEGIN
                    execute IMMEDIATE 'select 1 from dual@' ||
                        grec_db_instance(idx).db_link
                    INTO lv_test;

                    lrec(lv_idx) := grec_db_instance(idx);
                    lv_idx := lv_idx + 1;
                EXCEPTION WHEN OTHERS  THEN
                    populate_data;
                    lrec.DELETE;
                    lv_idx := 1;
                    FOR lrec_idx IN 1..grec_db_instance.COUNT LOOP
                        IF grec_db_instance(lrec_idx).db_link IS NULL THEN
                            lrec(lv_idx) := grec_db_instance(lrec_idx);
                            lv_idx := lv_idx + 1;
                        ELSE
                            BEGIN
                                execute IMMEDIATE 'select 1 from dual@' ||
                                    grec_db_instance(lrec_idx).db_link
                                INTO lv_test;

                                lrec(lv_idx) := grec_db_instance(lrec_idx);
                                lv_idx := lv_idx + 1;
                            EXCEPTION
                                WHEN OTHERS THEN
                                    NULL;
                            END;
                        END IF;
                    END LOOP;
                    grec_db_instance := lrec;
                    EXIT;
                END;
            END IF;

        END LOOP;

        gv_dblink_test := gv_dblink_test + 1;
        RETURN lrec;
   EXCEPTION
    WHEN others THEN
        quest_soo_tracing.process_exception(GC_PACKAGE_NAME, LC_PROC_NAME, 100, SQLCODE, sqlerrm);

        RETURN lrec;
   END get_current_dblinks;

   FUNCTION get_parameter(p_parameter VARCHAR2) RETURN VARCHAR2 IS

   	 lv_value 	quest_soo_parameters.parameter_value%TYPE;
   BEGIN

   	  BEGIN
   	  	SELECT parameter_value
   	  	INTO   lv_value
   	  	FROM   quest_soo_parameters
   	  	WHERE  parameter_name = p_parameter;

   	  EXCEPTION
   	  	WHEN OTHERS THEN
   	  		NULL;
   	  END;

   	  RETURN lv_value;
   EXCEPTION
      WHEN OTHERS THEN
        RETURN NULL;
   END get_parameter;

   PROCEDURE set_parameter(p_parameter VARCHAR2, p_value VARCHAR2) IS
       PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
       BEGIN
           INSERT INTO quest_soo_parameters (parameter_name, parameter_value)
           VALUES (p_parameter, p_value);
       EXCEPTION
       	   WHEN DUP_VAL_ON_INDEX THEN
       	   	  UPDATE quest_soo_parameters
       	   	  SET parameter_value = p_value
       	   	  WHERE parameter_name = p_parameter;
           WHEN OTHERS THEN
              NULL;
       END;

       COMMIT;
   EXCEPTION
   	  WHEN OTHERS THEN
   	  	NULL;
   END set_parameter;

BEGIN
    populate_data;
END quest_soo_variable;
/
