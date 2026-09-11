/*
PORTFOLIO SUMMARY: RDC Trailer Plan Pipeline
FULL VERSION: SQL_RDCTrailerPlan.txt (33KB)

TECHNIQUES DEMONSTRATED:
  - Multi-stage DDL pipeline (CREATE OR REPLACE TABLE)
  - MERGE statement for incremental upserts
  - DELETE with correlated subqueries
  - Custom TEMP FUNCTION for business logic
  - Complex CTEs with 5+ levels of nesting
  - Window functions (LAG, LEAD, LAST_VALUE IGNORE NULLS)
  - Multi-source data coalescing
  - Dashboard rollup generation

PLATFORM: Google BigQuery
*/

/* ========== STAGE 1: FORECAST WITH FORWARD-FILL ========== */
-- Demonstrates: LAST_VALUE IGNORE NULLS for gap-filling missing data
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


/* ========== STAGE 2: INTELLIGENT TIMESTAMP SELECTION ========== */
-- Demonstrates: Multi-source coalescing with business logic
SELECT
  LOAD_ID,
  TRAILER_ID,
  -- Select best ready timestamp based on data quality rules
  DATETIME(
    CASE
      WHEN ABS(DATETIME_DIFF(EST_READY_TS, CURRENT_READY_TS, SECOND)) <= 2 
      THEN GREATEST(CURRENT_READY_TS, FIRST_CHANGE_TS)  -- Timestamp wasn't updated
      ELSE CURRENT_READY_TS
    END,
    TIME_ZONE_NAME
  ) AS READY_TS,
  
  -- Coalesce departure from multiple sources (priority order)
  DATETIME_TRUNC(COALESCE(
    DATETIME(load_status.DEPART_TS_UTC, tz.TIME_ZONE_NAME),      -- Source 1: Most reliable
    DATETIME(trip_movement.ACTUAL_DEPART_TS_UTC, tz.TIME_ZONE_NAME),  -- Source 2
    trip.DEPART_TS                                                     -- Source 3: Fallback
  ), SECOND) AS BEGIN_TRIP_TS
FROM load_data;


/* ========== STAGE 3: VOLUME CALCULATION WITH PACK LOGIC ========== */
-- Demonstrates: Complex CASE aggregation with dimensional lookups
SELECT
  INVOICE_NBR,
  -- Non-breakpack cases (casepacks + pallets + oversized breakpacks)
  SUM(CASE
    WHEN pack.PACK_TYPE IN ('CASEPACK', 'FULL_PALLET', 'MIXED_PALLET') 
      THEN WHPK_SHIP_QTY
    WHEN LABEL_TYPE = 'FDSC' 
      AND item.LENGTH + item.WIDTH + item.HEIGHT > 52 
      THEN WHPK_SHIP_QTY  -- Oversized breakpack treated as casepack
    ELSE 0
  END) AS NON_BRPK_CASE_QTY,
  
  -- Cube calculation with fallback formula
  SUM(LEAST(
    COALESCE(
      WHPK_SHIP_QTY * item.WHPK_CUBE,
      (WHPK_SHIP_QTY * item.WHPK_QTY / item.VNPK_QTY) * item.VNPK_CUBE
    ),
    (WHPK_SHIP_QTY * item.WHPK_QTY / item.VNPK_QTY) * item.VNPK_CUBE
  )) AS CUBE_QTY
FROM invoice_line
  JOIN item_dim ON invoice_line.ITEM_NBR = item_dim.MDS_FAM_ID
  LEFT JOIN pick_code_class ON LABEL_TYPE = PICK_TYPE_CODE
GROUP BY INVOICE_NBR;


/* ========== STAGE 4: MERGE FOR INCREMENTAL UPDATES ========== */
-- Demonstrates: MERGE pattern for upsert operations
MERGE INTO `prod.trailer_plan` AS TARGET
USING `staging.trailer_plan_staged` AS SOURCE
ON TARGET.LOAD_ID = SOURCE.LOAD_ID 
  AND TARGET.RUN_DATE = SOURCE.RUN_DATE

WHEN MATCHED THEN
  UPDATE SET
    REFRESH_TIME = SOURCE.REFRESH_TIME,
    TRAILER_ID = SOURCE.TRAILER_ID,
    READY_TS = SOURCE.READY_TS,
    CUBE_QTY = SOURCE.CUBE_QTY,
    CARRY_OVER_FLAG = SOURCE.CARRY_OVER_FLAG,
    -- ... additional fields
    CAPPED_FLAG = SOURCE.CAPPED_FLAG

WHEN NOT MATCHED BY TARGET THEN
  INSERT (REFRESH_TIME, RUN_DATE, LOAD_ID, TRAILER_ID, READY_TS, CUBE_QTY, CARRY_OVER_FLAG, CAPPED_FLAG)
  VALUES (SOURCE.REFRESH_TIME, SOURCE.RUN_DATE, SOURCE.LOAD_ID, SOURCE.TRAILER_ID, SOURCE.READY_TS, SOURCE.CUBE_QTY, SOURCE.CARRY_OVER_FLAG, SOURCE.CAPPED_FLAG);


/* ========== STAGE 5: DELETE WITH CORRELATED SUBQUERY ========== */
-- Demonstrates: DELETE using EXISTS for referential cleanup
DELETE `prod.trailer_plan` AS TGT
WHERE EXISTS (
  SELECT 1 
  FROM `staging.cancelled_loads` AS DEL
  WHERE TGT.LOAD_ID = DEL.LOAD_ID
    AND TGT.ORIG_LOC_ID = DEL.ORIG_LOC_ID
    AND TGT.DEST_LOC_ID = DEL.DEST_LOC_ID
);


/* ========== STAGE 6: TEMP FUNCTION FOR ATTRIBUTION ========== */
-- Demonstrates: Encapsulating complex business logic in reusable function
CREATE TEMP FUNCTION COMPLIANCE_ATTRIBUTION(
  DAILY_PLAN INT64,
  DAILY_ACTUAL INT64,
  CARRY_OVER_COUNT INT64,
  MUST_SHIP_FLAG STRING,
  TRAILERS_AVAILABLE INT64,
  LEVEL INT64  -- 1=Category, 2=Area, 3=Reason, 4=Detail
)
RETURNS STRING AS (
  CASE
    -- COMPLIANT
    WHEN DAILY_ACTUAL = DAILY_PLAN THEN 
      IF(LEVEL <= 2, 'COMPLIANT', 'Trailer count matches plan')
    
    -- UNDER: Trailer was available but not sent
    WHEN DAILY_ACTUAL < DAILY_PLAN AND TRAILERS_AVAILABLE > 0 THEN
      CASE LEVEL
        WHEN 1 THEN 'UNDER'
        WHEN 2 THEN 'TRANSPORTATION'
        WHEN 3 THEN 'Guaranteed Delivery Missed'
        ELSE 'Trailer was available but not dispatched'
      END
    
    -- UNDER: Must ship with no trailer
    WHEN DAILY_ACTUAL < DAILY_PLAN AND MUST_SHIP_FLAG = 'Y' THEN
      CASE LEVEL
        WHEN 1 THEN 'UNDER'
        WHEN 2 THEN 'DC_HANDOFF'
        WHEN 3 THEN 'Must Ship Missed'
        ELSE 'No trailer available on must-ship date'
      END
    
    -- OVER: Delivery on non-delivery day
    WHEN DAILY_ACTUAL > DAILY_PLAN AND DAILY_PLAN = 0 THEN
      CASE LEVEL
        WHEN 1 THEN 'OVER'
        WHEN 2 THEN 'TRANSPORTATION'
        WHEN 3 THEN 'Unplanned Delivery'
        ELSE 'Trailer sent on non-delivery date'
      END
    
    -- OVER: Could have carried over
    WHEN DAILY_ACTUAL > DAILY_PLAN AND CARRY_OVER_COUNT = 0 THEN
      CASE LEVEL
        WHEN 1 THEN 'OVER'
        WHEN 2 THEN 'TRANSPORTATION'
        WHEN 3 THEN 'Zero Carry Over'
        ELSE 'Trailer sent when it could have been held'
      END
  END
);

-- Usage in query:
SELECT
  STORE_NBR,
  PROJECTED_DATE,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 1) AS COMPLIANCE_L1,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 2) AS COMPLIANCE_L2,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 3) AS COMPLIANCE_L3
FROM daily_summary;


/* ========== STAGE 7: DASHBOARD ROLLUPS ========== */
-- Demonstrates: Multi-level aggregation with window functions
SELECT
  BD.*,
  -- Daily actual count
  COUNT(DISTINCT LOAD_ID) OVER (
    PARTITION BY STORE_NBR, PROJECTED_DATE
  ) AS DAILY_ACTUAL,
  
  -- Weekly rollup
  WKLY.WEEKLY_PLAN,
  WKLY.WEEKLY_FORECAST,
  WKLY.WEEKLY_ACTUAL,
  
  -- Compliance classification
  CASE
    WHEN PROJECTED_DATE > CURRENT_DATE THEN NULL
    WHEN DAILY_ACTUAL > DAILY_PLAN THEN 'OVER'
    WHEN DAILY_ACTUAL < DAILY_PLAN THEN 'UNDER'
    ELSE 'COMPLIANT'
  END AS PLAN_COMPLIANCE_FLAG,
  
  -- Trailer utilization bucketing
  CASE
    WHEN CUBE_QTY > 4050 THEN 'INVALID'
    WHEN TRLR_UTIL_PCT <= 0.25 THEN '0-25%'
    WHEN TRLR_UTIL_PCT <= 0.50 THEN '25-50%'
    WHEN TRLR_UTIL_PCT <= 0.75 THEN '50-75%'
    WHEN TRLR_UTIL_PCT <= 0.85 THEN '75-85%'
    ELSE 'FULL (85%+)'
  END AS UTILIZATION_BUCKET

FROM base_data BD
  LEFT JOIN (
    SELECT STORE_NBR, YEAR_WK_NBR,
      SUM(DAILY_PLAN) AS WEEKLY_PLAN,
      SUM(FORECAST) AS WEEKLY_FORECAST,
      COUNT(DISTINCT LOAD_ID) AS WEEKLY_ACTUAL
    FROM daily_rollup
    GROUP BY STORE_NBR, YEAR_WK_NBR
  ) AS WKLY
  ON BD.STORE_NBR = WKLY.STORE_NBR 
  AND BD.YEAR_WK_NBR = WKLY.YEAR_WK_NBR;
