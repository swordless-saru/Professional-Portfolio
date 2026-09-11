/*
OWNER: Supply Chain Analytics Team
PURPOSE: Carrier load aggregation with invoice and item detail joining
FEATURES: Multi-level CTEs, Window functions, Aggregation with HAVING, Volume calculations
*/

WITH
invoice_items AS (
  -- Aggregate item-level volume from invoice lines
  SELECT
    inv.invoice_nbr,
    inv.invoice_date,
    inv.load_id,
    inv.ship_from_dc_nbr AS origin_dc,
    inv.ship_to_location_nbr AS dest_location,
    SUM(line.whpk_ship_qty) AS total_whpk_qty,
    SUM(line.each_ship_qty) AS total_unit_qty,
    SUM(
      CASE
        WHEN line.variable_wt_qty > 1 
        THEN ROUND(line.each_ship_qty / line.variable_wt_qty + 0.4999)
        ELSE line.each_ship_qty / NULLIF(item.vnpk_qty, 0)
      END
    ) AS total_vnpk_qty,
    SUM(line.whpk_ship_qty * item.whpk_cube_qty) AS total_cube,
    SUM(line.whpk_ship_qty * item.whpk_weight_qty) AS total_weight,
    SUM(line.ext_cost_amt) AS total_cost,
    SUM(line.ext_retail_amt) AS total_retail
  FROM `supply-chain-dw.dc_operations.invoice_header` AS inv
    INNER JOIN `supply-chain-dw.dc_operations.invoice_line` AS line
      ON inv.invoice_nbr = line.invoice_nbr
      AND inv.invoice_date = line.invoice_date
    INNER JOIN `enterprise-dw.product_dims.item_dim` AS item
      ON line.item_nbr = item.mds_fam_id
      AND item.current_ind = 'Y'
  WHERE inv.invoice_date >= CURRENT_DATE - 90
    AND line.outs_code NOT IN ('O', 'R', 'M', 'F')
  GROUP BY 1, 2, 3, 4, 5
),

load_summary AS (
  -- Build load-level summary with carrier and status info
  SELECT
    ld.load_id,
    ld.trip_id,
    ld.trailer_id,
    ld.origin_location_id,
    ld.dest_location_id,
    ld.load_status_code,
    ld.freight_category_code,
    ld.ready_ts,
    ld.projected_delivery_ts,
    tr.actual_depart_ts,
    tr.actual_arrival_ts,
    ii.total_whpk_qty,
    ii.total_unit_qty,
    ii.total_vnpk_qty,
    ii.total_cube,
    ii.total_weight,
    ii.total_cost,
    ii.total_retail,
    -- Utilization calculation (assuming 2600 cubic feet capacity)
    LEAST(ii.total_cube / 2600, 1) AS trailer_util_pct,
    -- Transit time calculation
    DATETIME_DIFF(tr.actual_arrival_ts, tr.actual_depart_ts, HOUR) AS transit_hours
  FROM `supply-chain-dw.transportation.loads` AS ld
    LEFT JOIN `supply-chain-dw.transportation.trip_movement` AS tr
      ON ld.load_id = tr.load_id
      AND ld.trip_id = tr.trip_id
    LEFT JOIN invoice_items AS ii
      ON ld.load_id = ii.load_id
  WHERE ld.load_status_code NOT IN ('CANCEL', 'REJECT')
    AND ld.ready_ts >= CURRENT_TIMESTAMP - INTERVAL 90 DAY
),

dc_lane_metrics AS (
  -- Calculate lane-level metrics for performance comparison
  SELECT
    origin_location_id,
    dest_location_id,
    COUNT(DISTINCT load_id) AS load_count,
    AVG(trailer_util_pct) AS avg_utilization,
    PERCENTILE_CONT(trailer_util_pct, 0.5) OVER (
      PARTITION BY origin_location_id
    ) AS median_utilization,
    AVG(transit_hours) AS avg_transit_hours,
    SUM(total_cube) AS total_lane_cube,
    SUM(total_weight) AS total_lane_weight
  FROM load_summary
  WHERE actual_arrival_ts IS NOT NULL
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT load_id) >= 5  -- Minimum volume threshold
)

SELECT
  ls.*,
  dlm.load_count AS lane_load_count,
  dlm.avg_utilization AS lane_avg_utilization,
  dlm.avg_transit_hours AS lane_avg_transit,
  -- Performance vs lane average
  CASE
    WHEN ls.trailer_util_pct > dlm.avg_utilization THEN 'ABOVE_AVG'
    WHEN ls.trailer_util_pct < dlm.avg_utilization * 0.8 THEN 'BELOW_AVG'
    ELSE 'AT_AVG'
  END AS utilization_performance,
  -- Calendar dimensions
  cal.fiscal_year_week_nbr,
  cal.fiscal_year_nbr,
  cal.fiscal_week_nbr,
  cal.day_of_week_name
FROM load_summary AS ls
  LEFT JOIN dc_lane_metrics AS dlm
    ON ls.origin_location_id = dlm.origin_location_id
    AND ls.dest_location_id = dlm.dest_location_id
  INNER JOIN `core-dw.calendar_dim` AS cal
    ON EXTRACT(DATE FROM ls.ready_ts) = cal.calendar_date
ORDER BY ls.ready_ts DESC
