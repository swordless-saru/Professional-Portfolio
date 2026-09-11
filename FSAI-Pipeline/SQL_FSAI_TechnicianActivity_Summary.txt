/*
PORTFOLIO SUMMARY: Technician Activity Analysis
FULL VERSION: SQL_FSAI_TechnicianActivity.txt (12.9KB)

TECHNIQUES DEMONSTRATED:
  - Multiple CTEs with distinct purposes
  - Window functions (ROW_NUMBER, LAG)
  - UNION ALL for combining data sources
  - Dynamic date handling
  - Complex CASE logic for status determination

PLATFORM: Google BigQuery
*/

/* ========== CTE 1: SERVICE PROVIDER DATA ========== */
-- Demonstrates: Date range filtering, status aggregation
WITH 
isp_activity AS (
  SELECT
    tech.tech_id,
    tech.tech_name,
    act.location_id,
    act.activity_date,
    act.activity_type,
    act.workorder_id,
    act.duration_minutes,
    -- Running total of activities per tech per day
    SUM(duration_minutes) OVER (
      PARTITION BY tech.tech_id, act.activity_date 
      ORDER BY act.start_time
    ) AS cumulative_minutes,
    -- Activity sequence for the day
    ROW_NUMBER() OVER (
      PARTITION BY tech.tech_id, act.activity_date 
      ORDER BY act.start_time
    ) AS activity_seq
  FROM `facilities.technician_activity` AS act
    INNER JOIN `facilities.technicians` AS tech
      ON act.tech_id = tech.tech_id
  WHERE act.activity_date >= CURRENT_DATE - 90
    AND tech.employment_type = 'INTERNAL'
),

/* ========== CTE 2: FIELD TECHNICIAN DATA ========== */
-- Demonstrates: Different source with same output schema
ftm_activity AS (
  SELECT
    tech_id,
    tech_name,
    location_id,
    checkin_date AS activity_date,
    'SITE_VISIT' AS activity_type,
    workorder_id,
    DATETIME_DIFF(checkout_time, checkin_time, MINUTE) AS duration_minutes,
    SUM(DATETIME_DIFF(checkout_time, checkin_time, MINUTE)) OVER (
      PARTITION BY tech_id, checkin_date 
      ORDER BY checkin_time
    ) AS cumulative_minutes,
    ROW_NUMBER() OVER (
      PARTITION BY tech_id, checkin_date 
      ORDER BY checkin_time
    ) AS activity_seq
  FROM `facilities.mobile_checkins`
  WHERE checkin_date >= CURRENT_DATE - 90
),

/* ========== CTE 3: IVR DATA ========== */
-- Demonstrates: Third data source integration
ivr_activity AS (
  SELECT
    tech_id,
    tech_name,
    location_id,
    call_date AS activity_date,
    'PHONE_SUPPORT' AS activity_type,
    workorder_id,
    call_duration_minutes AS duration_minutes,
    SUM(call_duration_minutes) OVER (
      PARTITION BY tech_id, call_date 
      ORDER BY call_time
    ) AS cumulative_minutes,
    ROW_NUMBER() OVER (
      PARTITION BY tech_id, call_date 
      ORDER BY call_time
    ) AS activity_seq
  FROM `facilities.ivr_calls`
  WHERE call_date >= CURRENT_DATE - 90
)

/* ========== FINAL: UNION + ENRICHMENT ========== */
-- Demonstrates: UNION ALL with consistent schema, window analytics
SELECT
  combined.*,
  loc.region_name,
  loc.district_name,
  -- Daily productivity metrics
  MAX(cumulative_minutes) OVER (
    PARTITION BY tech_id, activity_date
  ) AS total_daily_minutes,
  MAX(activity_seq) OVER (
    PARTITION BY tech_id, activity_date
  ) AS total_daily_activities,
  -- Compare to previous day
  LAG(cumulative_minutes, 1) OVER (
    PARTITION BY tech_id 
    ORDER BY activity_date, activity_seq
  ) AS prev_cumulative,
  -- Productivity classification
  CASE
    WHEN MAX(cumulative_minutes) OVER (PARTITION BY tech_id, activity_date) >= 480 
      THEN 'FULL_DAY'
    WHEN MAX(cumulative_minutes) OVER (PARTITION BY tech_id, activity_date) >= 240 
      THEN 'HALF_DAY'
    WHEN MAX(cumulative_minutes) OVER (PARTITION BY tech_id, activity_date) > 0 
      THEN 'PARTIAL'
    ELSE 'NO_ACTIVITY'
  END AS productivity_status

FROM (
  SELECT * FROM isp_activity
  UNION ALL
  SELECT * FROM ftm_activity
  UNION ALL
  SELECT * FROM ivr_activity
) AS combined

  INNER JOIN `facilities.locations` AS loc
    ON combined.location_id = loc.location_id

ORDER BY tech_id, activity_date, activity_seq;
