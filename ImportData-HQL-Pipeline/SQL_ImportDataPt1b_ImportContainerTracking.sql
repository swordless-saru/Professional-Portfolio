/*
OWNER: Imports Analytics Team
PURPOSE: Container tracking data extraction from Hive
FEATURES: Hive SQL, Container milestone tracking, Port operations
PLATFORM: Apache Hive / Hadoop
*/

-- Container Tracking Details
SELECT
    cnt.container_id,
    cnt.booking_po_nbr,
    cnt.vessel_name,
    cnt.voyage_nbr,
    cnt.origin_port_code,
    cnt.origin_port_name,
    cnt.dest_port_code,
    cnt.dest_port_name,
    cnt.container_size_code,
    cnt.container_type_code,
    
    -- Milestone timestamps
    cnt.empty_pickup_ts,
    cnt.gate_in_origin_ts,
    cnt.vessel_departure_ts,
    cnt.transship_arrival_ts,
    cnt.transship_departure_ts,
    cnt.vessel_arrival_ts,
    cnt.customs_release_ts,
    cnt.available_for_pickup_ts,
    cnt.gate_out_port_ts,
    cnt.facility_arrival_ts,
    cnt.empty_return_ts,
    
    -- Calculated metrics
    DATEDIFF(cnt.vessel_arrival_ts, cnt.vessel_departure_ts) AS ocean_transit_days,
    DATEDIFF(cnt.gate_out_port_ts, cnt.vessel_arrival_ts) AS port_dwell_days,
    DATEDIFF(cnt.facility_arrival_ts, cnt.gate_out_port_ts) AS drayage_days,
    
    -- Container status
    CASE
        WHEN cnt.empty_return_ts IS NOT NULL THEN 'COMPLETED'
        WHEN cnt.facility_arrival_ts IS NOT NULL THEN 'AT_FACILITY'
        WHEN cnt.gate_out_port_ts IS NOT NULL THEN 'IN_DRAYAGE'
        WHEN cnt.customs_release_ts IS NOT NULL THEN 'AWAITING_PICKUP'
        WHEN cnt.vessel_arrival_ts IS NOT NULL THEN 'AT_PORT'
        WHEN cnt.vessel_departure_ts IS NOT NULL THEN 'IN_TRANSIT'
        ELSE 'PENDING'
    END AS container_status,
    
    -- Volume metrics
    cnt.teu_count,
    cnt.total_cartons,
    cnt.total_units,
    cnt.total_cube_ft,
    cnt.total_weight_lbs

FROM imports_dw.container_tracking AS cnt

WHERE cnt.vessel_departure_ts >= DATE_SUB(CURRENT_DATE, 180)
    AND cnt.container_id IS NOT NULL

ORDER BY cnt.vessel_departure_ts DESC
