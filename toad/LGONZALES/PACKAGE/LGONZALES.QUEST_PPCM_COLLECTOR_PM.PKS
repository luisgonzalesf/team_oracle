CREATE OR REPLACE PACKAGE LGONZALES.quest_ppcm_collector_pm
	AUTHID Current_User
IS
   --
   -- Purpose: Collector for Performance Modelling
   --
   -- MODIFICATION HISTORY
   -- Person      Date    Comments
   -- ---------   ------  ------------------------------------------
   -- DR          02/09   Initial creation

   -- Exception declarations

   exc_custom_sql_no_rows exception;
   en_custom_sql_no_rows CONSTANT      NUMBER := -20015;
   PRAGMA EXCEPTION_INIT (exc_custom_sql_no_rows, -20015);

   exc_custom_sql_multi_rows exception;
   en_custom_sql_multi_rows CONSTANT   NUMBER := -20016;
   PRAGMA EXCEPTION_INIT (exc_custom_sql_multi_rows, -20016);

   exc_custom_sql_datatype exception;
   en_custom_sql_datatype CONSTANT     NUMBER := -20017;
   PRAGMA EXCEPTION_INIT (exc_custom_sql_datatype, -20017);

   PROCEDURE take_snapshot (i_cur_snapshot    IN quest_ppcm_snapshot%ROWTYPE,
                            i_prev_snapshot   IN quest_ppcm_snapshot%ROWTYPE);

   FUNCTION calc_memory_usage (i_snapshot_id IN NUMBER)
      RETURN NUMBER;

   FUNCTION run_custom_sql (i_sql_text IN VARCHAR2)
      RETURN NUMBER;

   PROCEDURE get_custom_sql (
      i_custom_sql_type   IN     quest_ppcm_custom_sql.custom_sql_type%TYPE,
      o_custom_sql_id        OUT quest_ppcm_custom_sql.custom_sql_id%TYPE,
      o_sql_text             OUT quest_ppcm_custom_sql.sql_text%TYPE,
      o_custom_sql_name      OUT quest_ppcm_custom_sql.custom_sql_name%TYPE
   );

   PROCEDURE set_custom_sql (
      i_custom_sql_type   IN quest_ppcm_custom_sql.custom_sql_type%TYPE,
      i_sql_text          IN quest_ppcm_custom_sql.sql_text%TYPE,
      i_custom_sql_name   IN quest_ppcm_custom_sql.custom_sql_name%TYPE
   );
END quest_ppcm_collector_pm;
/
