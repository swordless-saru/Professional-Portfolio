CREATE TEMP FUNCTION COMPLIANCE_ATTRIBUTION(
  DAILY_PLAN INT64,
  DAILY_ACTUAL INT64,
  CARRY_OVER_COUNT INT64,
  MUST_SHIP_FLAG STRING,
  TRAILERS_AVAILABLE INT64,
  LEVEL INT64 -- 1=Category, 2=Area, 3=Reason, 4=Detail
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

-- Usage:
SELECT
  STORE_NBR,
  PROJECTED_DATE,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 1) AS COMPLIANCE_L1,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 2) AS COMPLIANCE_L2,
  COMPLIANCE_ATTRIBUTION(DAILY_PLAN, DAILY_ACTUAL, CARRY_OVER_COUNT, MUST_SHIP_FLAG, AVAILABLE, 3) AS COMPLIANCE_L3
FROM daily_summary;