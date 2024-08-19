CREATE OR REPLACE PACKAGE LGONZALES.quest_soo_util
  AUTHID Current_User
AS
--
-- This package contains utility routines to support Spotlight On Oracle
--
-- Person      Date         Comments
-- ---------   -----------  -----------------------------------------------
-- Joe T       14-Jan-2008  Initial

   -- Get details about events on system.
   -- Replacement for quest_soo_pkb.event_detail_41 and wait_detail_41
   FUNCTION event_detail (
      p_event    VARCHAR2,
      p_p1text   VARCHAR2,
      p_p1       NUMBER,
      p_p2text   VARCHAR2,
      p_p2       NUMBER,
      p_p3text   VARCHAR2,
      p_p3       NUMBER,
      p_type     PLS_INTEGER DEFAULT 1               -- 1 is Event, 2 is Wait
   )
      RETURN VARCHAR2;

   -- Do some transformation and return a lock type description
   FUNCTION get_lock_type_desc (p_lock_type VARCHAR2, p_id2 NUMBER DEFAULT -1)
      RETURN VARCHAR2;

   -- Get lock mode description
   -- It's a number so use indexing from 0 to 6
   FUNCTION get_lock_mode_desc (p_idx PLS_INTEGER)
      RETURN VARCHAR2;

   -- Get lock mode description
   -- If part of Q, X, N etc then will be ok
   FUNCTION get_lock_mode_desc (p_idx VARCHAR2)
      RETURN VARCHAR2;

END quest_soo_util;
/
