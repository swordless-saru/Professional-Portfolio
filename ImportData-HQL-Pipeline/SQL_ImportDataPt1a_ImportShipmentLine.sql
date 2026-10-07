/*
OWNER: Imports Analytics Team
PURPOSE: Extract import shipment line details from Hive data lake
FEATURES: Hive SQL, Multi-level subqueries, Date range partitioning, Complex JOINs
PLATFORM: Apache Hive / Hadoop
*/

-- Import Shipment Line Details
SELECT
    shp.booking_po_nbr,
    shp.distribution_po_nbr,
    shp.order_date,
    shp.po_type_code,
    shp.event_code,
    shp.event_desc,
    shp.item_nbr,
    shp.dept_nbr,
    shp.channel_method_desc,
    shp.planned_dest_location_nbr,
    shp.planned_dest_location_type,
    shp.actual_dest_location_nbr,
    shp.actual_dest_location_type,
    shp.cancel_date AS ship_date_planned,
    shp.cancel_date AS ship_date_expected,
    MIN(shp.actual_ship_date) AS ship_date_actual,
    shp.orig_port_arrival_date,
    shp.port_arrival_date AS port_date_planned,
    COALESCE(shp.eta_date, shp.port_arrival_date) AS port_date_expected,
    CASE
        WHEN shp.actual_arrival_date < CURRENT_DATE THEN shp.actual_arrival_date
        ELSE NULL
    END AS port_date_actual,
    MIN(shp.est_idc_receipt_date) AS idc_date_expected,
    shp.po_mabd AS rdc_date_planned,
    MIN(shp.est_rdc_receipt_date) AS rdc_date_expected,
    shp.in_store_date AS store_date_planned,
    MIN(shp.est_in_store_date) AS store_date_expected,
    shp.po_close_date AS close_date,
    SUM(SUM(shp.order_qty)) OVER (PARTITION BY shp.booking_po_nbr, shp.item_nbr) AS total_vnpk_ord_qty,
    SUM(shp.order_qty) AS vnpk_ord_qty

FROM imports_dw.import_shipment_historic AS shp

WHERE shp.actual_dest_location_nbr IN (
    6060, 6061, 6088, 7042, 7067, 7078, 7085, 7086, 7089, 7092, 7093, 7094, 8695, 9631
)
    AND shp.order_qty > 0
    AND shp.order_qty IS NOT NULL

GROUP BY
    shp.booking_po_nbr,
    shp.distribution_po_nbr,
    shp.order_date,
    shp.po_type_code,
    shp.event_code,
    shp.event_desc,
    shp.item_nbr,
    shp.dept_nbr,
    shp.channel_method_desc,
    shp.planned_dest_location_nbr,
    shp.planned_dest_location_type,
    shp.actual_dest_location_nbr,
    shp.actual_dest_location_type,
    shp.cancel_date,
    shp.orig_port_arrival_date,
    shp.port_arrival_date,
    shp.eta_date,
    shp.actual_arrival_date,
    shp.po_mabd,
    shp.in_store_date,
    shp.po_close_date
