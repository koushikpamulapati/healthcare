CREATE OR REPLACE PROCEDURE curated.populate_curated_models()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- -------------------------------------------------------------
    -- SCD-2 for PATIENT DIMENSION
    -- -------------------------------------------------------------
    UPDATE curated.dim_patient tgt
    SET tgt.end_date = CURRENT_DATE(), tgt.current_flag = 'N'
    FROM validated.valid_patients src
    WHERE tgt.patient_id = src.patient_id 
      AND tgt.current_flag = 'Y' 
      AND (tgt.name != src.name OR tgt.state != src.state OR tgt.insurance_id != src.insurance_id);

    MERGE INTO curated.dim_patient tgt
    USING validated.valid_patients src
    ON tgt.patient_id = src.patient_id AND tgt.current_flag = 'Y'
    WHEN NOT MATCHED THEN 
      INSERT (patient_sk, patient_id, name, state, insurance_id, start_date, end_date, current_flag)
      VALUES (UUID_STRING(), src.patient_id, src.name, src.state, src.insurance_id, CURRENT_DATE(), NULL, 'Y');

    -- -------------------------------------------------------------
    -- SCD-2 for DOCTOR DIMENSION
    -- -------------------------------------------------------------
    UPDATE curated.dim_doctor tgt
    SET tgt.end_date = CURRENT_DATE(), tgt.current_flag = 'N'
    FROM validated.valid_doctors src
    WHERE tgt.doctor_id = src.doctor_id 
      AND tgt.current_flag = 'Y' 
      AND (tgt.department != src.department);

    MERGE INTO curated.dim_doctor tgt
    USING validated.valid_doctors src
    ON tgt.doctor_id = src.doctor_id AND tgt.current_flag = 'Y'
    WHEN NOT MATCHED THEN 
      INSERT (doctor_sk, doctor_id, name, department, start_date, end_date, current_flag)
      VALUES (UUID_STRING(), src.doctor_id, src.name, src.department, CURRENT_DATE(), NULL, 'Y');

    -- -------------------------------------------------------------
    -- POPULATE FACT TABLE (fact_hospital_events)
    -- -------------------------------------------------------------
    
    -- A. ADMISSION Events
    MERGE INTO curated.fact_hospital_events tgt
    USING (
         SELECT 
            'ADMISSION' as e_type,
            a.admission_id,
            p.patient_sk,
            d.doctor_sk,
            a.admission_time,
            a.discharge_time,
            a.department,
            a.bed_no
         FROM validated.valid_admissions a
         JOIN curated.dim_patient p ON a.patient_id = p.patient_id AND p.current_flag = 'Y'
         JOIN curated.dim_doctor d ON a.attending_doctor_id = d.doctor_id AND d.current_flag = 'Y'
    ) src ON tgt.admission_id = src.admission_id AND tgt.event_type = src.e_type
    WHEN MATCHED THEN UPDATE SET 
        tgt.discharge_time = src.discharge_time, 
        tgt.department = src.department,
        tgt.bed_no = src.bed_no
    WHEN NOT MATCHED THEN INSERT 
        (event_sk, event_type, admission_id, patient_sk, doctor_sk, admission_time, discharge_time, department, bed_no)
    VALUES 
        (UUID_STRING(), src.e_type, src.admission_id, src.patient_sk, src.doctor_sk, src.admission_time, src.discharge_time, src.department, src.bed_no);

    -- B. PROCEDURE Events
    MERGE INTO curated.fact_hospital_events tgt
    USING (
         SELECT 
            'PROCEDURE' as e_type,
            pr.procedure_id,
            pr.admission_id,
            p.patient_sk,
            vd.doctor_sk as surgeon_sk,
            pr.scheduled_time,
            pr.start_time,
            pr.end_time,
            va.department
         FROM validated.valid_procedures pr
         JOIN validated.valid_admissions va ON pr.admission_id = va.admission_id
         JOIN curated.dim_patient p ON va.patient_id = p.patient_id AND p.current_flag = 'Y'
         JOIN curated.dim_doctor vd ON pr.surgeon_id = vd.doctor_id AND vd.current_flag = 'Y'
    ) src ON tgt.procedure_id = src.procedure_id AND tgt.event_type = src.e_type
    WHEN MATCHED THEN UPDATE SET tgt.end_time = src.end_time
    WHEN NOT MATCHED THEN INSERT 
        (event_sk, event_type, admission_id, procedure_id, patient_sk, doctor_sk, scheduled_time, start_time, end_time, department)
    VALUES 
        (UUID_STRING(), src.e_type, src.admission_id, src.procedure_id, src.patient_sk, src.surgeon_sk, src.scheduled_time, src.start_time, src.end_time, src.department);

    -- C. BILLING Events
    MERGE INTO curated.fact_hospital_events tgt
    USING (
         SELECT 
            'BILLING' as e_type,
            b.bill_id,
            b.admission_id,
            p.patient_sk,
            b.total_amount,
            b.billing_time,
            va.department
         FROM validated.valid_billing b
         JOIN validated.valid_admissions va ON b.admission_id = va.admission_id
         JOIN curated.dim_patient p ON va.patient_id = p.patient_id AND p.current_flag = 'Y'
    ) src ON tgt.bill_id = src.bill_id AND tgt.event_type = src.e_type
    WHEN MATCHED THEN UPDATE SET tgt.total_amount = src.total_amount
    WHEN NOT MATCHED THEN INSERT 
        (event_sk, event_type, admission_id, bill_id, patient_sk, total_amount, billing_time, department)
    VALUES 
        (UUID_STRING(), src.e_type, src.admission_id, src.bill_id, src.patient_sk, src.total_amount, src.billing_time, src.department);

    RETURN 'Curated models populated successfully.';
END;
$$;


-- =========================================================================
-- 2. ANOMALY ENGINE & GOVERNANCE RULES
-- =========================================================================
CREATE OR REPLACE TABLE governance.anomaly_rule_hits (
    anomaly_id VARCHAR DEFAULT UUID_STRING(),
    rule_name VARCHAR,
    business_key VARCHAR,
    anomaly_desc VARCHAR,
    detected_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

--PROCEDURE FOR GOVERNENCE AND ANAMOLY RULE
CREATE OR REPLACE PROCEDURE governance.run_anomaly_engine()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- 1. Bed Conflict Rule
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    SELECT 'BED_CONFLICT', a1.admission_id, CONCAT('Overlaps with ', a2.admission_id, ' in ward ', a1.ward, ' bed ', a1.bed_no)
    FROM validated.valid_admissions a1
    JOIN validated.valid_admissions a2 
      ON a1.bed_no = a2.bed_no AND a1.ward = a2.ward AND a1.admission_id != a2.admission_id
    WHERE a1.admission_time <= COALESCE(a2.discharge_time, CURRENT_TIMESTAMP())
      AND COALESCE(a1.discharge_time, CURRENT_TIMESTAMP()) >= a2.admission_time;

    -- 2. Procedure Schedule Clash
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    SELECT 'SURGEON_CLASH', p1.procedure_id, CONCAT('Surgeon double booked: conflicts with ', p2.procedure_id)
    FROM validated.valid_procedures p1
    JOIN validated.valid_procedures p2
      ON p1.surgeon_id = p2.surgeon_id AND p1.procedure_id != p2.procedure_id
    WHERE p1.start_time <= p2.end_time AND p1.end_time >= p2.start_time;

    -- 3. Operation Theatre Overrun
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    SELECT 'OT_OVERRUN', procedure_id, CONCAT('Duration exceeded 4 hrs: ', DATEDIFF(minute, start_time, end_time), ' mins')
    FROM validated.valid_procedures
    WHERE DATEDIFF(minute, start_time, end_time) > 240;

    -- 4. Multiple active admissions
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    SELECT 'MULTIPLE_ACTIVE_ADMISSIONS', patient_id, 'Patient has multiple active distinct admissions simultaneously.'
    FROM validated.valid_admissions
    WHERE discharge_time IS NULL
    GROUP BY patient_id HAVING COUNT(*) > 1;

    -- 5. Billing amount unusually high vs department avg (> 3 std dev)
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    WITH DeptAvg AS (
        SELECT a.department, AVG(b.total_amount) as avg_amt, STDDEV(b.total_amount) as std_dev
        FROM validated.valid_billing b JOIN validated.valid_admissions a ON b.admission_id = a.admission_id GROUP BY a.department
    )
    SELECT 'BILL_OUTLIER', b.bill_id, CONCAT('Amount ', b.total_amount, ' exceeds dept avg ', d.avg_amt)
    FROM validated.valid_billing b
    JOIN validated.valid_admissions a ON b.admission_id = a.admission_id
    JOIN DeptAvg d ON a.department = d.department
    WHERE b.total_amount > (d.avg_amt + (3 * COALESCE(d.std_dev, 1)));

    -- 6. Billing same time for same patient
    INSERT INTO governance.anomaly_rule_hits (rule_name, business_key, anomaly_desc)
    SELECT 'DUPLICATE_BILL_TIME', patient_id, CONCAT('Billed multiple times at ', billing_time)
    FROM validated.valid_billing
    GROUP BY patient_id, billing_time HAVING COUNT(bill_id) > 1;

    RETURN 'Anomaly Engine run executed.';
END;
$$;