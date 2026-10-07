/*
PORTFOLIO SUMMARY: Teradata Integrated Planning Patterns
FULL VERSIONS: 
  - SQL_IntegratedPlanning_InboundOpenPOs.txt (5.6KB)
  - SQL_IntegratedPlanning_InboundReceivedPOs.txt (5.0KB)
  - SQL_IntegratedPlanning_OutboundShippedPOs.txt (6.4KB)

TECHNIQUES DEMONSTRATED:
  - Teradata SQL syntax and functions
  - Window functions with PARTITION BY
  - Complex CASE logic for receipt date offsetting
  - UNION for multi-source consolidation
  - Nested subqueries with aggregation

PLATFORM: Teradata
*/

/* ========== PATTERN 1: WINDOW AGGREGATION FOR RATIO CALCULATION ========== */
-- Demonstrates: Running totals for proportional distribution
SELECT
  booking_po_nbr,
  distribution_po_nbr,
  item_nbr,
  vnpk_ord_qty,
  
  -- Total across booking PO for ratio calculation
  SUM(vnpk_ord_qty) OVER (
    PARTITION BY booking_po_nbr, item_nbr
  ) AS tot_vnpk_ord_qty,
  
  SUM(vnpk_rcv_qty) OVER (
    PARTITION BY booking_po_nbr, item_nbr
  ) AS tot_vnpk_rcv_qty,
  
  -- First receipt date across all distribution orders
  MIN(idc_date_actual - COALESCE(dc_lane.lead_time, 0)) OVER (
    PARTITION BY booking_po_nbr, item_nbr
  ) AS min_idc_date

FROM order_data;


/* ========== PATTERN 2: RECEIPT DATE OFFSET LOGIC ========== */
-- Demonstrates: Complex business rules for date adjustment
SELECT
  *,
  -- Flag orders requiring receipt date offset
  CASE
    WHEN ecommerce_ind = 'Y' THEN 'Y'
    WHEN dest_location_id = 7092 THEN 'Y'  -- Special facility
    WHEN po_type IN (40, 42) AND channel_method = 'FLOW' THEN 'Y'
    ELSE 'N'
  END AS offset_required_flag,
  
  -- Adjusted receipt date based on business rules
  CASE
    -- Recent orders with low receipt rate: use first/expected date
    WHEN offset_required_flag = 'Y' 
      AND COALESCE(min_idc_date, idc_date_planned) >= CURRENT_DATE - 21 
      AND (tot_vnpk_rcv_qty / NULLIF(tot_vnpk_ord_qty, 0)) < 0.5 
    THEN COALESCE(min_idc_date, idc_date_planned)
    
    -- Other offset orders: apply lead time adjustment
    WHEN offset_required_flag = 'Y' 
    THEN idc_date_actual - COALESCE(dc_lane.lead_time, 0)
    
    -- Standard: use actual receipt date
    ELSE idc_date_actual
  END AS idc_date_adjusted,
  
  -- Fill in volume for unreceived orders within lookback window
  CASE
    WHEN offset_required_flag = 'Y' 
      AND unit_rcv_qty = 0 
      AND COALESCE(min_idc_date, idc_date_planned) BETWEEN CURRENT_DATE - 21 AND CURRENT_DATE - 1 
    THEN unit_ord_qty
    ELSE unit_rcv_qty
  END AS unit_rcv_qty_adjusted

FROM order_data_with_totals;


/* ========== PATTERN 3: MULTI-SOURCE UNION WITH ROUTING LOGIC ========== */
-- Demonstrates: UNION combining different shipment types with facility mapping
SELECT
  'STORAGE_TO_RDC' AS part_no,
  ship_week_no,
  -- Route storage facility to associated flow facility for certain PO types
  CASE
    WHEN po_type IN (43, 45, 46) AND ship_from_dc = 6060 THEN 7089
    WHEN po_type IN (43, 45, 46) AND ship_from_dc = 6061 THEN 7086
    WHEN po_type IN (43, 45, 46) AND ship_from_dc = 6088 THEN 7093
    WHEN po_type IN (43, 45, 46) AND ship_from_dc = 7042 THEN 7085
    ELSE ship_from_dc
  END AS from_location_no,
  ship_to_location AS to_location_no,
  item_nbr,
  -- Variable weight handling
  COALESCE(SUM(CASE
    WHEN variable_wt_qty > 1 
    THEN ROUND(each_ship_qty / variable_wt_qty + 0.4999) * vnpk_qty
    ELSE ROUND(CAST(each_ship_qty AS DECIMAL(18,2)))
  END), 0.0) AS total_ship_units,
  SUM(whpk_ship_qty * whpk_cube_qty) AS total_cube

FROM dc_invoice inv
  INNER JOIN dc_invoice_line line 
    ON inv.invoice_nbr = line.invoice_nbr
  INNER JOIN item_dim item 
    ON line.item_nbr = item.mds_fam_id
  INNER JOIN dc_lane 
    ON inv.ship_from_dc = dc_lane.from_location_nbr
WHERE invoice_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE
GROUP BY 1, 2, 3, 4, 5

UNION ALL

SELECT
  'TRANSFER_PO' AS part_no,
  cal.year_wk_nbr AS ship_week_no,
  po.xfer_whse_nbr AS from_location_no,  -- Transfer origin
  inv.ship_from_dc AS to_location_no,     -- Receives at RDC
  line.item_nbr,
  COALESCE(SUM(CASE
    WHEN line.variable_wt_qty > 1 
    THEN ROUND(line.each_ship_qty / line.variable_wt_qty + 0.4999) * item.vnpk_qty
    ELSE ROUND(CAST(line.each_ship_qty AS DECIMAL(18,2)))
  END), 0.0) AS total_ship_units,
  SUM(line.whpk_ship_qty * item.whpk_cube_qty) AS total_cube

FROM dc_invoice inv
  INNER JOIN dc_invoice_line line 
    ON inv.invoice_nbr = line.invoice_nbr
  INNER JOIN purchase_order po 
    ON line.po_nbr = po.po_nbr
    AND po.po_type = 23  -- Transfer type
  INNER JOIN item_dim item 
    ON line.item_nbr = item.mds_fam_id
  INNER JOIN calendar_dim cal 
    ON po.order_date = cal.calendar_date
WHERE po.xfer_whse_nbr IN (6060, 6061, 6088, 7042, 7067, 7078)
GROUP BY 1, 2, 3, 4, 5;


/* ========== PATTERN 4: DATE RANGE SUBQUERY ========== */
-- Demonstrates: Dynamic date filtering using correlated subquery
SELECT *
FROM receipt_data
WHERE idc_date_actual >= (
    -- Start of fiscal week, 65 weeks ago
    SELECT calendar_date 
    FROM util.rec_start_date
  )
  AND idc_date_actual <= (
    -- End of last complete week
    SELECT MAX(calendar_date)
    FROM calendar_dim c1
      INNER JOIN (
        SELECT year_wk_nbr
        FROM calendar_dim
        WHERE calendar_date = CURRENT_DATE - 3
      ) c2
      ON c1.year_wk_nbr = c2.year_wk_nbr
  );
