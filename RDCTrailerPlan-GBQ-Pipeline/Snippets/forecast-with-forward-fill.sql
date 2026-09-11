CREATE OR REPLACE TABLE `analytics.delivery_forecast_current` AS (
  SELECT
    LOCATION_ID,
    CALENDAR_DATE,
    -- Forward-fill from previous same-day-of-week when data is missing
    COALESCE(
      DAILY_CAP,
      LAST_VALUE(DAILY_CAP IGNORE NULLS) OVER (
        PARTITION BY LOCATION_ID, EXTRACT(DAYOFWEEK FROM CALENDAR_DATE)
        ORDER BY CALENDAR_DATE ASC
        ROWS UNBOUNDED PRECEDING
      )
    ) AS DAILY_PLAN,
    -- Must-ship: days adjacent to zero-plan days
    CASE
      WHEN DAILY_PLAN = 0 THEN 'N'
      WHEN MIN(DAILY_PLAN) OVER (
        PARTITION BY LOCATION_ID
        ORDER BY CALENDAR_DATE
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
      ) = 0 THEN 'Y'
      ELSE 'N'
    END AS MUST_SHIP_FLAG
  FROM forecast_data
);
