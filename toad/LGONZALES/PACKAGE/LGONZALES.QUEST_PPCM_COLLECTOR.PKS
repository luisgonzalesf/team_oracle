CREATE OR REPLACE PACKAGE LGONZALES.quest_ppcm_collector
    AUTHID Current_User
IS
   --
   -- Purpose: Main collector package for PPCM
   --
   -- MODIFICATION HISTORY
   -- Person      Date    Comments
   -- ---------   ------  ------------------------------------------
   -- DR          02/09   Initial creation

   -- Exception declarations

   exc_invalid_snapshot_type exception;
   en_invalid_snapshot_type CONSTANT   NUMBER := -20017;
   PRAGMA EXCEPTION_INIT (exc_invalid_snapshot_type, -20017);

   PROCEDURE take_snapshot (i_snapshot_type IN VARCHAR2);

   PROCEDURE setup_job (i_snapshot_type    IN VARCHAR2,
                        i_repeat_minutes   IN NUMBER,
                        i_start_date       IN timestamp WITH TIME ZONE);

   FUNCTION get_job_repeat_minutes (
      i_start_date        IN timestamp WITH TIME ZONE,
      i_calendar_string   IN VARCHAR2
   )
      RETURN NUMBER;

   PROCEDURE set_ppcm_parameter (i_parameter_name     VARCHAR2,
                                 i_parameter_value    VARCHAR2);

   FUNCTION get_ppcm_parameter (i_parameter_name VARCHAR2)
      RETURN VARCHAR2;

   PROCEDURE remove_job (i_snapshot_type IN VARCHAR2);

   FUNCTION get_job_interval_minutes (i_job_interval IN VARCHAR2)
      RETURN NUMBER;

   PROCEDURE purge_snapshots (i_snapshot_type IN VARCHAR2);
END quest_ppcm_collector;
/
