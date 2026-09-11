/*
OWNER: Supply Chain Analytics Team
PURPOSE: Consolidated load tracking with multi-source UNION and incremental MERGE pattern
FEATURES: Multi-source UNION, MERGE statement, Complex timestamp handling, Source coalescing
*/

-- Step 1: Collect legacy transportation loads
CREATE OR REPLACE TABLE `flow-analytics-dev.staging.carrier_loads_legacy` AS (
  SELECT
    load.load_id,
    trip.trip_id,
    TRIM(load.trailer_id) AS trailer_id,
    load.origin_location_id,
    load.dest_location_id,
    load.load_status_code,
    trip.trip_status_code,
    DATE(trip.projected_ts) AS projected_date,
    EXTRACT(HOUR FROM trip.projected_ts) AS delivery_slot,
    DATETIME(load.ready_ts_utc, tz.time_zone_name) AS ready_ts,
    trip.projected_ts,
    CASE 
      WHEN trip.depart_odom_mile > 0 
      THEN DATETIME(trip.depart_ts_utc, tz.time_zone_name) 
    END AS depart_ts
  FROM `supply-chain-dw.transportation.trip_load_xref` AS tl
    INNER JOIN `supply-chain-dw.transportation.loads` AS load
      ON tl.load_id = load.load_id
    INNER JOIN `supply-chain-dw.transportation.trips` AS trip
      ON tl.trip_id = trip.trip_id
    INNER JOIN `enterprise-dw.location_dims.dc_dim` AS dc
      ON load.origin_location_id = dc.dc_nbr
      AND dc.country_code = 'US'
      AND dc.current_ind = 'Y'
    LEFT JOIN (
      SELECT
        dc_nbr,
        GET_TIMEZONE_NAME(time_zone_code) AS time_zone_name
      FROM `enterprise-dw.location_dims.dc_dim`
      WHERE country_code = 'US' AND current_ind = 'Y'
    ) AS tz
      ON dc.dc_nbr = tz.dc_nbr
    INNER JOIN `enterprise-dw.location_dims.store_dim` AS sd
      ON load.dest_location_id = sd.store_nbr
      AND sd.country_code = 'US'
      AND sd.state_prov_code NOT IN ('AK', 'HI', 'PR')  -- Continental US only
  WHERE trip.projected_ts IS NOT NULL
    AND DATE(trip.projected_ts) >= CURRENT_DATE - 420
    AND load.trailer_id IS NOT NULL
    AND UPPER(TRIM(load.trailer_id)) NOT LIKE '%DUMMY%'
    AND TRIM(trip.trip_type_code) IN ('STORE', 'CONSOLIDATED')
    AND TRIM(load.freight_category_code) = 'STR'
    AND TRIM(load.load_status_code) NOT IN ('CANCEL')
    AND dc.dc_type_desc = 'Regional'
);

-- Step 2: Collect modern TMS loads
CREATE OR REPLACE TABLE `flow-analytics-dev.staging.carrier_loads_modern` AS (
  SELECT DISTINCT
    CAST(plan.plan_id AS INT64) AS load_id,
    plan.parent_plan_id AS trip_id,
    TRIM(psn.trailer_id) AS trailer_id,
    plan.origin_location_id,
    plan.destination_location_id AS dest_location_id,
    plan.status AS load_status_code,
    CAST(NULL AS STRING) AS trip_status_code,
    DATE(TIMESTAMP(plan.min_due_ts), tz.time_zone_name) AS projected_date,
    EXTRACT(HOUR FROM DATETIME(TIMESTAMP(plan.min_due_ts), tz.time_zone_name)) AS delivery_slot,
    DATETIME(TIMESTAMP(plan.trailer_avail_ts), tz.time_zone_name) AS ready_ts,
    DATETIME(TIMESTAMP(plan.min_due_ts), tz.time_zone_name) AS projected_ts,
    DATETIME(TIMESTAMP(plan.actual_pickup_ts), tz.time_zone_name) AS depart_ts
  FROM `tms-prod.tms_us.plan_data` AS plan
    INNER JOIN `enterprise-dw.location_dims.dc_dim` AS dc
      ON plan.origin_location_id = dc.dc_nbr
      AND dc.country_code = 'US'
      AND dc.current_ind = 'Y'
    LEFT JOIN `supply-chain-dw.store_ops.psn_load` AS psn
      ON CAST(plan.plan_id AS INT64) = psn.load_id
    LEFT JOIN (
      SELECT
        store_nbr,
        GET_TIMEZONE_NAME(time_zone_code) AS time_zone_name
      FROM `enterprise-dw.location_dims.store_dim`
      WHERE country_code = 'US' AND current_ind = 'Y'
    ) AS tz
      ON plan.destination_location_id = tz.store_nbr
  WHERE plan.status IN ('TENDER_ACCEPTED', 'IN_TRANSIT', 'DELIVERED')
    AND plan.origin_location_type = 'DC'
    AND plan.destination_location_type = 'STORE'
    AND dc.dc_type_desc = 'Regional'
    AND plan.category = 'STR'
);

-- Step 3: Combine sources and enrich with volume data
CREATE OR REPLACE TABLE `flow-analytics-dev.staging.carrier_loads_combined` AS (
  WITH
  combined_loads AS (
    SELECT
      COALESCE(modern.load_id, legacy.load_id) AS load_id,
      COALESCE(modern.trip_id, legacy.trip_id) AS trip_id,
      COALESCE(modern.trailer_id, legacy.trailer_id) AS trailer_id,
      COALESCE(modern.origin_location_id, legacy.origin_location_id) AS origin_location_id,
      COALESCE(modern.dest_location_id, legacy.dest_location_id) AS dest_location_id,
      COALESCE(modern.load_status_code, legacy.load_status_code) AS load_status_code,
      COALESCE(modern.trip_status_code, legacy.trip_status_code) AS trip_status_code,
      COALESCE(modern.projected_date, legacy.projected_date) AS projected_date,
      COALESCE(modern.delivery_slot, legacy.delivery_slot) AS delivery_slot,
      COALESCE(modern.ready_ts, legacy.ready_ts) AS ready_ts,
      COALESCE(modern.projected_ts, legacy.projected_ts) AS projected_ts,
      COALESCE(modern.depart_ts, legacy.depart_ts) AS depart_ts
    FROM `flow-analytics-dev.staging.carrier_loads_modern` AS modern
      FULL OUTER JOIN `flow-analytics-dev.staging.carrier_loads_legacy` AS legacy
        ON modern.origin_location_id = legacy.origin_location_id
        AND modern.dest_location_id = legacy.dest_location_id
        AND modern.trailer_id = legacy.trailer_id
        AND modern.projected_date = legacy.projected_date
  ),
  
  invoice_volume AS (
    SELECT
      load_id,
      SUM(case_qty) AS total_cases,
      SUM(cube_qty) AS total_cube,
      SUM(weight_qty) AS total_weight
    FROM `supply-chain-dw.dc_operations.invoice_summary`
    WHERE invoice_date >= CURRENT_DATE - 365
    GROUP BY load_id
  )

  SELECT
    cl.*,
    iv.total_cases,
    iv.total_cube,
    iv.total_weight,
    LEAST(iv.total_cube / 2600, 1) AS trailer_util_pct
  FROM combined_loads AS cl
    LEFT JOIN invoice_volume AS iv
      ON cl.load_id = iv.load_id
);

-- Step 4: MERGE into production table (incremental update pattern)
MERGE INTO `flow-analytics-prod.flow_planning.carrier_load_tracking` AS target
USING `flow-analytics-dev.staging.carrier_loads_combined` AS source
ON target.load_id = source.load_id
  AND target.projected_date = source.projected_date

WHEN MATCHED THEN
  UPDATE SET
    refresh_ts = CURRENT_TIMESTAMP,
    trip_id = source.trip_id,
    trailer_id = source.trailer_id,
    load_status_code = source.load_status_code,
    trip_status_code = source.trip_status_code,
    delivery_slot = source.delivery_slot,
    ready_ts = source.ready_ts,
    projected_ts = source.projected_ts,
    depart_ts = source.depart_ts,
    total_cases = source.total_cases,
    total_cube = source.total_cube,
    total_weight = source.total_weight,
    trailer_util_pct = source.trailer_util_pct

WHEN NOT MATCHED BY TARGET THEN
  INSERT (
    refresh_ts, load_id, trip_id, trailer_id, origin_location_id, dest_location_id,
    load_status_code, trip_status_code, projected_date, delivery_slot,
    ready_ts, projected_ts, depart_ts, total_cases, total_cube, total_weight, trailer_util_pct
  )
  VALUES (
    CURRENT_TIMESTAMP, source.load_id, source.trip_id, source.trailer_id,
    source.origin_location_id, source.dest_location_id, source.load_status_code,
    source.trip_status_code, source.projected_date, source.delivery_slot,
    source.ready_ts, source.projected_ts, source.depart_ts,
    source.total_cases, source.total_cube, source.total_weight, source.trailer_util_pct
  );

-- Step 5: Delete cancelled loads
DELETE `flow-analytics-prod.flow_planning.carrier_load_tracking` AS target
WHERE EXISTS (
  SELECT 1
  FROM `flow-analytics-dev.staging.cancelled_loads` AS cancelled
  WHERE target.load_id = cancelled.load_id
    AND target.origin_location_id = cancelled.origin_location_id
    AND target.dest_location_id = cancelled.dest_location_id
);
