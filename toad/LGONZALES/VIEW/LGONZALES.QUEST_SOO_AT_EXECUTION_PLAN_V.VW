CREATE OR REPLACE FORCE VIEW LGONZALES.QUEST_SOO_AT_EXECUTION_PLAN_V
(TRACE_FILE_ID, SQL_ID, PARSE_ID, ID, CNT, 
 PID, POS, OBJ, CR, PR, 
 PW, TIME_US, OP)
BEQUEATH DEFINER
AS 
SELECT trace_file_id, ep.sql_id, ep.parse_id, ep.ID, ep.cnt, ep.pid,
          ep.pos, ep.obj, ep.cr, ep.pr, ep.pw, ep.time_us,
          o.operation_string op
     FROM quest_soo_at_execution_plan ep JOIN quest_soo_at_operations o
          USING (trace_file_id, operation_id);
