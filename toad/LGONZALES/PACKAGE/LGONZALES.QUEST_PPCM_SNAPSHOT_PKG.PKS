CREATE OR REPLACE PACKAGE LGONZALES.QUEST_PPCM_SNAPSHOT_PKG
    AUTHID Current_User
  IS
--
-- Sample PPCM data collector for use with PPCM reference implementation
-- Collects enough data from Oracle for PPCM analysis.  OS Stats (CPU, Disk, Etc)
-- are collected by an external program and provided to the take_xxx_snapshot routines
--
-- MODIFICATION HISTORY
-- Person      Date    Comments
-- ---------   ------  ------------------------------------------
-- Guy          Feb07   Initial



   -- standard snapshot
   PROCEDURE take_snapshot  ;
   -- snapshot with option to reset collections
   PROCEDURE take_snapshot_reset;


  -- Probability of getting a R value of this magnitude
  FUNCTION prob_r (
      p_n   NUMBER /* number of records*/,
      p_r   NUMBER                                /* correlation coefficient*/
   )
      RETURN NUMBER;
  -- Submit  or adjust a snapshot job

  -- Snapshot job mgt
  FUNCTION submit_snapshot_job (
      p_first_time_hhmm   VARCHAR2,
      p_interval_hrs      INTEGER
   )
      RETURN NUMBER;

  PROCEDURE remove_snapshot_job;
  FUNCTION job_interval_hrs (p_dbms_job_interval VARCHAR2)
      RETURN NUMBER;
  --
  -- Return the value of a parameter
  --
  FUNCTION ppcm_parameter (p_parameter_name VARCHAR2)
      RETURN VARCHAR2;
  PROCEDURE set_ppcm_parameter (
      p_parameter_name VARCHAR2,
      p_parameter_value VARCHAR2
  );
  PROCEDURE purge_snapshots;
END; -- Package spec
/
