CREATE OR REPLACE TASK validated.task_process_dq
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('RAW.patient_stream') OR SYSTEM$STREAM_HAS_DATA('RAW.admissions_stream')
AS CALL validated.process_data_quality();

CREATE OR REPLACE TASK validated.task_populate_curated
  WAREHOUSE = COMPUTE_WH
  AFTER validated.task_process_dq
AS CALL curated.populate_curated_models();

CREATE OR REPLACE TASK validated.task_anomaly_engine
  WAREHOUSE = COMPUTE_WH
  AFTER validated.task_populate_curated
AS CALL governance.run_anomaly_engine();

-- Resume tasks
ALTER TASK validated.task_anomaly_engine RESUME;
ALTER TASK validated.task_populate_curated RESUME;
ALTER TASK validated.task_process_dq RESUME;

ALTER TASK validated.task_anomaly_engine suspend;
ALTER TASK validated.task_populate_curated suspend;
ALTER TASK validated.task_process_dq suspend;

EXECUTE TASK validated.task_process_dq;

EXECUTE TASK validated.task_process_dq;
