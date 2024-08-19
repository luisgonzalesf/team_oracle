CREATE OR REPLACE PACKAGE LGONZALES.quest_ppcm_bottleneck
    AUTHID Current_User
AS
--
-- PPCM data collector for waits bottlenecks
-- Collects enough data from Oracle for PPCM bottleneck analysis
--
-- MODIFICATION HISTORY
-- Person      Date     Comments
-- ---------   -------  ------------------------------------------
-- Joe T       July 08   Initial

    -- Data collection
    PROCEDURE collect_data(p_snapshot_id     NUMBER DEFAULT NULL );

    -- Run further calculations
    PROCEDURE run_calculation;

    -- Snapshot job mgt
    FUNCTION submit_snapshot_job (
      p_first_time_hhmm   VARCHAR2,
      p_interval_min      INTEGER
    )
      RETURN NUMBER;

    -- Remove users jobs
    PROCEDURE remove_snapshot_job;

    -- Find interval in minutes for existing jobs
    FUNCTION job_interval_min (p_dbms_job_interval VARCHAR2)
      RETURN NUMBER;

    -- Get value of parameter from PPCM bottlenecks
    FUNCTION ppcm_parameter (p_parameter_name VARCHAR2)
      RETURN VARCHAR2;

    -- Set PPCM parameter
    PROCEDURE set_ppcm_parameter (
      p_parameter_name VARCHAR2,
      p_parameter_value VARCHAR2
    );

    -- Purge past snapshots
    PROCEDURE purge_snapshots;

  PROCEDURE collect_data_reset;

END;
/
