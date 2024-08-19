CREATE OR REPLACE PACKAGE LGONZALES.quest_soo_archivelog
  AUTHID Current_User
AS
   TYPE typ_dest_rec IS RECORD (
      session_id        NUMBER (12, 0),
      sequence_num      NUMBER (12, 0),
      tree_depth        NUMBER (12, 0),
      dest_name         VARCHAR2 (256),
      status            VARCHAR2 (10),
      target            VARCHAR2 (20),
      destination       VARCHAR2 (256),
      destination_end   VARCHAR2 (256),
      BINDING           VARCHAR2 (50),
      log_sequence      NUMBER (12),
      reopen_secs       NUMBER (12),
      transmit_mode     VARCHAR2 (50),
      TYPE              VARCHAR2 (10),
      valid_type        VARCHAR2 (50),
      total_mb          NUMBER (16),
      free_mb           NUMBER (16),
      usable_file_mb    NUMBER (16),
      reclaimable_mb    NUMBER(16),
      is_asm            VARCHAR2 (10),
      is_recovery       VARCHAR2 (10),
      min_record        NUMBER (1),
      time_to_failure   NUMBER,
      instance_name     VARCHAR2 (64),
      local_ttf         NUMBER,
      local_min_rec     NUMBER,
      error             varchar2(256),
      message           varchar2(200),
      archiver_status   VARCHAR2(20)
   );

   TYPE typ_drive_rec IS RECORD (
      dest_id           VARCHAR2 (256),
      drive             VARCHAR2 (256),
      total_space       NUMBER (16),
      free_space        NUMBER (16),
      usable_space      number(16),
      space_ttf         NUMBER,
      number_ttf        PLS_INTEGER,
      recovery_total    NUMBER (16),
      recovery_free     NUMBER (16),
      recovery_ttf      NUMBER,
      number_recovery   PLS_INTEGER,
      instance_name     VARCHAR2 (64),
      local_ttf         NUMBER,
      local_recov_ttf   NUMBER,
      message           varchar2(200)
   );

   TYPE typ_archive_rec IS RECORD (
      sequence#   NUMBER,
      next_time   DATE,
      size_mb     NUMBER
   );

   TYPE typ_arc_rec IS RECORD (
      start_date   DATE,
      end_date     DATE,
      size_mb      NUMBER
   );

   TYPE typ_arc_rec_arr IS TABLE OF typ_arc_rec
      INDEX BY BINARY_INTEGER;

   TYPE typ_arc_rec_ar2 IS TABLE OF typ_arc_rec_arr
      INDEX BY BINARY_INTEGER;

   TYPE typ_archive_rec_arr IS TABLE OF typ_archive_rec
      INDEX BY BINARY_INTEGER;

   TYPE typ_archive_rec_ar2 IS TABLE OF typ_archive_rec_arr
      INDEX BY BINARY_INTEGER;

   TYPE typ_dest_rec_arr IS TABLE OF typ_dest_rec
      INDEX BY BINARY_INTEGER;

   TYPE typ_dest_rec_ar2 IS TABLE OF typ_dest_rec_arr
      INDEX BY BINARY_INTEGER;

   TYPE typ_drive_rec_arr IS TABLE OF typ_drive_rec
      INDEX BY BINARY_INTEGER;

   TYPE typ_drive_rec_ar2 IS TABLE OF typ_drive_rec_arr
      INDEX BY BINARY_INTEGER;

   TYPE typ_drive_idx IS TABLE OF PLS_INTEGER
      INDEX BY BINARY_INTEGER;

   TYPE typ_dest_idx IS TABLE OF PLS_INTEGER
      INDEX BY LONG;

   TYPE typ_date IS TABLE OF DATE
      INDEX BY BINARY_INTEGER;

   TYPE typ_rate IS TABLE OF NUMBER (16, 2)
      INDEX BY BINARY_INTEGER;

   TYPE typ_inst_arr IS TABLE OF VARCHAR2 (64)
      INDEX BY BINARY_INTEGER;

   TYPE typ_inst_ar2 IS TABLE OF typ_inst_arr
      INDEX BY LONG;

   garr_tmp_dest   typ_dest_rec_arr;
   garr_tmp_arc    typ_arc_rec_arr;

   PROCEDURE add_drive_details (
      destination     VARCHAR2,
      total_space     NUMBER,
      free_space      NUMBER,
      usable_space    NUMBER,
      IDENTIFIER      VARCHAR2,
      instance_name   VARCHAR2,
      message         VARCHAR2
   );

   FUNCTION get_drive_listing
      RETURN quest_soo_arc_dest_list_typ;

   PROCEDURE init (p_rac PLS_INTEGER);

   FUNCTION build_list RETURN quest_soo_arc_dest_list_typ;

   FUNCTION get_archivelog_rate (p_days PLS_INTEGER, p_minutes PLS_INTEGER)
      RETURN quest_soo_alerttrace_log_typ;

   FUNCTION dest_entry
      RETURN typ_dest_rec_arr;

   FUNCTION setup_archive(p_idx pls_integer DEFAULT NULL, p_local PLS_INTEGER DEFAULT 0)
      RETURN typ_arc_rec_arr;

   FUNCTION get_min_succeed(p_instance   NUMBER DEFAULT NULL)
      RETURN PLS_INTEGER;
END quest_soo_archivelog;
/
