CREATE OR REPLACE PACKAGE BODY LGONZALES.QUEST_SOO_SCHEMA_MGR
IS
TYPE cvtype IS REF CURSOR;

   FUNCTION table_exists (p_table_name VARCHAR2)
      RETURN BOOLEAN
   IS
      l_count          INTEGER := 0;
      l_table_exists   BOOLEAN := FALSE;
   BEGIN
      SELECT COUNT (*)
        INTO l_count
        FROM user_tables
       WHERE table_name = p_table_name;

      IF l_count > 0
      THEN
         l_table_exists := TRUE;
      END IF;

      RETURN (l_table_exists);
   END;

   PROCEDURE create_schema_version_table
   IS
      sqltext   VARCHAR2 (2000)
         := 'CREATE TABLE quest_soo_schema_versions
               (schema_id varchar2(256) primary key,
                version  number not null)';
   BEGIN
      EXECUTE IMMEDIATE sqltext;
   END;

   FUNCTION get_version (p_schema_id VARCHAR2)
      RETURN NUMBER
   IS
      l_version     NUMBER;
      version_csr   cvtype;
   BEGIN
      OPEN version_csr FOR    'SELECT version FROM quest_soo_schema_versions '
                           || ' WHERE schema_id=:b_schema_id ' USING
      p_schema_id;

      FETCH version_csr
       INTO l_version;

      IF version_csr%NOTFOUND
      THEN
         l_version := -1;
      END IF;

      CLOSE version_csr;

      RETURN (l_version);
   END;

   PROCEDURE set_version (p_schema_id VARCHAR2, p_version NUMBER)
   IS
      l_current_version   NUMBER;
   BEGIN
      l_current_version := get_version (p_schema_id);

      IF l_current_version = -1 OR l_current_version IS NULL
      THEN
         EXECUTE IMMEDIATE    'INSERT INTO quest_soo_schema_versions '
                           || '(schema_id,version) VALUES(:b_schema_id,:b_version) '
                     USING p_schema_id, p_version;
      ELSIF l_current_version != p_version
      THEN
         EXECUTE IMMEDIATE    'UPDATE quest_soo_schema_versions '
                           || 'SET version=:b_version WHERE schema_id=:b_schema_id '
                     USING p_version, p_schema_id;
      END IF;

      COMMIT;
   END;

   PROCEDURE init
   IS
   BEGIN
      IF NOT table_exists ('QUEST_SOO_SCHEMA_VERSIONS')
      THEN
         create_schema_version_table;
      END IF;
   END;

END;
/
