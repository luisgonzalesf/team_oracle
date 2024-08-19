CREATE OR REPLACE PACKAGE LGONZALES.QUEST_SOO_SCHEMA_MGR
  AUTHID Current_User
IS
   -- Check that a table exists
   FUNCTION table_exists (p_table_name VARCHAR2)
      RETURN BOOLEAN;
   -- Get the version of an SOO schema
   FUNCTION get_version (p_schema_id VARCHAR2)
      RETURN NUMBER;

   -- Set the version of an SOO schema
   PROCEDURE set_version (p_schema_id VARCHAR2, p_version NUMBER);

   -- initialize the package objects (tables, etc)
   PROCEDURE init;
END;
/
