/*
PORTFOLIO SUMMARY: Carrier Load Pipeline
FULL VERSION: SQL_IBOB_LOAD.txt (7.7KB)

TECHNIQUES DEMONSTRATED:
  - Multi-source data consolidation (FULL OUTER JOIN)
  - COALESCE chains for source prioritization
  - MERGE statement for incremental loads
  - DELETE with EXISTS for cleanup
  - Staging table pattern

PLATFORM: Google BigQuery
*/

/* ========== STAGE 1: LEGACY TMS LOADS ========== */
-- Demonstrates: Timezone conversion, business filtering
CREATE OR REPLACE TABLE `staging.carrier_loads_legacy` AS (
  SELECT
    load.load_id,
    trip.trip_id,
    TRIM(load.trailer_id) AS trailer_id,
    load.origin_location_id,
    load.dest_location_id,
    DATE(trip.projected_ts) AS projected_date,
    -- Convert UTC to local timezone
    DATETIME(load.ready_ts_utc, tz.time_zone_name) AS ready_ts,
    CASE 
      WHEN trip.depart_odom_mile > 0 
      THEN DATETIME(trip.depart_ts_utc, tz.time_zone_name) 
    END AS depart_ts
  FROM `tms.loads` AS load
    INNER JOIN `tms.trips` AS trip ON load.trip_id = trip.trip_id
    LEFT JOIN timezone_lookup AS tz ON load.origin_location_id = tz.dc_nbr
  WHERE trip.projected_ts >= CURRENT_TIMESTAMP - INTERVAL 420 DAY
    AND UPPER(TRIM(load.trailer_id)) NOT LIKE '%DUMMY%'
    AND load.load_status NOT IN ('CANCEL')
);


/* ========== STAGE 2: MODERN TMS LOADS ========== */
-- Demonstrates: Different source system with schema mapping
CREATE OR REPLACE TABLE `staging.carrier_loads_modern` AS (
  SELECT
    CAST(plan.plan_id AS INT64) AS load_id,
    plan.parent_plan_id AS trip_id,
    TRIM(psn.trailer_id) AS trailer_id,
    plan.origin_location_id,
    plan.destination_location_id AS dest_location_id,
    DATE(TIMESTAMP(plan.min_due_ts), tz.time_zone_name) AS projected_date,
    DATETIME(TIMESTAMP(plan.trailer_avail_ts), tz.time_zone_name) AS ready_ts,
    DATETIME(TIMESTAMP(plan.actual_pickup_ts), tz.time_zone_name) AS depart_ts
  FROM `modern_tms.plan_data` AS plan
    LEFT JOIN `psn.load` AS psn ON CAST(plan.plan_id AS INT64) = psn.load_id
    LEFT JOIN timezone_lookup AS tz ON plan.destination_location_id = tz.store_nbr
  WHERE plan.status IN ('TENDER_ACCEPTED', 'IN_TRANSIT', 'DELIVERED')
);


/* ========== STAGE 3: COMBINE WITH COALESCE ========== */
-- Demonstrates: FULL OUTER JOIN with source prioritization
CREATE OR REPLACE TABLE `staging.carrier_loads_combined` AS (
  SELECT
    -- Prefer modern system, fall back to legacy
    COALESCE(modern.load_id, legacy.load_id) AS load_id,
    COALESCE(modern.trip_id, legacy.trip_id) AS trip_id,
    COALESCE(modern.trailer_id, legacy.trailer_id) AS trailer_id,
    COALESCE(modern.origin_location_id, legacy.origin_location_id) AS origin_location_id,
    COALESCE(modern.dest_location_id, legacy.dest_location_id) AS dest_location_id,
    COALESCE(modern.projected_date, legacy.projected_date) AS projected_date,
    COALESCE(modern.ready_ts, legacy.ready_ts) AS ready_ts,
    COALESCE(modern.depart_ts, legacy.depart_ts) AS depart_ts,
    -- Track data source
    CASE 
      WHEN modern.load_id IS NOT NULL AND legacy.load_id IS NOT NULL THEN 'BOTH'
      WHEN modern.load_id IS NOT NULL THEN 'MODERN'
      ELSE 'LEGACY'
    END AS data_source
  FROM `staging.carrier_loads_modern` AS modern
    FULL OUTER JOIN `staging.carrier_loads_legacy` AS legacy
      ON modern.origin_location_id = legacy.origin_location_id
      AND modern.dest_location_id = legacy.dest_location_id
      AND modern.trailer_id = legacy.trailer_id
      AND modern.projected_date = legacy.projected_date
);


/* ========== STAGE 4: MERGE INTO PRODUCTION ========== */
-- Demonstrates: MERGE for upsert pattern
MERGE INTO `prod.carrier_load_tracking` AS target
USING `staging.carrier_loads_combined` AS source
ON target.load_id = source.load_id
  AND target.projected_date = source.projected_date

WHEN MATCHED THEN
  UPDATE SET
    refresh_ts = CURRENT_TIMESTAMP,
    trip_id = source.trip_id,
    trailer_id = source.trailer_id,
    ready_ts = source.ready_ts,
    depart_ts = source.depart_ts,
    data_source = source.data_source

WHEN NOT MATCHED BY TARGET THEN
  INSERT (refresh_ts, load_id, trip_id, trailer_id, origin_location_id, 
          dest_location_id, projected_date, ready_ts, depart_ts, data_source)
  VALUES (CURRENT_TIMESTAMP, source.load_id, source.trip_id, source.trailer_id,
          source.origin_location_id, source.dest_location_id, source.projected_date,
          source.ready_ts, source.depart_ts, source.data_source);


/* ========== STAGE 5: CLEANUP CANCELLED LOADS ========== */
-- Demonstrates: DELETE with correlated subquery
DELETE `prod.carrier_load_tracking` AS target
WHERE EXISTS (
  SELECT 1
  FROM `staging.cancelled_loads` AS cancelled
  WHERE target.load_id = cancelled.load_id
    AND target.origin_location_id = cancelled.origin_location_id
    AND target.dest_location_id = cancelled.dest_location_id
);

-- Demonstrates: DELETE for orphaned records (projected date shifted)
DELETE `prod.carrier_load_tracking` AS target
WHERE EXISTS (
  SELECT 1
  FROM `prod.carrier_load_tracking` AS current_data
    INNER JOIN (
      SELECT load_id, MIN(projected_date) AS min_date, MAX(projected_date) AS max_date
      FROM `staging.carrier_loads_combined`
      GROUP BY load_id
    ) AS date_range
    ON current_data.load_id = date_range.load_id
    AND current_data.projected_date NOT BETWEEN date_range.min_date AND date_range.max_date
  WHERE target.load_id = current_data.load_id
    AND target.projected_date = current_data.projected_date
);
