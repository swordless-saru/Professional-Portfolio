/*
OWNER: Facilities Analytics Team
PURPOSE: Tracks workorder aging timeline to analyze resolution time patterns
FEATURES: Nested CTEs, Window functions (LAG/LEAD), Date calculations, Age bucketing
*/

WITH
workorder_base AS (
  SELECT
    wo.workorder_id,
    wo.location_id,
    wo.priority_code,
    wo.status_code,
    wo.created_ts,
    wo.completed_ts,
    wo.assigned_tech_id,
    EXTRACT(DATE FROM wo.created_ts) AS created_date,
    EXTRACT(DATE FROM wo.completed_ts) AS completed_date
  FROM `facilities-dw.facilities_prod.workorders` AS wo
  WHERE wo.created_ts >= CURRENT_TIMESTAMP - INTERVAL 365 DAY
    AND wo.status_code != 'CANCELLED'
),

daily_status_history AS (
  -- Track status changes over time with lag/lead for transition analysis
  SELECT
    workorder_id,
    status_code,
    status_ts,
    LAG(status_code, 1) OVER (PARTITION BY workorder_id ORDER BY status_ts) AS prev_status,
    LEAD(status_code, 1) OVER (PARTITION BY workorder_id ORDER BY status_ts) AS next_status,
    DATETIME_DIFF(
      LEAD(status_ts, 1) OVER (PARTITION BY workorder_id ORDER BY status_ts),
      status_ts,
      HOUR
    ) AS hours_in_status
  FROM `facilities-dw.facilities_prod.workorder_status_history`
),

aging_calculation AS (
  SELECT
    wb.*,
    DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, HOUR) AS total_hours,
    DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) AS total_days,
    CASE
      WHEN DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) <= 1 THEN '0-1 Days'
      WHEN DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) <= 3 THEN '2-3 Days'
      WHEN DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) <= 7 THEN '4-7 Days'
      WHEN DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) <= 14 THEN '8-14 Days'
      WHEN DATETIME_DIFF(COALESCE(wb.completed_ts, CURRENT_TIMESTAMP), wb.created_ts, DAY) <= 30 THEN '15-30 Days'
      ELSE '30+ Days'
    END AS age_bucket,
    SUM(dsh.hours_in_status) OVER (PARTITION BY wb.workorder_id) AS total_status_hours,
    COUNT(DISTINCT dsh.status_code) OVER (PARTITION BY wb.workorder_id) AS status_change_count
  FROM workorder_base AS wb
    LEFT JOIN daily_status_history AS dsh
      ON wb.workorder_id = dsh.workorder_id
),

weekly_summary AS (
  SELECT
    EXTRACT(WEEK FROM created_date) AS fiscal_week,
    EXTRACT(YEAR FROM created_date) AS fiscal_year,
    location_id,
    priority_code,
    age_bucket,
    COUNT(DISTINCT workorder_id) AS workorder_count,
    AVG(total_hours) AS avg_hours_to_complete,
    PERCENTILE_CONT(total_hours, 0.5) OVER (
      PARTITION BY location_id, priority_code
    ) AS median_hours,
    PERCENTILE_CONT(total_hours, 0.9) OVER (
      PARTITION BY location_id, priority_code
    ) AS p90_hours
  FROM aging_calculation
  GROUP BY 1, 2, 3, 4, 5
)

SELECT
  ws.*,
  -- Rolling 4-week average for trend analysis
  AVG(avg_hours_to_complete) OVER (
    PARTITION BY ws.location_id, ws.priority_code
    ORDER BY ws.fiscal_year, ws.fiscal_week
    ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
  ) AS rolling_4wk_avg_hours
FROM weekly_summary AS ws
ORDER BY fiscal_year DESC, fiscal_week DESC, location_id
