CREATE OR REPLACE PACKAGE LGONZALES.quest_soo_variable
  AUTHID Current_User
AS
   --
   -- This package contains common variables used within Spotlight
   --
   -- Person      Date     Comments
   -- ---------   ------   -----------------------------------------------
   -- Joe T       6-May-08 Inital Version

   TYPE typ_db_rec IS RECORD (
      instance_number   PLS_INTEGER,
      instance_name     VARCHAR2 (50),
      HOST              VARCHAR2 (64),
      db_link           VARCHAR2 (128)
   );

   TYPE typ_db_rec_arr IS TABLE OF typ_db_rec
      INDEX BY BINARY_INTEGER;

   grec_db_instance   typ_db_rec_arr;

   FUNCTION get_current_dblinks RETURN typ_db_rec_arr;

   PROCEDURE populate_data;

   FUNCTION get_parameter(p_parameter VARCHAR2) RETURN VARCHAR2;

   PROCEDURE set_parameter(p_parameter VARCHAR2, p_value VARCHAR2);

END quest_soo_variable;
/
