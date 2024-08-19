CREATE OR REPLACE PACKAGE LGONZALES.quest_soo_alerttrace
  AUTHID Current_User
AS
/******************************************************************************
   NAME:       quest_soo_alerttrace
   PURPOSE:

   REVISIONS:
   Ver        Date        Author           Description
   ---------  ----------  ---------------  ------------------------------------
   1.0        30/10/2007  Joe Tyrrell      Initial Creation
   1.1        30/04/2008  Joe Tyrrell      Extended for RAC cluster
******************************************************************************/

   ---------------------------------------
-- Data types global for all instances
----------------------------------------- Record definition for text information
   TYPE typ_text_rec IS RECORD (
      INSTANCE   VARCHAR2 (50),
      startpos   NUMBER,
      endpos     NUMBER,
      linedate   DATE,
      text       VARCHAR2 (4000)
   );

   -- Array definitions
   TYPE typ_text_rec_arr IS TABLE OF typ_text_rec
      INDEX BY BINARY_INTEGER;

   garr_tmp_text   typ_text_rec_arr;

   mc_previous           CONSTANT NUMBER (3)         := 0;
   mc_forward            CONSTANT NUMBER (3)         := 1;
   mc_search             CONSTANT NUMBER (3)         := 2;

   mc_read_full_file   CONSTANT NUMBER := 201;
   mc_read_head_file   CONSTANT NUMBER := 202;
   mc_read_tail_file   CONSTANT NUMBER := 203;
   mc_read_snip_file   CONSTANT NUMBER := 204;

   --initializeLines
   PROCEDURE initializelines (
      p_lines              NUMBER,
      p_chunksize          NUMBER,
      p_rac                NUMBER DEFAULT 0,
      o_start_date   OUT   VARCHAR2
   );

   PROCEDURE initializelines (
      p_lines              NUMBER,
      p_chunksize          NUMBER,
      p_rac                NUMBER DEFAULT 0);

   --  Readfile

   -- Input paramters:
   --   p_filename
   --       NULL -- Alert Log File Name
   --
   --   p_nav
   --       0  --  previous,
   --       1  --  forward.
   --       2  --  Search by Bytes
   --      -1  --  reset a file.
   --      -2  --  reset all the files position.
   --       6  --  move to a new location in file
   --     100  --  Start of the file
   --     101  --  End of the file
   --
   --   p_search
   --       NULL - No search
   --       If p_nav is 2 then it must be numeric.
   --
   --   p_search_mode
   --       0 - No Case Sensitive
   --       1 - Case Sensitive
   --   r_read_seconds
   --       5 - Default number of seconds a string search
   --           will be performed on file.
   --           If no values are found in allocated time
   --           1 row will be returned with position, date, and 'STRING NOT FOUND' text
   FUNCTION readfile (
      p_filename        VARCHAR2 DEFAULT NULL,
      p_nav             NUMBER DEFAULT 101,
      p_search          VARCHAR2 DEFAULT NULL,
      p_search_mode   NUMBER DEFAULT 0,
      p_read_seconds    NUMBER DEFAULT 5,
      p_read_rac        NUMBER DEFAULT 0
   )
      RETURN quest_soo_alerttrace_log_typ;

   -- Function used for cross rac instance data collection
   FUNCTION read_rac (
      p_start_pos       NUMBER,
      p_nav             NUMBER,
      p_search          VARCHAR2,
      p_search_mode   NUMBER,
      p_read_seconds    NUMBER,
      p_num_lines   NUMBER
   )
      RETURN typ_text_rec_arr;

   -- Retrieves start and end date from Alert Log
   PROCEDURE start_end_date (o_start_date OUT DATE, o_end_date OUT DATE);

   -- For a given date, at what position is the date or nearest date forward of it
   FUNCTION date_position (p_date DATE, p_local NUMBER := 0, p_direction NUMBER DEFAULT mc_forward)
      RETURN NUMBER;

   -- Adds an alarm condition
   PROCEDURE add_alarm(p_alarm_text     VARCHAR2, p_severity    NUMBER);

   -- Based on a given list of alarm text conditions, do any exist in last p_minutes
   FUNCTION find_alarms (p_minutes NUMBER, p_rac NUMBER)
      RETURN quest_soo_alerttrace_log_typ;

   PROCEDURE search_date(
      p_start_pos                 NUMBER,
      p_direction                 NUMBER,
      p_search                    VARCHAR2,
      p_search_mode             NUMBER,
      p_days                      NUMBER,
      p_rac                       NUMBER,
      o_date          OUT         DATE,
      o_position      OUT         NUMBER );

   PROCEDURE isdate (
      inputstring         VARCHAR2,
      isdate        OUT   NUMBER,
      datevalue     OUT   DATE
   );

   FUNCTION read_raw_file (p_filename          VARCHAR2,
                           p_operation_mode    NUMBER := mc_read_full_file,
                           p_bytes             NUMBER := NULL)
      RETURN quest_soo_raw_tab_typ
      PIPELINED;

END quest_soo_alerttrace;
/
