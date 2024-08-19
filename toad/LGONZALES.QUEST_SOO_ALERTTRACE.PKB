CREATE OR REPLACE PACKAGE BODY LGONZALES.quest_soo_alerttrace
AS
   -- Default size to read for read-back operations
   mc_file_read          CONSTANT NUMBER             := 8192;
   -- Constants for navigation through file
   mc_find_start         CONSTANT NUMBER (3)         := 3;
   mc_find_bufffwd       CONSTANT NUMBER (3)         := 4;
   mc_find_end           CONSTANT NUMBER (3)         := 5;
   mc_find_buffback      CONSTANT NUMBER (3)         := 6;
   mc_reset_file         CONSTANT NUMBER (3)         := -1;
   mc_reset_all          CONSTANT NUMBER (3)         := -2;
   mc_file_start         CONSTANT NUMBER (3)         := 100;
   mc_file_end           CONSTANT NUMBER (3)         := 101;
   -- Constant to signify start of file
   mc_file_start_pos     CONSTANT NUMBER (1)         := 1;
   -- Constants for search mode
   mc_search_case_insensitive   CONSTANT NUMBER (1)         := 0;
   mc_search_case_sensitive     CONSTANT NUMBER (1)         := 1;
   mc_search_regex_insensitive  CONSTANT NUMBER (1)         := 2;
   mc_search_regex_sensitive    CONSTANT NUMBER (1)         := 3;
   -- Constant for package name
   mc_package_name       CONSTANT VARCHAR2(50)       := 'QUEST_SOO_ALERTTRACE';
   -- Number of lines read in each chunk and chunks stored in cache
   gv_lines                       NUMBER             := 100;
   gv_chunksize                   NUMBER             := 5;
   -- Instance name and output directory for dump files
   gv_instance                    VARCHAR2 (100);
   gv_dump_dir                    VARCHAR2 (1000);
   -- Global BFILE value
   -- Created to save passing around parameters
   gv_bfile                       BFILE;
   gv_input_filename              VARCHAR2(32767);
   -- Global variable to track which file is being worked on
   gv_file_idx                    NUMBER;
   -- Global variable for current file length
   gv_file_size                   NUMBER;
   -- Restart parameter for when an exception occurs in DB link operation
   gv_restart                     NUMBER;
   gv_retry_count                 NUMBER := 0;

   -- Each file will have an array pointer within cache
   TYPE typ_file IS TABLE OF NUMBER
      INDEX BY LONG;

   TYPE typ_text IS TABLE OF VARCHAR2 (100)
      INDEX BY BINARY_INTEGER;

   TYPE typ_date IS TABLE OF DATE INDEX BY BINARY_INTEGER;

   garr_file_idx                  typ_file;

   TYPE typ_idx IS TABLE OF NUMBER
      INDEX BY BINARY_INTEGER;

   -- Info about file and current position etc
   TYPE typ_file_rec IS RECORD (
      dirname          VARCHAR2 (1000),
      filename         VARCHAR2 (100),
      file_length      NUMBER,
      arr_buff_start   typ_idx,
      arr_buff_end     typ_idx,
      curr_buff        NUMBER
   );

   -- Array definition and variable for records
   TYPE typ_file_rec_arr IS TABLE OF typ_file_rec
      INDEX BY BINARY_INTEGER;

   garr_file_rec                  typ_file_rec_arr;

   TYPE typ_dblink_rec IS RECORD (
      INSTANCE        VARCHAR2 (50),
      dblink          VARCHAR2 (128),
      start_date      DATE,
      end_date        DATE,
      CURRENT_DATE    DATE,
      current_idx     NUMBER,
      start_pos       NUMBER,
      end_pos         NUMBER,
      current_lines   typ_text_rec_arr
   );

   TYPE typ_alarm_rec IS RECORD (
      search_text   VARCHAR2(400),
      severity      NUMBER);

   TYPE typ_alarm_rec_arr IS TABLE OF typ_alarm_rec INDEX BY BINARY_INTEGER;

   TYPE typ_dblink_rec_arr IS TABLE OF typ_dblink_rec
      INDEX BY BINARY_INTEGER;

   garr_dblink                    typ_dblink_rec_arr;
   garr_alarm_rec                 typ_alarm_rec_arr;
   garr_dblink_base               quest_soo_variable.typ_db_rec_arr;

   FUNCTION  move_rac(p_date DATE, p_direction NUMBER DEFAULT mc_forward) RETURN typ_text_rec_arr ;

   PROCEDURE init_dblink;

   -- Close all LOB files. Used instead of close due to exceptions being raised for
   -- some reason when using natural close due to too many lob files opened
   PROCEDURE close_all_file
   IS
   BEGIN
      -- File no longer needed. Now close
      DBMS_LOB.filecloseall;
   EXCEPTION
      WHEN OTHERS
      THEN
         raise_application_error (-20014,
                                  'Error closing files. Error:' || SQLERRM
                                 );
   END close_all_file;


   -- Find start date from file across all RAC instances
   -- Max date is found during 101 run of alert log
   PROCEDURE find_start_end_dates(o_start_date OUT date)
   IS
      lv_start_date   DATE;
      lv_end_date     DATE;
      lv_pos          NUMBER;
      lv_sql          VARCHAR2 (200);
      lv_dblink       VARCHAR2 (128);
   BEGIN
      o_start_date := SYSDATE;
      FOR idx IN 1 .. garr_dblink.COUNT
      LOOP
         IF garr_dblink (idx).dblink IS NULL
         THEN
            start_end_date (garr_dblink (idx).start_date,
                            garr_dblink (idx).end_date
                           );

         ELSE
            lv_dblink := garr_dblink (idx).dblink;
            lv_sql :=
                  'begin quest_soo_alerttrace.start_end_date@'
               || lv_dblink
               || '(:1, :2); END;';

            quest_soo_tracing.add_debug(mc_package_name, 'find_start_end_dates', 100, lv_sql);

            EXECUTE IMMEDIATE lv_sql
                        USING OUT lv_start_date, OUT lv_end_date;

            garr_dblink (idx).start_date := lv_start_date;
            garr_dblink (idx).end_date := lv_end_date;
            garr_dblink (idx).CURRENT_DATE := lv_end_date;
         END IF;
         o_start_date := LEAST(o_start_date, garr_dblink (idx).START_DATE);
      END LOOP;
   EXCEPTION
    WHEN OTHERS THEN
        gv_restart := 1;
        RAISE;
   END find_start_end_dates;

   -- Initialise file entry
   PROCEDURE initfile (p_file VARCHAR2, p_dirpath VARCHAR2)
   IS
   BEGIN
      -- Assign default values to file record
      garr_file_rec (gv_file_idx).dirname := p_dirpath;
      garr_file_rec (gv_file_idx).filename := p_file;
      garr_file_rec (gv_file_idx).file_length := 0;
      garr_file_rec (gv_file_idx).curr_buff := 0;
      garr_file_rec (gv_file_idx).arr_buff_start.DELETE;
      garr_file_rec (gv_file_idx).arr_buff_end.DELETE;
      -- Keep track of entries here too
      garr_file_idx (p_dirpath || p_file) := gv_file_idx;
   END initfile;

   -- Takes in p_filename which is full path to file including directory
   -- Needs to be transformed into pieces of directory and file
   -- If p_filename is null then assume standard alert log
   PROCEDURE lp_seperate_file_name (
      p_filename         VARCHAR2,
      o_dirname    OUT   VARCHAR2,
      o_file       OUT   VARCHAR2
   )
   IS
      lv_delim     CHAR (1)    := '/';
      lv_str_pos   NUMBER;
   BEGIN
      -- Assume alert log
      IF p_filename IS NULL
      THEN
         o_dirname := gv_dump_dir;
         o_file := 'alert_' || gv_instance || '.log';
         gv_file_idx := 1;

         IF NOT garr_file_rec.EXISTS (gv_file_idx)
         THEN
            initfile (o_file, o_dirname);
         END IF;
      -- See if file details have already been loaded
      -- If not we're starting from scratch
      ELSIF NOT garr_file_idx.EXISTS (p_filename)
      THEN
         lv_str_pos := INSTR (p_filename, lv_delim, -1);

         IF lv_str_pos = 0
         THEN
            lv_delim := '\';
            lv_str_pos := INSTR (p_filename, lv_delim, -1);
         END IF;

         o_dirname := SUBSTR (p_filename, 1, lv_str_pos);
         o_file := SUBSTR (p_filename, (lv_str_pos + 1));
         gv_file_idx := garr_file_rec.COUNT + 1;
         initfile (o_file, o_dirname);
      ELSE
         gv_file_idx := garr_file_idx (p_filename);
         o_dirname := garr_file_rec (gv_file_idx).dirname;
         o_file := garr_file_rec (gv_file_idx).filename;
      END IF;
   END lp_seperate_file_name;

   -- Not used
   PROCEDURE close_file
   IS
   BEGIN
      --Check the file IS OPEN
      IF DBMS_LOB.fileisopen (gv_bfile) = 1
      THEN
         DBMS_LOB.fileclose (gv_bfile);
      END IF;
   END close_file;

   -- If a directory doesn't exist we need to create it
   -- Contain within autonomous transaction block so as not to commit implicit commit
   PROCEDURE create_directory (p_dirname VARCHAR2, p_dirpath VARCHAR2)
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      v_sql_text   VARCHAR2 (4000);
   BEGIN
      v_sql_text :=
            'CREATE OR REPLACE DIRECTORY '
         || p_dirname
         || ' AS '''
         || p_dirpath
         || '''';

      EXECUTE IMMEDIATE v_sql_text;
   END create_directory;

   -- Validate directory exists
   PROCEDURE lp_validate_directory (
      iv_directory_path         VARCHAR2,
      ov_directory_name   OUT   VARCHAR2
   )
   IS
      lv_test   NUMBER;
   BEGIN
      BEGIN
         -- Validate directory exists
         SELECT directory_name
           INTO ov_directory_name
           FROM all_directories
          WHERE directory_path = iv_directory_path AND ROWNUM < 2;
      EXCEPTION
         -- If doesn't exist
         WHEN NO_DATA_FOUND
         THEN
            -- Generic alert log directory
            -- In a different directory. Needs then to create a
            -- unique directory name
            FOR idx IN 1 .. 10000
            LOOP
               BEGIN
                   ov_directory_name := 'QUEST_SOO_DIR_' || idx;

                 SELECT 1
                   INTO lv_test
                   FROM all_directories
                  WHERE directory_name = ov_directory_name AND ROWNUM < 2;
               EXCEPTION
                 WHEN NO_DATA_FOUND
                 THEN
                    EXIT;
                END;
            END LOOP;

            create_directory (ov_directory_name, iv_directory_path);
      END;
   END lp_validate_directory;

   -- Open file for reading
   PROCEDURE lp_open_file (p_filename VARCHAR2)
   IS
      lv_directory   VARCHAR2 (1000);
      lv_file_name   VARCHAR2 (1000);
      lv_dir_path    VARCHAR2 (1000);
   BEGIN
      gv_input_filename := p_filename;
      -- Seperate out directory and file name data
      BEGIN
         lp_seperate_file_name (p_filename, lv_dir_path, lv_file_name);
      EXCEPTION
         WHEN OTHERS
         THEN
            raise_application_error
                             (-20001,
                                 'Error seperating file name from directory:'
                              || SQLERRM
                             );
      END;

      -- Test directory exists and create if necessary
      -- Currently lv_directory stores directory path. After procedure will store name
      BEGIN
         lp_validate_directory (lv_dir_path, lv_directory);
      EXCEPTION
         WHEN OTHERS
         THEN
            raise_application_error
                                (-20002,
                                    'Error validating or creating directory:'
                                 || SQLERRM
                                );
      END;

      BEGIN
         -- Create BFILE to load up
         gv_bfile := BFILENAME (lv_directory, lv_file_name);
      EXCEPTION
         WHEN OTHERS
         THEN
            raise_application_error (-20003,
                                     'Error opening file:' || SQLERRM);
      END;

      --Check the file IS OPEN
      BEGIN
         DBMS_LOB.fileopen (gv_bfile, DBMS_LOB.lob_readonly);
      EXCEPTION
         WHEN OTHERS
         THEN
            raise_application_error (-20003,
                                     'Error opening file:' || SQLERRM);
      END;
      gv_file_size := DBMS_LOB.getlength (gv_bfile);
   END lp_open_file;

   --
   -- Return the date corresponding to the string provided, if the string
   -- is in fact a date formatted as the date lines in the alert log.
   --
   PROCEDURE isdate (
      inputstring         VARCHAR2,
      isdate        OUT   NUMBER,
      datevalue     OUT   DATE
   )
   IS
   BEGIN
      BEGIN
   -- Start from Oracle 12.2, the format of timestamp in alert log has changed, so need check here
      IF LENGTH(inputstring) > 25
         THEN
           datevalue := TO_DATE (substr(replace(inputstring,'T',' '),0,19),'YYYY-MM-DD HH24:MI:SS',  'NLS_DATE_LANGUAGE=english');
         ELSE
           datevalue := TO_DATE (inputstring, 'DY MON DD HH24:MI:SS YYYY',  'NLS_DATE_LANGUAGE=english');
         END IF;
         isdate := 1;
      EXCEPTION
         WHEN OTHERS
         THEN
            isdate := 0;
      END;
   END isdate;

   -- Within file find position of closest date iether forward or backwards
   PROCEDURE find_date (
      p_start_pos            NUMBER,
      o_date_pos    OUT      NUMBER,
      o_date        OUT      DATE,
      p_direction   IN       NUMBER DEFAULT mc_previous
   )
   IS
      lv_start      NUMBER;
      lv_end        NUMBER;
      lv_tmp_read   NUMBER;
      lv_tmp_end    NUMBER;
      lv_text       VARCHAR2 (4000);
      lv_tmp_date   DATE;
      lv_isdate     NUMBER;
      lv_idx        NUMBER;
   BEGIN
      lv_end := p_start_pos;
      lv_start := p_start_pos;
      lv_idx := 1;

      LOOP
         -- If starting position before start of file
         -- or have searched full 8k of area then likely date not to be found
         IF    (p_direction = mc_previous AND lv_start <= mc_file_start_pos
               )
            OR (p_direction = mc_forward AND lv_end >= gv_file_size)
            OR lv_idx = 100
         THEN
            EXIT;
         END IF;

         -- Get START
         IF p_direction = mc_previous
         THEN
            lv_start := lv_end - (mc_file_read / 10);
         ELSE
            lv_end := LEAST (lv_start + (mc_file_read / 10), gv_file_size);

            IF lv_end < gv_file_size
            THEN
               lv_end := DBMS_LOB.INSTR (gv_bfile, '0A', lv_end, 1) + 1;
            END IF;
         END IF;

         IF lv_start <= mc_file_start_pos
         THEN
            lv_start := mc_file_start_pos;
         ELSE
            -- Set start to beginning of next line
            lv_start := DBMS_LOB.INSTR (gv_bfile, '0A', lv_start, 1) + 1;
         END IF;

         lv_tmp_read := lv_start;

         -- Just in case can't find a date in previous 800 characters before starting position
         LOOP
            -- Find end of line
            lv_tmp_end := DBMS_LOB.INSTR (gv_bfile, '0A', lv_tmp_read, 1);
            -- Read from current position to end of line
            lv_text :=
               UTL_RAW.cast_to_varchar2 (DBMS_LOB.SUBSTR (gv_bfile,
                                                          (  lv_tmp_end
                                                           - lv_tmp_read
                                                          ),
                                                          lv_tmp_read
                                                         )
                                        );
            -- Test if it's a date
            isdate (lv_text, lv_isdate, lv_tmp_date);

            IF lv_isdate = 1
            THEN
               o_date := lv_tmp_date;
               o_date_pos := lv_tmp_read;
            END IF;

            lv_tmp_read := lv_tmp_end + 1;

            -- If we've reached end of search area dont go forward of end position
            -- Outer loop will go back further in text file
            IF    (lv_tmp_read >= lv_end)
               OR (p_direction = mc_forward AND o_date IS NOT NULL)
            THEN
               EXIT;
            END IF;
         END LOOP;

         -- If value has been found then exit
         IF o_date IS NOT NULL
         THEN
            EXIT;
         END IF;

         -- Assign new end of search area
         IF p_direction = mc_previous
         THEN
            lv_end := lv_start;
         ELSE
            lv_start := lv_end;
         END IF;

         -- Sanity check. Increment index so dont search whole file
         lv_idx := lv_idx + 1;
      END LOOP;
   END find_date;

   -- Re-initialize cache storing line start/end numbers for previously
   -- retrieved pieces of text
   PROCEDURE reset_cache (
      p_direction   NUMBER,
      p_start       NUMBER,
      p_end         NUMBER,
      p_idx         NUMBER DEFAULT gv_file_idx
   )
   IS
      lv_buffer   NUMBER;
   BEGIN
      garr_file_rec (p_idx).arr_buff_start.DELETE;
      garr_file_rec (p_idx).arr_buff_end.DELETE;

      IF p_direction = mc_forward
      THEN
         lv_buffer := 1;
      ELSE
         lv_buffer := gv_chunksize;
      END IF;

      garr_file_rec (p_idx).arr_buff_start (lv_buffer) := p_start;
      garr_file_rec (p_idx).arr_buff_end (lv_buffer) := p_end;
      garr_file_rec (p_idx).curr_buff := lv_buffer;
   END reset_cache;

   -- This does the actual reading of lines and stores entries in a local array
   FUNCTION lf_read_lines (
      p_start_pos            NUMBER,
      p_direction            NUMBER,
      o_start_pos   OUT      NUMBER,
      o_end_pos     OUT      NUMBER,
      po_reset      IN OUT   NUMBER,
      p_rerun                NUMBER DEFAULT 0,
      p_size_mult            NUMBER DEFAULT 1
   )
      RETURN typ_text_rec_arr
   IS
      larr_read_lines     typ_text_rec_arr;
      larr_tmp_read       typ_text_rec_arr;
      lv_lines            NUMBER;
      lv_idx              NUMBER;
      lv_start_pos        NUMBER;
      lv_date_start_pos   NUMBER;
      lv_tmp_start        NUMBER;
      lv_tmp_end          NUMBER;
      lv_tmp_read         NUMBER;
      lv_tmp_srch_end     NUMBER;
      lv_isdate           NUMBER;
      lv_current_date     DATE;
      lv_tmp_date         DATE;
      lv_text             VARCHAR2 (4000);
   BEGIN
      -- First we need to find out starting position
      -- If going forward its the parameter value
      -- If going backwards its parameter - MC_READ_FILE - difference to first date value
      -- MC_READ_FILE will read the file in 8k blocks
      -- If that doesn't contain GV_LINES then another 8k worth will be read before hand
      IF p_direction = mc_forward
      THEN
         lv_start_pos := p_start_pos;
      ELSE
         lv_start_pos := p_start_pos - mc_file_read * p_size_mult;

         -- Set starting position to start of next line
         IF lv_start_pos < mc_file_start_pos
         THEN
            lv_start_pos := mc_file_start_pos;
         ELSE
            lv_start_pos :=
                          DBMS_LOB.INSTR (gv_bfile, '0A', lv_start_pos, 1)
                          + 1;
         END IF;

         IF p_direction = mc_previous AND p_start_pos <= mc_file_start_pos THEN
            RETURN larr_read_lines;
         END IF;

      END IF;

      IF NVL (lv_start_pos, 0) < mc_file_start_pos
      THEN
         lv_start_pos := mc_file_start_pos;
      END IF;

      -- Only populate the date column if we are reading the alert log
      IF gv_input_filename IS NULL THEN
         -- Now find date. If going backwards then we'll use date associated with that entry
         -- We'll go back by amounts of MC_READ_FILE / 10 until a date is found or start of file reached
         find_date (lv_start_pos, lv_date_start_pos, lv_current_date);

         -- Now we have date and starting position for it.
         -- If going backwards set starting position to date position
         -- Otherwise continue from current position
         IF     p_direction = mc_previous
            AND NVL (lv_date_start_pos, 0) > mc_file_start_pos
         THEN
            lv_start_pos := lv_date_start_pos;
         END IF;
      END IF;

      -- Start running forward now
      -- If direction is forward we only want to read the first GV_LINES
      -- If direction is previous we want to get all lines to end point,
      -- store in array, ensure total lines is >= GV_LINES and copy
      -- last GV_LINES to final array
      -- If total lines is less than GV_LINES go back a further MC_FILE_READ to retrieve
      -- required lines to make up GV_LINES
      lv_lines := 1;
      lv_tmp_start := lv_start_pos;

      LOOP
         -- Find end-of-line
         lv_tmp_end := DBMS_LOB.INSTR (gv_bfile, '0A', lv_tmp_start, 1);

         IF lv_tmp_end = 0
         THEN
            lv_tmp_end := gv_file_size;
         END IF;

         -- Get line of text
         lv_text :=
            UTL_RAW.cast_to_varchar2 (DBMS_LOB.SUBSTR (gv_bfile,
                                                       (  lv_tmp_end
                                                        - lv_tmp_start
                                                       ),
                                                       lv_tmp_start
                                                      )
                                     );
         -- Only populate the date column if we are reading the alert log
         IF gv_input_filename IS NULL THEN
            -- Test if it's a date and assign current date if so
            isdate (lv_text, lv_isdate, lv_tmp_date);

            IF lv_isdate = 1
            THEN
               lv_current_date := lv_tmp_date;
               lv_date_start_pos := lv_tmp_start;
            END IF;
         END IF;

         -- Assign line details
         larr_read_lines (lv_lines).startpos := lv_tmp_start;
         larr_read_lines (lv_lines).endpos := lv_tmp_end;
         larr_read_lines (lv_lines).linedate := lv_current_date;
         larr_read_lines (lv_lines).text := lv_text;
         lv_tmp_start := lv_tmp_end + 1;
         lv_lines := lv_lines + 1;

         IF     p_direction = mc_forward
            AND (lv_lines > gv_lines OR lv_tmp_start >= gv_file_size)
         THEN
            EXIT;
         ELSIF p_direction = mc_previous AND lv_tmp_start >= p_start_pos
         THEN
            EXIT;
         END IF;
      END LOOP;

      -- If going backwards through file possible to have greater number of lines
      -- than wanted
      IF p_direction = mc_previous
      THEN
         -- If equals to then perfect, return array
         IF larr_read_lines.COUNT = gv_lines
         THEN
            NULL;
         -- If greater than need to trim last p_read_lines to array
         ELSIF larr_read_lines.COUNT > gv_lines
         THEN
            -- Get first element we need
            lv_lines := larr_read_lines.COUNT - gv_lines + 1;

            FOR idx IN 1 .. gv_lines
            LOOP
               larr_tmp_read (idx) := larr_read_lines (lv_lines);
               lv_lines := lv_lines + 1;
            END LOOP;

            larr_read_lines := larr_tmp_read;
         -- We have less than required. Call procedure again to get required lines with larger size for reading
         ELSE
            -- Not enough lines within 8k block OR may have arrived at start of file.
            -- Test if lv_start_pos at start of file. If so, move forward within file only
            -- If not then increase multiplier to go back further. If reaches start of file and
            -- still no good do a forward read and reset
            IF lv_start_pos > mc_file_start_pos
            THEN
               IF p_rerun = 0
               THEN
                  FOR idx IN 1 .. 100
                  LOOP
                     larr_read_lines :=
                        lf_read_lines (p_start_pos,
                                       mc_previous,
                                       lv_tmp_start,
                                       lv_tmp_end,
                                       po_reset,
                                       1,
                                       idx + 1
                                      );
                     EXIT WHEN (larr_read_lines.COUNT >= gv_lines)
                           OR (    larr_read_lines.COUNT < gv_lines
                               AND lv_tmp_start <= mc_file_start_pos
                              );
                  END LOOP;

                  IF larr_read_lines.COUNT > gv_lines
                  THEN
                     -- Get first element we need
                     lv_lines := larr_read_lines.COUNT - gv_lines;

                     FOR idx IN 1 .. gv_lines
                     LOOP
                        larr_tmp_read (idx) := larr_read_lines (lv_lines);
                        lv_lines := lv_lines + 1;
                     END LOOP;

                     larr_read_lines := larr_tmp_read;
                  END IF;
               END IF;
            END IF;
         END IF;
      END IF;

      o_start_pos := larr_read_lines (larr_read_lines.FIRST).startpos;
      o_end_pos := larr_read_lines (larr_read_lines.COUNT).endpos;
      RETURN larr_read_lines;
   END lf_read_lines;

   -- Taken out of lf_search from version 1. We need it in seperate procedure so
   -- from RAC client we can find date and from SOO can find position
   -- Multiple places this procedure can be entered into
   FUNCTION perform_search(
      p_start_pos                 NUMBER,
      p_direction                 NUMBER,
      p_search                    VARCHAR2,
      p_search_mode             NUMBER,
      po_reset           IN OUT   NUMBER,
      p_search_seconds            NUMBER,
      p_rac                       NUMBER) RETURN NUMBER IS
      lv_start        NUMBER;
      lv_end          NUMBER;
      lv_find_idx     NUMBER;
      lv_tmp_idx      NUMBER;
      lv_comp_idx     NUMBER;
      lv_seconds      NUMBER;
      lv_start_date   DATE;
      lv_curr_date    DATE;
      lv_search_date  date;
      lv_search_start_date DATE;
      lv_date_pos     NUMBER;
      lv_tmp_text     VARCHAR2 (8196);
      lv_find         VARCHAR2 (400);
      lv_regex_match_param VARCHAR2(10);
      lv_regex_match_count NUMBER;
   BEGIN

      lv_find := p_search;
      lv_find_idx := 0;

      IF p_search_mode = mc_search_case_insensitive
      THEN
         lv_find := UPPER (lv_find);
      END IF;

      IF p_search_mode = mc_search_regex_sensitive THEN
         lv_regex_match_param := 'cm';
      ELSIF p_search_mode = mc_search_regex_insensitive THEN
         lv_regex_match_param := 'im';
      END IF;

      lv_start := p_start_pos;
      lv_start_date := SYSDATE;
      lv_seconds := 0;

      IF p_rac > 0 THEN
        find_date(p_start_pos,lv_date_pos,lv_search_start_date);
      END IF;

      -- Loop through file until something found or start/end of file reached
      -- Move through file in 8k chunks
      LOOP
         -- If forward then define end as 8k in advance
         IF p_direction IN (mc_forward, mc_file_start)
         THEN
            lv_end := lv_start + mc_file_read;

            IF lv_end > gv_file_size
            THEN
               lv_end := gv_file_size;
            END IF;

            IF lv_start >= gv_file_size
            THEN
               dbms_output.put_line('Exiting here ');
               EXIT;
            END IF;
         -- If backwards then define start as 8k up and end at current spot
         ELSE
            lv_end := lv_start;
            lv_start := lv_start - mc_file_read;

            IF lv_start < mc_file_start_pos
            THEN
               lv_start := mc_file_start_pos;
            END IF;

            IF lv_end <= mc_file_start_pos
            THEN
                dbms_output.put_line('Exiting there ');
               EXIT;
            END IF;
         END IF;

         IF p_search_mode = mc_search_case_insensitive
         THEN
            lv_tmp_text :=
               UPPER (UTL_RAW.cast_to_varchar2 (DBMS_LOB.SUBSTR (gv_bfile,
                                                                 (  lv_end
                                                                  - lv_start
                                                                 ),
                                                                 lv_start
                                                                )
                                               )
                     );
         ELSE
            lv_tmp_text :=
               UTL_RAW.cast_to_varchar2 (DBMS_LOB.SUBSTR (gv_bfile,
                                                          (lv_end - lv_start
                                                          ),
                                                          lv_start
                                                         )
                                        );
         END IF;

         IF p_direction = mc_forward
         THEN
            IF p_search_mode IN (mc_search_regex_sensitive,mc_search_regex_insensitive) THEN
               EXECUTE IMMEDIATE 'BEGIN :lv_find_idx := REGEXP_INSTR (:lv_tmp_text, :lv_find, 1, 1, 0, :lv_regex_match_param); END;'
                  USING OUT lv_find_idx, lv_tmp_text, lv_find, lv_regex_match_param;
            ELSE
               lv_find_idx := INSTR (lv_tmp_text, lv_find);
            END IF;
         ELSE
            IF p_search_mode IN (mc_search_regex_sensitive,mc_search_regex_insensitive) THEN
               lv_regex_match_count := 1;
               lv_tmp_idx := 0;
               LOOP
                  EXECUTE IMMEDIATE 'BEGIN :lv_tmp_idx := REGEXP_INSTR (:lv_tmp_text, :lv_find, 1, :lv_regex_match_count, 0, :lv_regex_match_param); END;'
                     USING OUT lv_tmp_idx, lv_tmp_text, lv_find, lv_regex_match_count, lv_regex_match_param;
                  EXIT WHEN lv_tmp_idx = 0;
                  lv_regex_match_count := lv_regex_match_count + 1;
                  lv_find_idx := lv_tmp_idx;
               END LOOP;
            ELSE
               lv_find_idx := INSTR (lv_tmp_text, lv_find, -1);
            END IF;
         END IF;

         dbms_output.put_line('Find Idx: ' || lv_find_idx);

         IF lv_find_idx > 0
         THEN
            lv_find_idx := lv_start + lv_find_idx;

            IF lv_find_idx > gv_file_size
            THEN
               lv_find_idx := gv_file_size;
            END IF;

            EXIT;
         END IF;

         IF p_direction = mc_forward
         THEN
            lv_start := lv_start + mc_file_read - (mc_file_read / 20);
         ELSE
            IF lv_start = mc_file_start_pos
            THEN
               EXIT;
            END IF;

            lv_start := lv_start + (mc_file_read / 20);
         END IF;

         -- Work out how many seconds we've used for search sofar
         lv_curr_date := SYSDATE;
         lv_seconds := (lv_curr_date - lv_start_date) * 60 * 60 * 24;

         -- Test if greater than allocated period and exit if so
         IF p_rac = 0 THEN
             IF lv_seconds >= p_search_seconds
             THEN
                lv_find_idx := -1;
                EXIT;
             END IF;
         ELSE
            IF p_direction = mc_forward THEN
                find_date(lv_end,lv_date_pos,lv_search_date);
                IF (lv_search_date - lv_search_start_date) > p_search_seconds THEN
                    lv_find_idx := -1;
                    EXIT;
                END IF;
            ELSE
                find_date(lv_start, lv_date_pos, lv_search_date);
                IF (lv_search_start_date - lv_search_date) > p_search_seconds THEN
                    lv_find_idx := -1;
                    EXIT;
                END IF;
            END IF;
         END IF;
      END LOOP;

      RETURN lv_find_idx;

   END perform_search;

   -- This procedure is main driver for all searching
   -- Takes a start position to look over, finds first instance either forwards or backwards
   -- from given positon.
   -- If search string is found then will call lf_read_lines to get lines around that string and return
   -- Otherwise will return NULL array
   -- For all cases APART from case sensitive forward, searching will be done in MC_FILE_READ sized chunks
   FUNCTION lf_search (
      p_start_pos                 NUMBER,
      p_direction                 NUMBER,
      p_search                    VARCHAR2,
      p_search_mode             NUMBER,
      po_reset           IN OUT   NUMBER,
      p_search_seconds            NUMBER
   )
      RETURN typ_text_rec_arr
   IS
      larr_lines      typ_text_rec_arr;
      lv_start        NUMBER;
      lv_end          NUMBER;
      lv_find_idx     NUMBER;
      lv_tmp_idx      NUMBER;
      lv_comp_idx     NUMBER;
      lv_seconds      NUMBER;
      lv_start_date   DATE;
      lv_curr_date    DATE;
      lv_tmp_text     VARCHAR2 (8196);
      lv_find         VARCHAR2 (400);
   BEGIN
      lv_find := p_search;
      lv_find_idx := 0;

      IF p_search_mode = mc_search_case_insensitive
      THEN
         lv_find := UPPER (lv_find);
      END IF;

      lv_start := p_start_pos;
      lv_start_date := SYSDATE;
      lv_seconds := 0;

      lv_find_idx := perform_search(p_start_pos, p_direction, p_search, p_search_mode, po_reset, p_search_seconds, 0);

      --END IF;
      -- If found get data from file and reset cache. If not found then blank array will be returned
      IF lv_find_idx > 0
      THEN
         -- Find start of current line for searching forward or end of current line for searching backwards
         IF p_direction = mc_previous
         THEN
            lv_find_idx :=
               LEAST (DBMS_LOB.INSTR (gv_bfile, '0A', lv_find_idx, 1) + 2,
                      gv_file_size
                     );
         ELSE
            -- Dont necessarily know where start of line is
            -- Move back 400 bytes (for 8k buffer), find last end of line before lv_find_idx
            lv_tmp_idx := lv_find_idx - (mc_file_read / 20);
            lv_comp_idx := 0;

            LOOP
               -- Make sure not past start of file
               IF lv_tmp_idx < mc_file_start_pos
               THEN
                  lv_tmp_idx := mc_file_start_pos;
               END IF;

               -- Find end-of-line
               lv_tmp_idx := DBMS_LOB.INSTR (gv_bfile, '0A', lv_tmp_idx, 1);

               -- If not found then at last line
               IF lv_tmp_idx = 0
               THEN
                  lv_find_idx := gv_file_size;
                  EXIT;
               -- If found then assign start of line
               ELSIF lv_tmp_idx > lv_find_idx
               THEN
                  -- If first loop through and end-of-line is > lv_find_idx
                  -- found line is on first line
                  IF lv_comp_idx = 0
                  THEN
                     lv_find_idx := mc_file_start_pos;
                  ELSE
                     lv_find_idx := lv_comp_idx + 1;
                  END IF;

                  EXIT;
               ELSE
                  lv_comp_idx := lv_tmp_idx;
               END IF;

               lv_tmp_idx := lv_tmp_idx + 1;
            END LOOP;
         END IF;

         larr_lines :=
            lf_read_lines (lv_find_idx,
                           p_direction,
                           lv_start,
                           lv_end,
                           po_reset
                          );
         -- Reset cache for front end
         po_reset := -1;
         reset_cache (mc_forward, lv_start, lv_end);
      ELSIF lv_seconds >= p_search_seconds
      THEN
         larr_lines (1).startpos := lv_start;
         larr_lines (1).endpos := NULL;
         find_date (lv_start, lv_end, larr_lines (1).linedate);
         larr_lines (1).text := 'STRING NOT FOUND';
      END IF;

      RETURN larr_lines;
   END lf_search;

   -- For a given search, if the item is found, what is the date????
   -- Return NULL if item isn't found in date allowed else date of item
   PROCEDURE search_date(
      p_start_pos                 NUMBER,
      p_direction                 NUMBER,
      p_search                    VARCHAR2,
      p_search_mode             NUMBER,
      p_days                      NUMBER,
      p_rac                       NUMBER,
      o_date          OUT         DATE,
      o_position      OUT         NUMBER )
   IS

      lv_start_idx      NUMBER;
      lv_date           date;
      lv_date_pos       NUMBER;
      lv_reset          NUMBER := 0;
      lc_proc_name      VARCHAR2(50) := 'SEARCH_DATE';
   BEGIN
      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 100, 'Parameters:' || p_start_pos || ':' ||
                                                                      p_direction                 || ':' ||
                                                                      p_search                    || ':' ||
                                                                      p_search_mode             || ':' ||
                                                                      p_days                      || ':' ||
                                                                      p_rac                       );

      IF p_rac = 1 THEN
        lp_open_file(null);
      END IF;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 101, 'Performing search');
      lv_start_idx := perform_search(nvl(p_start_pos, gv_file_size),p_direction,p_search,p_search_mode,lv_reset, p_days,1);
      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 102, 'Search done. Returns:' || lv_start_idx);

      IF lv_start_idx > 0 THEN
        find_date(lv_start_idx,lv_date_pos,lv_date, mc_previous);
      ELSE
        lv_date := NULL;
      END IF;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 103, 'Return date:' || TO_CHAR(o_date, 'DD-Mon-YYYY HH24:MI:SS'));
      o_position := lv_start_idx;
      o_date := lv_date;

      IF p_rac = 1 THEN
        close_all_file;
      END IF;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 104, 'Finish');
   END search_date;

   -- Initialize number of lines to select in each go and number to cache in background
   PROCEDURE initializelines (
      p_lines       NUMBER,
      p_chunksize   NUMBER,
      p_rac         NUMBER DEFAULT 0,
      o_start_date  OUT VARCHAR2
   )
   IS
         lv_date     DATE;
   BEGIN
      quest_soo_tracing.add_debug(mc_package_name,'INIT',100,'Start of init:' || p_lines || ':' || p_chunksize || ':' || p_rac);
      gv_lines := p_lines;
      gv_chunksize := p_chunksize;

      IF p_rac = 1
      THEN
         -- Initialise Rac
         init_dblink;
   -- Fix a bug that lv_date is null in RAC, SOO-2721
         IF lv_date is null
         THEN
           lv_date := sysdate();
         END IF;

         find_start_end_dates(lv_date);

         o_start_date :=  TO_CHAR(lv_date, 'DD/MM/YYYY HH:MI:SS AM');
         quest_soo_tracing.add_debug(mc_package_name,'INIT',100, 'Start date:' || o_start_date);
      END IF;

      quest_soo_tracing.add_debug(mc_package_name,'INIT',100,'End of init');
   END initializelines;

   PROCEDURE initializelines (
      p_lines              NUMBER,
      p_chunksize          NUMBER,
      p_rac                NUMBER DEFAULT 0)
   IS
      lv_date       VARCHAR2(100);
   BEGIN
      quest_soo_tracing.add_debug(mc_package_name,'INIT-1',100, 'Calling through classic init');
      initializelines(p_lines, p_chunksize, p_rac, lv_date);
   END initializelines;

   -- Move entries in cache up or down and add in current entry
   PROCEDURE move_cache (
      p_direction   NUMBER,
      p_start       NUMBER,
      p_end         NUMBER,
      p_idx         NUMBER DEFAULT gv_file_idx
   )
   IS
      lv_idx     NUMBER;
      lv_start   NUMBER;
      lv_end     NUMBER;
   BEGIN
      lv_start := garr_file_rec (p_idx).arr_buff_start.FIRST;
      lv_end := garr_file_rec (p_idx).arr_buff_end.LAST;

      IF p_direction = mc_forward
      THEN
         -- If array is full, assign first element for copy later
         IF lv_start = 1
         THEN
            lv_start := 2;
         END IF;

         -- Array is full. Remove first entry, copy other elements back, add new one to end of array
         IF lv_end = gv_chunksize
         THEN
            FOR idx IN lv_start .. lv_end
            LOOP
               garr_file_rec (p_idx).arr_buff_start (idx - 1) :=
                                   garr_file_rec (p_idx).arr_buff_start (idx);
               garr_file_rec (p_idx).arr_buff_end (idx - 1) :=
                                     garr_file_rec (p_idx).arr_buff_end (idx);
            END LOOP;

            garr_file_rec (p_idx).arr_buff_start (lv_end) := p_start;
            garr_file_rec (p_idx).arr_buff_end (lv_end) := p_end;
         ELSE
            -- Have space in array. Add element to end
            garr_file_rec (p_idx).arr_buff_start (lv_end + 1) := p_start;
            garr_file_rec (p_idx).arr_buff_end (lv_end + 1) := p_end;
         END IF;
      ELSE
         IF lv_end = gv_chunksize
         THEN
            lv_end := lv_end - 1;
         END IF;

         -- Array is full. Need to make room in it by moving elements existing up
         IF lv_start = 1
         THEN
            lv_idx := lv_end + 1;

            LOOP
               garr_file_rec (p_idx).arr_buff_start (lv_idx) :=
                            garr_file_rec (p_idx).arr_buff_start (lv_idx - 1);
               garr_file_rec (p_idx).arr_buff_end (lv_idx) :=
                              garr_file_rec (p_idx).arr_buff_end (lv_idx - 1);
               lv_idx := lv_idx - 1;
               EXIT WHEN lv_idx = 1;
            END LOOP;

            garr_file_rec (p_idx).arr_buff_start (1) := p_start;
            garr_file_rec (p_idx).arr_buff_end (1) := p_end;
         -- Still have room to move
         ELSE
            garr_file_rec (p_idx).arr_buff_start (lv_start - 1) := p_start;
            garr_file_rec (p_idx).arr_buff_end (lv_start - 1) := p_end;
         END IF;
      END IF;
   END move_cache;

   PROCEDURE print_cache (p_direction NUMBER)
   IS
      lv_idx   NUMBER;
   BEGIN
      RETURN;

      CASE p_direction
         WHEN mc_forward
         THEN
            DBMS_OUTPUT.put_line ('Forward ');
         WHEN mc_previous
         THEN
            DBMS_OUTPUT.put_line ('Previous ');
         WHEN mc_file_start
         THEN
            DBMS_OUTPUT.put_line ('File Start ');
         WHEN mc_file_end
         THEN
            DBMS_OUTPUT.put_line ('File End ');
         WHEN mc_search
         THEN
            DBMS_OUTPUT.put_line ('Search ');
      END CASE;

      lv_idx := garr_file_rec (gv_file_idx).arr_buff_start.FIRST;

      WHILE lv_idx IS NOT NULL
      LOOP
         DBMS_OUTPUT.put_line
                         (   'Buff Number: '
                          || lv_idx
                          || ' - Start:'
                          || garr_file_rec (gv_file_idx).arr_buff_start
                                                                       (lv_idx)
                          || ' - End:'
                          || garr_file_rec (gv_file_idx).arr_buff_end (lv_idx)
                         );
         lv_idx := garr_file_rec (gv_file_idx).arr_buff_start.NEXT (lv_idx);
      END LOOP;
   END print_cache;

   -- After reading gv_lines from all RAC instances, need to sort out which lines are
   -- going to be returned for display. Because of the index by date concept, not all instances
   -- iwll have entries necessary for display at same time. Sort through entries
   -- and keep track of position of which lines used
   FUNCTION sort_rac_files (p_direction NUMBER)
      RETURN typ_text_rec_arr
   IS
      lv_current_idx    NUMBER;
      lv_inst_idx       NUMBER;
      lv_current_date   DATE;
      lv_idx            NUMBER;
      lv_exit           BOOLEAN          := FALSE;
      larr_lines        typ_text_rec_arr;
   BEGIN
      lv_idx := 1;


      FOR idx IN 1 .. garr_dblink.COUNT
      LOOP
         IF p_direction = mc_forward
         THEN
            garr_dblink (idx).current_idx :=
                                        garr_dblink (idx).current_lines.FIRST;

            IF garr_dblink (idx).current_idx is not null and
                    garr_dblink (idx).current_lines(garr_dblink (idx).current_idx).linedate IS NULL THEN
                WHILE garr_dblink(idx).CURRENT_idx IS NOT NULL LOOP
                    garr_dblink(idx).CURRENT_idx := garr_dblink (idx).current_lines.NEXT(garr_dblink(idx).CURRENT_idx);
                    IF garr_dblink (idx).current_lines(garr_dblink (idx).current_idx).linedate IS NOT NULL THEN
                        EXIT;
                    END IF;
                END LOOP;
            END IF;

            IF garr_dblink (idx).current_idx IS NOT NULL
            THEN
               garr_dblink (idx).CURRENT_DATE :=
                  garr_dblink (idx).current_lines
                                                (garr_dblink (idx).current_idx
                                                ).linedate;
            ELSE
               garr_dblink (idx).CURRENT_DATE := NULL;
            END IF;
         ELSE
            garr_dblink (idx).current_idx :=
                                         garr_dblink (idx).current_lines.LAST;

            IF garr_dblink (idx).current_idx IS NOT NULL
            THEN
               garr_dblink (idx).CURRENT_DATE :=
                  garr_dblink (idx).current_lines
                                                (garr_dblink (idx).current_idx
                                                ).linedate;
            ELSE
               garr_dblink (idx).CURRENT_DATE := NULL;
            END IF;
         END IF;
      END LOOP;

      LOOP
         -- What's the max current date
         FOR idx IN 1 .. garr_dblink.COUNT
         LOOP
            IF    lv_current_date IS NULL
               OR (    p_direction = mc_previous
                   AND lv_current_date < garr_dblink (idx).CURRENT_DATE
                  )
               OR (    p_direction = mc_forward
                   AND lv_current_date > garr_dblink (idx).CURRENT_DATE
                  )
            THEN
               lv_current_date := garr_dblink (idx).CURRENT_DATE;
               lv_inst_idx := idx;
            END IF;
         END LOOP;

         -- When through all the entries we're done
         EXIT WHEN lv_current_date IS NULL;

         -- Two loops just in case one of the entries
         FOR inst_idx IN lv_inst_idx .. garr_dblink.COUNT
         LOOP
            IF garr_dblink (inst_idx).CURRENT_DATE = lv_current_date
            THEN
               lv_current_idx := garr_dblink (inst_idx).current_idx;
               dbms_output.put_line('Current Idx: ' || lv_current_idx || ' - Instance:' || inst_idx);
               LOOP

                  larr_lines (lv_idx) :=
                        garr_dblink (inst_idx).current_lines (lv_current_idx);
                  larr_lines (lv_idx).text :=
                        garr_dblink (inst_idx).INSTANCE
                     || ' - '
                     || larr_lines (lv_idx).text;
                  lv_idx := lv_idx + 1;

                  IF lv_idx > gv_lines
                  THEN
                     lv_exit := TRUE;

                  END IF;

                  IF p_direction = mc_previous
                  THEN
                     garr_dblink(inst_idx).start_pos := garr_dblink(inst_idx).current_lines(lv_current_idx).startpos;
                     lv_current_idx :=
                        garr_dblink (inst_idx).current_lines.PRIOR
                                                              (lv_current_idx);

                  ELSE
                     garr_dblink(inst_idx).end_pos := garr_dblink(inst_idx).current_lines(lv_current_idx).endpos;
                     lv_current_idx :=
                        garr_dblink (inst_idx).current_lines.NEXT
                                                              (lv_current_idx);
                  END IF;

                  IF    lv_exit
                     OR lv_current_idx IS NULL
                     OR garr_dblink (inst_idx).current_lines (lv_current_idx).linedate !=
                                                               lv_current_date
                  THEN
                     EXIT;
                  END IF;
               END LOOP;

               garr_dblink (inst_idx).current_idx := lv_current_idx;

               IF lv_current_idx IS NULL
               THEN
                  garr_dblink (inst_idx).CURRENT_DATE := NULL;
               ELSE
                  garr_dblink (inst_idx).CURRENT_DATE :=
                     garr_dblink (inst_idx).current_lines (lv_current_idx).linedate;
               END IF;

               IF lv_exit
               THEN
                  EXIT;
               END IF;
            END IF;
         END LOOP;

         IF lv_exit
         THEN
            EXIT;
         END IF;

         lv_current_date := NULL;
      END LOOP;

      RETURN larr_lines;
   END sort_rac_files;

   -- Procedure to do the remote lookup on files and assign the lines to local variables
   PROCEDURE read_remote (
      p_idx         NUMBER,
      p_pos         NUMBER,
      p_direction   NUMBER,
      p_search      VARCHAR2,
      p_case        NUMBER,
      p_time        NUMBER
   )
   IS
      lv_sql   VARCHAR2 (1000);
   BEGIN
      lv_sql :=
            'DECLARE  larr_lines  quest_soo_alerttrace.typ_text_rec_arr@ '
         || garr_dblink (p_idx).dblink
         || '; '
         || 'BEGIN   larr_lines := quest_soo_alerttrace.read_rac@'
         || garr_dblink (p_idx).dblink
         || '(:1,:2,:3,:4,:5, :6); '
         || 'FOR idx IN 1..larr_lines.COUNT LOOP '
         || 'quest_soo_alerttrace.garr_tmp_text(idx).startpos := larr_lines(idx).startpos; '
         || 'quest_soo_alerttrace.garr_tmp_text(idx).endpos := larr_lines(idx).endpos; '
         || 'quest_soo_alerttrace.garr_tmp_text(idx).linedate := larr_lines(idx).linedate; '
         || 'quest_soo_alerttrace.garr_tmp_text(idx).text := larr_lines(idx).text; '
         || 'END LOOP; '
         || 'END;';

      quest_soo_tracing.add_debug(mc_package_name, 'read_remote', 100, lv_sql || ' =========' ||
                                    p_pos || ':' || p_direction || ':' || p_search || ':' || p_time || ':' || gv_lines);
      quest_soo_tracing.flush_data;

      EXECUTE IMMEDIATE lv_sql
                  USING IN p_pos,
                        IN p_direction,
                        IN p_search,
                        IN p_case,
                        IN p_time,
                        IN gv_lines;

      garr_dblink (p_idx).current_lines := garr_tmp_text;
      garr_tmp_text.DELETE;
   EXCEPTION
    WHEN OTHERS THEN
        gv_restart := 1;
        quest_soo_tracing.process_exception(mc_package_name, 'read_remote',200,sqlcode,sqlerrm);
        RAISE;
   END read_remote;

   -- Manage the reading of local and remote alert log files
   PROCEDURE perform_rac_file_read(p_idx NUMBER, p_direction NUMBER, p_start NUMBER DEFAULT NULL)
   IS
       lv_start     NUMBER;
       lv_direction NUMBER;
       lv_reset     NUMBER;
      lv_start_pos   NUMBER;
      lv_end_pos     NUMBER;
   BEGIN
        garr_dblink (p_idx).current_lines.delete;
        IF p_direction = mc_previous
         THEN
            lv_direction := mc_previous;
            IF p_start IS NOT NULL THEN
                lv_start := p_start;
            ELSE
            lv_start := garr_file_rec (p_idx).arr_buff_start
                                     (garr_file_rec (p_idx).arr_buff_start.FIRST
                                     )
               - 1;
            END IF;
            IF lv_start <= mc_file_start_pos THEN
                RETURN;
            END IF;
         ELSIF p_direction = mc_file_start
         THEN
            lv_direction := mc_forward;
            lv_start := nvl(p_start, mc_file_start_pos);
         ELSIF p_direction != mc_file_end
         THEN
            lv_direction := mc_forward;
            IF p_start IS NOT NULL THEN
                lv_start := p_start;
            ELSE
                lv_start := garr_file_rec (p_idx).arr_buff_end
                                        (garr_file_rec (p_idx).arr_buff_end.LAST
                                        ) + 1;
            END IF;

            IF lv_start >= gv_file_size THEN
                RETURN;
            END IF;
         END IF;


         IF garr_dblink (p_idx).dblink IS NULL
         THEN
            IF p_direction = mc_file_end
            THEN
               lv_start := nvl(p_start,gv_file_size);
               lv_direction := mc_previous;
               lv_reset := -1;
            END IF;
            dbms_output.put_line('Start Pos :' || lv_start);
            garr_dblink (p_idx).current_lines :=
               lf_read_lines (lv_start,
                              lv_direction,
                              lv_start_pos,
                              lv_end_pos,
                              lv_reset
                             );
         ELSE
            IF p_direction = mc_file_end
            THEN
               lv_start := p_start;
               lv_direction := mc_previous;
               lv_reset := -1;
            END IF;
            dbms_output.put_line('Start Pos :' || lv_start);
            read_remote (p_idx, lv_start, lv_direction, NULL, 0, 5);
         END IF;

         lv_start_pos := garr_dblink (p_idx).current_lines.FIRST;
         lv_end_pos := garr_dblink (p_idx).current_lines.LAST;

         IF lv_start_pos IS NOT NULL
         THEN
            garr_dblink (p_idx).start_date :=
                      garr_dblink (p_idx).current_lines (lv_start_pos).linedate;
            garr_dblink (p_idx).end_date :=
                        garr_dblink (p_idx).current_lines (lv_end_pos).linedate;
            garr_dblink (p_idx).CURRENT_DATE := garr_dblink (p_idx).end_date;
            garr_dblink (p_idx).current_idx := lv_end_pos;
            garr_dblink (p_idx).start_pos :=
                      garr_dblink (p_idx).current_lines (lv_start_pos).startpos;
            garr_dblink (p_idx).end_pos :=
                          garr_dblink (p_idx).current_lines (lv_end_pos).endpos;

            IF garr_dblink (p_idx).current_lines (lv_start_pos).linedate IS NULL THEN
                WHILE lv_start_pos IS NOT NULL  LOOP
                    lv_start_pos := garr_dblink (p_idx).current_lines.NEXT(lv_start_pos);
                    IF lv_start_pos IS NOT NULL
                        AND garr_dblink (p_idx).current_lines (lv_start_pos).linedate IS NOT NULL
                    THEN
                        garr_dblink (p_idx).start_date := garr_dblink (p_idx).current_lines (lv_start_pos).linedate;
                        EXIT;
                    END IF;
                END LOOP;
            END IF;

         END IF;
   END perform_rac_file_read;

   -- Read all the files from RAC instances
   -- At the moment just assume looking at end of file
   -- Additional functionality to come
   FUNCTION read_rac_files (p_direction NUMBER)
      RETURN typ_text_rec_arr
   IS
      lv_start       NUMBER;
      lv_direction   NUMBER;
      lv_start_pos   NUMBER;
      lv_end_pos     NUMBER;
      lv_reset       NUMBER      := 0;
      larr_lines     typ_text_rec_arr;
   BEGIN
      -- First we need to sort through the entries in RAC and assign to local variables
      FOR idx IN 1 .. garr_dblink.COUNT
      LOOP
        perform_rac_file_read(idx, p_direction);
      END LOOP;

      IF p_direction IN (mc_file_start, mc_forward) THEN
        lv_direction := mc_forward;
      ELSE
        lv_direction := mc_previous;
      END IF;

      larr_lines := sort_rac_files (lv_direction);

      IF larr_lines.COUNT = 0 THEN
        RETURN larr_lines;
      END IF;

      FOR idx IN 1 .. garr_dblink.COUNT
      LOOP
         IF p_direction IN (mc_file_start, mc_file_end)
         THEN
            reset_cache (lv_direction,
                         garr_dblink (idx).start_pos,
                         garr_dblink (idx).end_pos,
                         idx
                        );
         ELSE

           move_cache (lv_direction,
                        garr_dblink (idx).start_pos,
                        garr_dblink (idx).end_pos,
                        idx
                       );
         END IF;
      END LOOP;

      RETURN larr_lines;
   END read_rac_files;

   FUNCTION search_rac_files(p_direction NUMBER, p_search VARCHAR2, p_search_mode NUMBER, p_days NUMBER) RETURN typ_text_rec_arr
   IS
        larr_lines      typ_text_rec_arr;
        larr_date       typ_date;
        larr_position   typ_idx;

        lv_date         date;
        lv_instance     NUMBER;
        lv_direction    NUMBER;
        lv_start_pos    NUMBER;
        lv_tmp_date     date;
        lv_pos          NUMBER;
   BEGIN

        IF p_direction = mc_file_start THEN
            lv_direction := mc_forward;
        ELSIF p_direction = mc_file_end THEN
            lv_direction := mc_previous;
        ELSE
            lv_direction := p_direction;
        END IF;

        FOR idx IN 1..garr_dblink.COUNT LOOP

            IF p_direction = mc_file_start THEN
                lv_start_pos := mc_file_start_pos;
            ELSIF p_direction = mc_file_end THEN
                IF garr_dblink(idx).dblink IS NULL THEN
                    lv_start_pos := gv_file_size;
                ELSE
                    lv_start_pos := NULL;
                END IF;
            ELSIF p_direction = mc_forward THEN
                lv_start_pos := garr_file_rec(idx).arr_buff_end(garr_file_rec(idx).arr_buff_end.LAST) + 1;
            ELSIF p_direction = mc_previous THEN
                lv_start_pos := garr_file_rec (idx).arr_buff_start
                                     (garr_file_rec (idx).arr_buff_start.FIRST
                                     )
                                      - 1;
            END IF;

            lv_tmp_date := NULL;

            IF garr_dblink(idx).dblink IS NULL THEN
                search_date(lv_start_pos,p_direction,p_search,p_search_mode,p_days, 0,lv_tmp_date,lv_pos);
            ELSE
                quest_soo_tracing.add_debug(mc_package_name, 'search_rac_files', 100, 'begin QUEST_SOO_ALERTTRACE.search_date@' ||
                            garr_dblink(idx).dblink || '(:1, :2, :3, :4, :5, 1, :6, :7); end; =====' ||
                            lv_start_pos || ':' || lv_direction || ':' || p_search || ':' || p_search_mode || ':' || p_days);
                quest_soo_tracing.flush_data;

                execute IMMEDIATE 'begin QUEST_SOO_ALERTTRACE.search_date@' ||
                            garr_dblink(idx).dblink || '(:1, :2, :3, :4, :5, 1, :6, :7); end;'
                USING in lv_start_pos, in lv_direction, in p_search, in p_search_mode, in p_days, out lv_tmp_date, out lv_pos;
            END IF;

            IF lv_tmp_date IS NOT NULL THEN
                IF lv_date IS NULL THEN
                    lv_date := lv_tmp_date;
                    lv_instance := idx;
                ELSIF lv_direction = mc_forward and lv_tmp_date < lv_date  THEN
                    lv_date := lv_tmp_date;
                    lv_instance := idx;
                ELSIF lv_direction = mc_previous AND lv_tmp_date > lv_date THEN
                    lv_date := lv_tmp_date;
                    lv_instance := idx;
                END IF;
            END IF;
        END LOOP;

        IF lv_date IS NOT NULL THEN
            larr_lines := move_rac(lv_date, lv_direction);
        END IF;

        RETURN larr_lines;
   EXCEPTION
    WHEN OTHERS THEN
        gv_restart := 1;
        quest_soo_tracing.process_exception(mc_package_name,'search_rac_files',200,sqlcode,sqlerrm);
        RAISE;
   END search_rac_files;

   -- Move RAC archive logs to a particular date.
   FUNCTION  move_rac(p_date DATE, p_direction NUMBER DEFAULT mc_forward)
   RETURN typ_text_rec_arr IS
        larr_lines      typ_text_rec_arr;
        lv_position     NUMBER;
   BEGIN

        FOR idx IN 1..garr_dblink.COUNT LOOP

            IF garr_dblink(idx).dblink IS NULL THEN
                lv_position := date_position(p_date, 1, p_direction );
            ELSE
                quest_soo_tracing.add_debug(mc_package_name, 'move_rac', 100, 'select QUEST_SOO_ALERTTRACE.date_position@' ||
                        garr_dblink(idx).dblink || '(:1, 0, :2) from dual =========' || TO_CHAR(p_date, 'DD-Mon-YYYY HH24:MI:SS') || ':' || p_direction);
                quest_soo_tracing.flush_data;

                execute IMMEDIATE 'select QUEST_SOO_ALERTTRACE.date_position@' ||
                        garr_dblink(idx).dblink || '(:1, 0, :2) from dual'
                INTO lv_position USING in p_date, IN p_direction ;
            END IF;

            IF lv_position IS NOT NULL THEN
                perform_rac_file_read(idx, p_direction, lv_position);
            ELSE
                garr_dblink (idx).current_lines.delete;
                garr_dblink (idx).start_date := NULL;
                garr_dblink (idx).end_date := NULL;
                garr_dblink (idx).CURRENT_DATE := NULL;
                garr_dblink (idx).current_idx := 0;
                garr_dblink (idx).start_pos := 0;
                garr_dblink (idx).end_pos := 0;
            END IF;

        END LOOP;

        larr_lines := sort_rac_files (p_direction);

        FOR idx IN 1 .. garr_dblink.COUNT
        LOOP
            reset_cache (p_direction,
                         garr_dblink (idx).start_pos,
                         garr_dblink (idx).end_pos,
                         idx
                        );
        END LOOP;

        RETURN larr_lines;
   EXCEPTION
    WHEN OTHERS THEN
        gv_restart := 1;
        quest_soo_tracing.process_exception(mc_package_name, 'move_rac', 200, SQLCODE, SQLERRM);
        RAISE;
   END move_rac;

   -- Main function to be called from outside. Takes in filename and series of parameters
   -- to describe what needs doing within file
   -- Search functionality is to be added still
   FUNCTION readfile (
      p_filename        VARCHAR2 DEFAULT NULL,
      p_nav             NUMBER DEFAULT 101,
      p_search          VARCHAR2 DEFAULT NULL,
      p_search_mode     NUMBER DEFAULT 0,
      p_read_seconds    NUMBER DEFAULT 5,
      p_read_rac        NUMBER DEFAULT 0
   )
      RETURN quest_soo_alerttrace_log_typ
   IS
      lv_start_pos      NUMBER;
      lv_end_pos        NUMBER;
      lv_cache_id       NUMBER;
      lv_reset          NUMBER;
      lv_read_seconds   NUMBER;
      lv_idx            NUMBER;
      larr_lines        typ_text_rec_arr;
      lnt_alert         quest_soo_alerttrace_log_typ;
      lrec_tmp_dblink   quest_soo_variable.typ_db_rec_arr;
      lc_proc_name      VARCHAR2(50) := 'READFILE';
   BEGIN
      quest_soo_tracing.add_debug(mc_package_name,lc_proc_name,100, 'Starting read:' || p_filename        || ':' ||
                                                                  p_nav             || ':' ||
                                                                  p_search          || ':' ||
                                                                  p_search_mode   || ':' ||
                                                                  p_read_seconds    || ':' ||
                                                                  p_read_rac        );

      -- If RAC, test for differences in DB links and do a reset if a difference is found
      IF p_read_rac = 1 THEN
         lv_reset := 0;
         gv_restart := 0;
         lrec_tmp_dblink := quest_soo_variable.get_current_dblinks;
         IF lrec_tmp_dblink.COUNT != garr_dblink_base.COUNT THEN
            lv_reset := 1;
            quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 120, 'Change in DB links. Do a reset ');
         END IF;

         IF lv_reset = 0 THEN
            FOR idx IN 1..lrec_tmp_dblink.COUNT LOOP
                IF NVL(lrec_tmp_dblink(idx).db_link, 'x') != nvl(garr_dblink_base(idx).db_link, 'x') THEN
                    lv_reset := 1;
                    quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 121, 'Different DB links');
                    EXIT;
                END IF;
            END LOOP;
         END IF;

         IF lv_reset = 1 THEN
            quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 122, 'Different DB links so send RESET command');
            init_dblink;
            RETURN readfile(p_filename,mc_file_end,NULL,p_search_mode,p_read_seconds,p_read_rac);
         END IF;

      END IF;

      -- Set reset of screen buffer to false
      -- When creating table later this will be used to multiply position details
      -- 1 means no reset. -1 means a reset
      lv_reset := 1;
      -- Open file up
      lp_open_file (p_filename);
      -- Get file length
      gv_file_size := DBMS_LOB.getlength (gv_bfile);
      -- Default read seconds to 5
      lv_read_seconds := NVL (p_read_seconds, 5);

      quest_soo_tracing.add_debug(mc_package_name,lc_proc_name,101, 'File size:' || gv_file_size);

      -- Determine what we're needed to do
      CASE p_nav
         WHEN mc_file_end
         THEN
            IF p_search IS NULL
            THEN
               BEGIN
                  lv_reset := -1;
                  IF p_read_rac = 1
                  THEN
                     larr_lines := read_rac_files (mc_file_end);
                  ELSE
                     -- Wipe out current cache and start from beginning
                     lv_reset := -1;
                     larr_lines :=
                        lf_read_lines (gv_file_size,
                                       mc_previous,
                                       lv_start_pos,
                                       lv_end_pos,
                                       lv_reset
                                      );
                     reset_cache (mc_previous, lv_start_pos, lv_end_pos);
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name,lc_proc_name,101,sqlcode,sqlerrm);
                     raise_application_error (-20004,
                                                 'Error reading to EOF:'
                                              || SQLERRM
                                             );
               END;
            ELSE
               BEGIN
                  IF p_read_rac = 0 THEN
                  lv_start_pos := gv_file_size;
                  larr_lines :=
                     lf_search (lv_start_pos,
                                mc_previous,
                                p_search,
                                p_search_mode,
                                lv_reset,
                                lv_read_seconds
                               );
                  ELSE
                    larr_lines := search_rac_files(p_nav,p_search,p_search_mode,lv_read_seconds);
                    IF larr_lines.COUNT > 0 THEN
                        lv_reset := -1;
                    END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 102, SQLCODE, SQLERRM);
                     raise_application_error
                                         (-20005,
                                             'Error searching from EOF for :'
                                          || p_search
                                          || ' - Error:'
                                          || SQLERRM
                                         );
               END;
            END IF;
         WHEN mc_file_start
         THEN
            IF p_search IS NULL
            THEN
               BEGIN
                  IF p_read_rac = 1
                  THEN
                     larr_lines := read_rac_files (mc_file_start);
                  ELSE
                     -- Wipe out cache and start from beginning again
                     lv_reset := -1;
                     larr_lines :=
                        lf_read_lines (mc_file_start_pos,
                                       mc_forward,
                                       lv_start_pos,
                                       lv_end_pos,
                                       lv_reset
                                      );
                     reset_cache (mc_forward, lv_start_pos, lv_end_pos);
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 103, SQLCODE, SQLERRM);
                     raise_application_error (-20006,
                                                 'Error reading from SOF:'
                                              || SQLERRM
                                             );
               END;
            ELSE
               BEGIN
                  IF p_read_rac = 0 THEN
                  lv_start_pos := mc_file_start_pos;
                  larr_lines :=
                     lf_search (lv_start_pos,
                                mc_forward,
                                p_search,
                                p_search_mode,
                                lv_reset,
                                lv_read_seconds
                               );
                  ELSE
                    larr_lines := search_rac_files(p_nav,p_search,p_search_mode,lv_read_seconds);
                    IF larr_lines.COUNT > 0 THEN
                        lv_reset := -1;
                    END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 104, SQLCODE, SQLERRM);
                     raise_application_error (-20007,
                                                 'Error searching for '
                                              || p_search
                                              || ' from SOF:'
                                              || SQLERRM
                                             );
               END;
            END IF;
         WHEN mc_forward
         THEN
            IF p_search IS NULL
            THEN
               BEGIN
                  IF p_read_rac = 1
                  THEN
                     larr_lines := read_rac_files (mc_forward);
                  ELSE
                     -- Look forward through file. If cached positions exist use them
                     -- and advance position in cache
                     -- If cached entries dont exist or at end of cache move forward
                     -- through file for next gv_lines and alter cache to drop oldest entries
                     lv_start_pos :=
                          garr_file_rec (gv_file_idx).arr_buff_end
                                (garr_file_rec (gv_file_idx).arr_buff_end.LAST
                                )
                        + 1;

                     IF    garr_file_rec (gv_file_idx).file_length <
                                                                  gv_file_size
                        OR lv_start_pos <
                                       garr_file_rec (gv_file_idx).file_length
                     THEN
                        IF lv_start_pos >=
                                      garr_file_rec (gv_file_idx).file_length
                        THEN
                           lv_reset := -1;
                           larr_lines :=
                              lf_read_lines (gv_file_size,
                                             mc_previous,
                                             lv_start_pos,
                                             lv_end_pos,
                                             lv_reset
                                            );
                        ELSE
                           larr_lines :=
                              lf_read_lines (lv_start_pos,
                                             mc_forward,
                                             lv_start_pos,
                                             lv_end_pos,
                                             lv_reset
                                            );
                        END IF;

                        IF lv_reset = -1
                        THEN
                           reset_cache (mc_forward, lv_start_pos, lv_end_pos);
                        ELSE
                           move_cache (mc_forward, lv_start_pos, lv_end_pos);
                        END IF;
                     END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 105, SQLCODE, SQLERRM);
                     raise_application_error
                        (-20008,
                            'Error moving forward from position '
                         || garr_file_rec (gv_file_idx).arr_buff_end
                                 (garr_file_rec (gv_file_idx).arr_buff_end.LAST
                                 )
                         +  1
                         || ' - Error:'
                         || SQLERRM
                        );
               END;
            ELSE
               BEGIN
                  -- Search forward from end of buffer position
                  IF p_read_rac = 0 THEN
                  lv_start_pos :=
                       garr_file_rec (gv_file_idx).arr_buff_end
                                (garr_file_rec (gv_file_idx).arr_buff_end.LAST
                                )
                     + 1;
                  larr_lines :=
                     lf_search (lv_start_pos,
                                mc_forward,
                                p_search,
                                p_search_mode,
                                lv_reset,
                                lv_read_seconds
                               );
                  ELSE
                    larr_lines := search_rac_files(p_nav,p_search,p_search_mode,lv_read_seconds);
                    IF larr_lines.COUNT > 0 THEN
                        lv_reset := -1;
                    END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 105, SQLCODE, SQLERRM);
                     raise_application_error
                                 (-20009,
                                     'Error searching forward from position '
                                  || lv_start_pos
                                  || ' for text:'
                                  || p_search
                                  || '. Error is :'
                                  || SQLERRM
                                 );
               END;
            END IF;
         WHEN mc_previous
         THEN
            IF p_search IS NULL
            THEN
               -- Look back through file
               -- If alter position entries in cached positions removing oldest entries
               BEGIN
                  IF p_read_rac = 1
                  THEN
                     larr_lines := read_rac_files (mc_previous);
                  ELSE
                     lv_start_pos :=
                          garr_file_rec (gv_file_idx).arr_buff_start
                             (garr_file_rec (gv_file_idx).arr_buff_start.FIRST
                             )
                        - 1;

                     IF lv_start_pos > (mc_file_start_pos + 1)
                     THEN
                        larr_lines :=
                           lf_read_lines (lv_start_pos,
                                          mc_previous,
                                          lv_start_pos,
                                          lv_end_pos,
                                          lv_reset
                                         );

                        IF lv_reset = -1
                        THEN
                           reset_cache (mc_previous, lv_start_pos,
                                        lv_end_pos);
                        ELSE
                           move_cache (mc_previous, lv_start_pos, lv_end_pos);
                        END IF;
                     END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 106, SQLCODE, SQLERRM);
                     raise_application_error
                        (-20010,
                            'Error moving backwards through file from position '
                         || lv_start_pos
                         || '. Error:'
                         || SQLERRM
                        );
               END;
            ELSE
               BEGIN
                  -- Search backwards through file for search string
                  -- Start at beginning of buffer
                  IF p_read_rac = 0 THEN
                  lv_start_pos :=
                     garr_file_rec (gv_file_idx).arr_buff_start
                             (garr_file_rec (gv_file_idx).arr_buff_start.FIRST
                             );
                  larr_lines :=
                     lf_search (lv_start_pos,
                                mc_previous,
                                p_search,
                                p_search_mode,
                                lv_reset,
                                lv_read_seconds
                               );
                  ELSE
                    larr_lines := search_rac_files(p_nav,p_search,p_search_mode,lv_read_seconds);
                    IF larr_lines.COUNT > 0 THEN
                        lv_reset := -1;
                    END IF;
                  END IF;
               EXCEPTION
                  WHEN OTHERS
                  THEN
                     quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 107, SQLCODE, SQLERRM);
                     raise_application_error
                           (-20011,
                               'Error searching for string: '
                            || p_search
                            || ' backwards through file from start position:'
                            || lv_start_pos
                            || '. Error:'
                            || SQLERRM
                           );
               END;
            END IF;
         WHEN mc_search
         THEN
            BEGIN
               IF p_read_rac = 1 THEN
                    larr_lines := move_rac(TO_DATE(p_search, 'DD/MM/YYYY HH:MI:SS AM'));
               ELSE
               lv_start_pos :=
                  DBMS_LOB.INSTR (gv_bfile, '0A', TO_NUMBER (p_search), 1)
                  + 1;
               larr_lines :=
                  lf_read_lines (lv_start_pos,
                                 mc_forward,
                                 lv_start_pos,
                                 lv_end_pos,
                                 lv_reset
                                );
               reset_cache (mc_forward, lv_start_pos, lv_end_pos);
               lv_reset := -1;
            END IF;
            EXCEPTION
               WHEN OTHERS
               THEN
                  quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 108, SQLCODE, SQLERRM);
                  raise_application_error (-20012,
                                              'Error moving to position '
                                           || p_search
                                           || '. Error:'
                                           || SQLERRM
                                          );
            END;
         ELSE
            NULL;
      END CASE;

      -- No longer need size of file cache. Assign to keep for next time
      garr_file_rec (gv_file_idx).file_length := gv_file_size;

      --print_cache (p_nav);
      BEGIN
         lnt_alert := NEW quest_soo_alerttrace_log_typ ();
         lnt_alert.EXTEND (larr_lines.COUNT);

         IF p_read_rac = 1 AND p_nav IN (mc_previous, mc_file_end)  THEN
            lv_idx := larr_lines.LAST;
         ELSE
          lv_idx := larr_lines.FIRST;
         END IF;

         lv_start_pos := 1;
         WHILE lv_idx IS NOT NULL LOOP
            lnt_alert (lv_start_pos) :=
               quest_soo_alerttrace_line_typ (larr_lines (lv_idx).linedate,
                                              larr_lines (lv_idx).text,
                                                larr_lines (lv_idx).startpos
                                              * lv_reset
                                             );
            IF p_read_rac = 1 AND p_nav IN (mc_previous, mc_file_end) THEN
                lv_idx := larr_lines.PRIOR(lv_idx);
            ELSE
                lv_idx := larr_lines.NEXT(lv_idx);
            END IF;
            lv_start_pos := lv_start_pos + 1;
         END LOOP;
      EXCEPTION
         WHEN OTHERS
         THEN
            quest_soo_tracing.process_exception(mc_package_name, lc_proc_name, 109, SQLCODE, SQLERRM);
            raise_application_error
               (-20013,
                   'Error creating nested table for return statement. Error:'
                || SQLERRM
               );
      END;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 110, 'Closing files');

      close_all_file;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 111, 'End of read. Returning ' || lnt_alert.COUNT || ' lines');
      gv_retry_count := 0;
      RETURN lnt_alert;
   EXCEPTION
    WHEN OTHERS THEN
        close_all_file;

        IF p_read_rac = 1 AND gv_restart = 1 AND gv_retry_count < 5 THEN
            gv_retry_count := gv_retry_count + 1;
            RETURN readfile(p_filename,mc_file_end,null,p_search_mode,p_read_seconds,p_read_rac);
        END IF;

        /* RAISE;*/
   END readfile;

   -- For a given date, what position is it or closest forward date
   -- If p_local = 1 then local insance, else being read from RAC
   -- and need to open and close alert log file
   FUNCTION date_position(p_date DATE, p_local  NUMBER := 0, p_direction NUMBER DEFAULT mc_forward) RETURN NUMBER IS
      lv_current_pos    NUMBER;
      lv_current_date   DATE;
      lv_tmp_pos        NUMBER;
      lv_high_pos       NUMBER;
      lv_high_date      DATE;
      lv_low_pos        NUMBER;
      lv_low_date       date;
      lv_idx            NUMBER;
      lc_proc_name      VARCHAR2(50) := 'DATE_POSITION';
   BEGIN
      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 100,
                                  'Start. Parameters:' || to_char(p_date, 'DD-Mon-YYYY HH24:MI:SS') || ':Blank:' ||
                                  p_local || ':' || p_direction );

      -- Open file up if remote
      IF p_local = 0 THEN
        lp_open_file (NULL);
      END IF;
      -- Get file length
      gv_file_size := DBMS_LOB.getlength (gv_bfile);
      lv_high_pos := gv_file_size;
      lv_high_date := SYSDATE;
      lv_low_pos := 1;
      lv_low_date := '1-Jan-1900';
      lv_current_pos := 2;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 101,'File size:' || gv_file_size);
      find_date(lv_low_pos,lv_low_pos,lv_low_date,mc_forward);
      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 102, 'Start position:' || lv_low_pos || ': Date:' || TO_CHAR(lv_low_date, 'DD-Mon-YYYY HH24:MI:SS'));
      find_date(gv_file_size,lv_high_pos,lv_high_date,mc_previous);
      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 103, 'End position:' || lv_high_pos || ': Date:' || TO_CHAR(lv_high_date, 'DD-Mon-YYYY HH24:MI:SS'));

      IF NOT p_date BETWEEN lv_low_date AND lv_high_date THEN
        IF p_date < lv_low_date then
            quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 104, 'RETURNING zero');
            RETURN 0;
        ELSE
            RETURN gv_file_size;
            quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 105, 'Returning file size');
        end IF;
      END IF;

      if p_date = lv_high_date then
        quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 106, 'Returning high pos');
        return lv_high_pos;
      elsif p_date = lv_low_date then
        quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 107, 'Returning low pos');
        return lv_low_pos;
      end if;

      lv_idx := 1;

      LOOP

        lv_current_pos := lv_low_pos + trunc((lv_high_pos - lv_low_pos) / 2);
        find_date(lv_current_pos,lv_current_pos,lv_current_date);
        quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 108, 'Loop:' || lv_idx ||
                                    'High:' || lv_high_pos || ' High Date:' || TO_CHAR(lv_high_date, 'DD-Mon-YYYY HH24:MI:SS')
                                    || ' low pos:' || lv_low_pos || ' Low date:' || TO_CHAR(lv_low_date, 'DD-Mon-YYYY HH24:MI:SS') || ' Current Pos:' || lv_current_pos
                                    || ' Current Date:' || TO_CHAR(lv_current_date, 'DD-Mon-YYYY HH24:MI:SS'));
        /*
        IF lv_current_pos = lv_low_pos THEN
            find_date(lv_current_pos, lv_current_pos, lv_current_date, mc_forward);
            IF lv_current_pos IS NULL THEN
                find_date(lv_high_pos,lv_current_pos,lv_current_date,mc_previous);
                IF lv_current_date < p_date THEN
                    lv_current_pos := gv_file_size;
                    EXIT;
                END IF;
            END IF;
        END IF;
        */
        EXIT WHEN lv_idx >= 100 OR (lv_current_pos = lv_high_pos AND lv_current_date > p_date)
             OR (lv_low_date = lv_high_date AND lv_low_date > p_date);

        IF lv_current_date > p_date THEN
            lv_high_date := lv_current_date;
            lv_high_pos := lv_current_pos;
        ELSIF lv_current_date < p_date THEN
            lv_low_date := lv_current_date;
            lv_low_pos := lv_current_pos;
        ELSE
            EXIT;
        END IF;

        IF lv_low_pos = lv_current_pos AND lv_current_date < p_date THEN
            find_date(lv_current_pos + 1,lv_low_pos,lv_low_date,mc_forward);
        ELSIF lv_high_pos = lv_current_pos AND lv_current_date > p_date THEN
            find_date(lv_current_pos - 1,lv_high_pos,lv_high_date,mc_forward);
        END IF;
        lv_idx := lv_idx + 1;
      END LOOP;

      -- If we're looking backwards through the file, we don't want the start of the date position
      -- We're looking for the end. Find the end position of data associated with the date
      IF p_direction = mc_previous AND lv_current_date = p_date THEN
        WHILE lv_current_date = p_date AND lv_current_pos < gv_file_size LOOP
            find_date(lv_current_pos + 1, lv_current_pos,lv_current_date,mc_forward);
            --lv_current_pos := lv_current_pos - 2;
            lv_current_pos := DBMS_LOB.INSTR (gv_bfile, '0A', lv_current_pos - 5, 1)-1;
            IF lv_current_pos IS NULL THEN
                lv_current_pos := gv_file_size;
            END IF;
        END LOOP;
      ELSIF p_direction = mc_forward AND lv_current_date = p_date THEN
        WHILE lv_current_date = p_date AND lv_current_pos > mc_file_start_pos LOOP
            find_date(lv_current_pos - 1,lv_low_pos,lv_current_date,mc_previous);
            IF lv_low_pos IS NOT NULL AND lv_current_date = p_date THEN
                lv_current_pos := lv_low_pos;
            END IF;
        END LOOP;
      END IF;

      IF p_local = 0 THEN
        close_all_file;
      END IF;

      quest_soo_tracing.add_debug(mc_package_name, lc_proc_name, 109, 'Returning:' || lv_current_pos);

      RETURN lv_current_pos;
   END date_position;

   -- Designed for cross-rac instance execution. From a given position
   -- read set number of lines and return
   FUNCTION read_rac (
      p_start_pos       NUMBER,
      p_nav             NUMBER,
      p_search          VARCHAR2,
      p_search_mode   NUMBER,
      p_read_seconds    NUMBER,
      p_num_lines       NUMBER
   )
      RETURN typ_text_rec_arr
   IS
      larr_lines     typ_text_rec_arr;
      lv_start_pos   NUMBER;
      lv_end_pos     NUMBER;
      lv_reset       NUMBER      := 0;
   BEGIN
      IF p_nav NOT IN (mc_forward, mc_previous)
      THEN
         RETURN larr_lines;
      END IF;

      -- Open file up
      lp_open_file (NULL);
      -- Get file length
      gv_file_size := DBMS_LOB.getlength (gv_bfile);

      gv_lines := p_num_lines;

      IF p_start_pos IS NULL
      THEN
         lv_start_pos := gv_file_size;
      ELSE
         lv_start_pos := p_start_pos;
      END IF;

      IF (lv_start_pos <= mc_file_start_pos AND p_nav = mc_previous) OR
            (lv_start_pos >= gv_file_size AND p_nav = mc_forward) THEN
            close_all_file;
            RETURN larr_lines;
      END IF;

      larr_lines :=
         lf_read_lines (lv_start_pos,
                        p_nav,
                        lv_start_pos,
                        lv_end_pos,
                        lv_reset
                       );
      reset_cache (mc_previous, lv_start_pos, lv_end_pos);
      close_all_file;
      RETURN larr_lines;
   END read_rac;

   -- Retrieve all instances and DB links for RAC cluster.
   -- If DB link doesn't exist, create one
   PROCEDURE init_dblink
   IS
      lv_local       VARCHAR2 (50);
      arr_instance   typ_text;
      arr_db_link    typ_text;
   BEGIN
      garr_dblink_base := quest_soo_variable.get_current_dblinks;

      FOR idx IN 1 .. garr_dblink_base.COUNT
      LOOP
         garr_dblink (idx).INSTANCE := garr_dblink_base(idx).instance_name;
         garr_dblink(idx).dblink := garr_dblink_base(idx).db_link;

         gv_file_idx := idx;
         initfile (garr_dblink (idx).INSTANCE, garr_dblink (idx).dblink);
      END LOOP;
   END init_dblink;

   -- Find start and end date from files
   PROCEDURE start_end_date (o_start_date OUT DATE, o_end_date OUT DATE)
   IS
      lv_start_date   DATE;
      lv_end_date     DATE;
      lv_pos          NUMBER;
   BEGIN
      -- Open file up
      lp_open_file (NULL);
      -- Get file length
      gv_file_size := DBMS_LOB.getlength (gv_bfile);
      -- Find starting position
      find_date (mc_file_start_pos, lv_pos, lv_start_date, mc_forward);
      -- Find end position
      find_date (gv_file_size, lv_pos, lv_end_date);
      o_start_date := lv_start_date;
      o_end_date := lv_end_date;
      close_all_file;
   END start_end_date;

   -- Add an alarm to search for in alarm generation
   -- Alarms are ordered by severity and order added, with highest severity alarms
   -- listed first
   PROCEDURE add_alarm(p_alarm_text     VARCHAR2, p_severity    NUMBER) IS
       lrec_alarm   typ_alarm_rec_arr;
       lv_pos_idx   NUMBER;
       lv_global_idx NUMBER;
       lv_copied     BOOLEAN := FALSE;
   BEGIN

       lv_pos_idx := 1;
       lv_global_idx := garr_alarm_rec.FIRST;
       IF lv_global_idx IS NOT NULL THEN
          WHILE lv_global_idx IS NOT NULL LOOP
              IF lv_copied or garr_alarm_rec(lv_global_idx).severity <= p_severity THEN
                 lrec_alarm(lv_pos_idx) := garr_alarm_rec(lv_global_idx);
              ELSE
                 lrec_alarm(lv_pos_idx).search_text := p_alarm_text;
                 lrec_alarm(lv_pos_idx).severity := p_severity;
                 lv_pos_idx := lv_pos_idx + 1;
                 lrec_alarm(lv_pos_idx) := garr_alarm_rec(lv_global_idx);
              END IF;
              lv_pos_idx := lv_pos_idx + 1;
              lv_global_idx := garr_alarm_rec.NEXT(lv_global_idx);
          END LOOP;
          garr_alarm_rec := lrec_alarm;
       ELSE
          garr_alarm_rec(lv_pos_idx).search_text := p_alarm_text;
          garr_alarm_rec(lv_pos_idx).severity := p_severity;

       END IF;
       dbms_output.put_line(p_alarm_text);
   END add_alarm;

   -- Designed to be run from a SQL statement. Open the file (don't change cache in any way)
   -- and for the last p_minutes find any of the alarm conditions within instance that refer to previously
   -- entered alarm conditions.
   FUNCTION find_alarms(p_minutes NUMBER, p_rac   NUMBER) RETURN quest_soo_alerttrace_log_typ IS
        lv_date         DATE;
        lnt_alarm       quest_soo_alerttrace_log_typ;
        lv_date_pos     NUMBER;
        lv_start_pos    NUMBER;
        lv_end_pos      NUMBER;
        lv_text         VARCHAR2(9000);
        lv_search_pos   NUMBER;
        lv_exception    VARCHAR2(400);
        lv_excp_date    DATE;
   BEGIN
        lv_date := SYSDATE - (p_minutes / (60 * 24));
        lnt_alarm := NEW quest_soo_alerttrace_log_typ();

        lp_open_file(null);

        lv_date_pos := date_position(lv_date,1, mc_forward);


        gv_file_size := DBMS_LOB.getlength(gv_bfile);

        dbms_output.put_line(TO_CHAR(lv_date, 'DD-Mon-YYYY HH24:MI:SS') || ':' || lv_date_pos || ':' || gv_file_size);

        lv_end_pos := gv_file_size;
        lv_start_pos := GREATEST(lv_date_pos, lv_end_pos - 8192);
        LOOP
            lv_text := UTL_RAW.cast_to_varchar2 (DBMS_LOB.substr(gv_bfile,(lv_end_pos - lv_start_pos),lv_start_pos));
            FOR idx IN 1..garr_alarm_rec.COUNT LOOP
                lv_search_pos := INSTR(lv_text, garr_alarm_rec(idx).search_text, -1);
                IF lv_search_pos > 0 THEN
                    lv_exception := garr_alarm_rec(idx).search_text;
                    EXIT;
                END IF;
            END LOOP;

            IF lv_search_pos > 0 OR lv_start_pos <= lv_date_pos THEN
                EXIT;
            ELSE
                lv_end_pos := lv_start_pos + 100;
                lv_start_pos := GREATEST(lv_date_pos, lv_end_pos - 8192);
            END IF;
        END LOOP;

        IF lv_search_pos > 0 THEN
            find_date(lv_search_pos + lv_start_pos,lv_date_pos,lv_excp_date,mc_previous);
            lnt_alarm.EXTEND;
            lnt_alarm(1) := QUEST_SOO_ALERTTRACE_LINE_TYP(lv_excp_date, lv_exception, lv_start_pos + lv_search_pos);
        END IF;

        close_all_file;

        RETURN lnt_alarm;

   END find_alarms;

   -- Initialize instance name and bdump directory paths so don't have to continually
   -- read them during read procedures
   PROCEDURE initialize
   IS
   BEGIN
      execute immediate 'SELECT instance_name
                         FROM v$instance'
                         INTO gv_instance;


      -- With Oracle 12.1 and greater Oracle now store the alert log location
      -- in v$diag_info and are going to deprecate BACKGROUND_DUMP_DEST.
      --So, we need to get the version of the db and query the dest if => 12.1

      IF quest_soo_pkg.get_db_version >= 12.1 THEN
          execute immediate 'SELECT value
                             FROM v$diag_info
                             WHERE name like ''Diag Trace'''
                             INTO gv_dump_dir;


      ELSE
          execute immediate 'SELECT VALUE
                             FROM v$parameter
                             WHERE NAME = ''background_dump_dest'''
                             INTO gv_dump_dir;

      END IF;


      IF INSTR(gv_dump_dir, '@') > 0 THEN
          gv_dump_dir := REPLACE(gv_dump_dir, '@', gv_instance);
      END IF;

      IF SUBSTR (gv_dump_dir, 1, 1) = '/'
      THEN
         -- Unix
         IF SUBSTR (gv_dump_dir, LENGTH (gv_dump_dir), 1) != '/'
         THEN
            gv_dump_dir := gv_dump_dir || '/';
         END IF;
      ELSE
         -- Windows
         IF SUBSTR (gv_dump_dir, LENGTH (gv_dump_dir), 1) != '\'
         THEN
            gv_dump_dir := gv_dump_dir || '\';
         END IF;
      END IF;
   END initialize;

   FUNCTION read_raw_file (p_filename          VARCHAR2,
                           p_operation_mode    NUMBER := mc_read_full_file,
                           p_bytes             NUMBER := NULL)
      RETURN quest_soo_raw_tab_typ
      PIPELINED
   IS
      l_req_read_amount    INTEGER := 4000;
      l_read_amount        INTEGER := l_req_read_amount;
      l_read_offset        INTEGER := 1;
      l_read_buffer        RAW (4000);
      l_file_snipped       BOOLEAN := FALSE;
      l_snip_line_output   RAW (4000)
         := UTL_RAW.
             cast_to_raw (
               CHR (10) || '----------------SNIP----------------' || CHR (10));
   BEGIN
      lp_open_file (p_filename);

      /* If only reading the tail of the file, set the offset to the end of the file less the amount of bytes to read */
      IF p_operation_mode = mc_read_tail_file
      THEN
         l_read_offset := gv_file_size - p_bytes + 1;
      END IF;

      /* If only reading the head of file, or snipping the file, and the amount of bytes to read is less than the default single read, set the single read to read that amount */
      IF p_operation_mode IN (mc_read_head_file, mc_read_snip_file)
         AND p_bytes < (l_read_offset + l_read_amount)
      THEN
         l_read_amount := p_bytes - l_read_offset + 1;
      END IF;

      /* While there is data to be read, loop through the file */
      WHILE l_read_amount > 0
      LOOP
         BEGIN
            DBMS_LOB.read (gv_bfile,
                           l_read_amount,
                           l_read_offset,
                           l_read_buffer);
            PIPE ROW (l_read_buffer);
         EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
               /* If cannot read any data, it raises NO_DATA_FOUND and sets l_read_amount to 0
                  We should fall through to the code below which will handle this
                  In 9i, dbms_lob.read does not set l_read_amount to 0 so we should set it to be safe */
               l_read_amount := 0;
         END;

         l_read_offset := l_read_offset + l_read_amount;

         /* If reading the head of the file (including for a snip operation), and the next read would take us past the p_bytes parameter,
            then set the next read to be the amount needed to get to p_bytes */
         IF     p_operation_mode IN (mc_read_head_file, mc_read_snip_file)
            AND l_file_snipped = FALSE
            AND p_bytes < (l_read_offset + l_read_amount)
         THEN
            l_read_amount := p_bytes - l_read_offset + 1;
         END IF;

         /* If snipping a file, check if the head portion has been completely read
            Output the snip line, and set up next read to start at the tail of the file */
         IF     p_operation_mode = mc_read_snip_file
            AND l_file_snipped = FALSE
            AND l_read_amount <= 0
         THEN
            PIPE ROW (l_snip_line_output);
            l_read_offset := gv_file_size - p_bytes + 1;
            l_read_amount :=
               LEAST (gv_file_size - p_bytes + 1, l_req_read_amount);
            l_file_snipped := TRUE;
         END IF;
      END LOOP;


      close_all_file;
      RETURN;
   EXCEPTION
      WHEN OTHERS
      THEN
         close_all_file;
         RAISE;
   END;


-- When package loads run initialization procedure
BEGIN
   initialize;
END quest_soo_alerttrace;
/
