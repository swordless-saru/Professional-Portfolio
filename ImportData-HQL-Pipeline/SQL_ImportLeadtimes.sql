/*
OWNER: Imports Analytics Team  
PURPOSE: Import lead time calculation with 3-year trend analysis
FEATURES: Hive SQL, Percentile calculations, Year-over-year comparison, Window functions
PLATFORM: Apache Hive / Hadoop
*/

-- Lead Time Analysis with Historical Trends
WITH
shipment_milestones AS (
    SELECT
        shp.booking_po_nbr,
        shp.item_nbr,
        shp.origin_country_code,
        shp.origin_port_code,
        shp.dest_port_code,
        shp.dest_facility_nbr,
        
        -- Key milestone dates
        shp.order_date,
        shp.ship_date,
        shp.port_arrival_date,
        shp.customs_clear_date,
        shp.facility_arrival_date,
        shp.available_date,
        
        -- Lead time segments (in days)
        DATEDIFF(shp.ship_date, shp.order_date) AS order_to_ship_days,
        DATEDIFF(shp.port_arrival_date, shp.ship_date) AS ocean_transit_days,
        DATEDIFF(shp.customs_clear_date, shp.port_arrival_date) AS port_dwell_days,
        DATEDIFF(shp.facility_arrival_date, shp.customs_clear_date) AS inland_transit_days,
        DATEDIFF(shp.available_date, shp.order_date) AS total_lead_time_days,
        
        -- Calendar dimensions
        YEAR(shp.ship_date) AS ship_year,
        MONTH(shp.ship_date) AS ship_month,
        WEEKOFYEAR(shp.ship_date) AS ship_week
        
    FROM imports_dw.shipment_detail AS shp
    
    WHERE shp.ship_date >= DATE_SUB(CURRENT_DATE, 365 * 3)  -- 3 years
        AND shp.available_date IS NOT NULL
        AND shp.order_date IS NOT NULL
),

lane_metrics AS (
    -- Calculate percentiles and averages by trade lane
    SELECT
        origin_country_code,
        origin_port_code,
        dest_port_code,
        dest_facility_nbr,
        ship_year,
        ship_month,
        
        COUNT(*) AS shipment_count,
        
        -- Lead time statistics
        AVG(total_lead_time_days) AS avg_lead_time,
        MIN(total_lead_time_days) AS min_lead_time,
        MAX(total_lead_time_days) AS max_lead_time,
        PERCENTILE(total_lead_time_days, 0.50) AS p50_lead_time,
        PERCENTILE(total_lead_time_days, 0.75) AS p75_lead_time,
        PERCENTILE(total_lead_time_days, 0.90) AS p90_lead_time,
        PERCENTILE(total_lead_time_days, 0.95) AS p95_lead_time,
        
        -- Segment breakdowns
        AVG(order_to_ship_days) AS avg_order_to_ship,
        AVG(ocean_transit_days) AS avg_ocean_transit,
        AVG(port_dwell_days) AS avg_port_dwell,
        AVG(inland_transit_days) AS avg_inland_transit,
        
        -- Variability metrics
        STDDEV(total_lead_time_days) AS stddev_lead_time
        
    FROM shipment_milestones
    GROUP BY
        origin_country_code,
        origin_port_code,
        dest_port_code,
        dest_facility_nbr,
        ship_year,
        ship_month
    HAVING COUNT(*) >= 10  -- Minimum sample size
),

year_over_year AS (
    SELECT
        lm.*,
        
        -- YoY comparison
        LAG(avg_lead_time, 12) OVER (
            PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
            ORDER BY ship_year, ship_month
        ) AS avg_lead_time_ly,
        
        LAG(p90_lead_time, 12) OVER (
            PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
            ORDER BY ship_year, ship_month
        ) AS p90_lead_time_ly,
        
        -- Rolling 3-month average
        AVG(avg_lead_time) OVER (
            PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
            ORDER BY ship_year, ship_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS rolling_3mo_avg
        
    FROM lane_metrics AS lm
)

SELECT
    yoy.*,
    
    -- YoY change calculations
    yoy.avg_lead_time - yoy.avg_lead_time_ly AS avg_lead_time_yoy_change,
    ROUND((yoy.avg_lead_time - yoy.avg_lead_time_ly) / NULLIF(yoy.avg_lead_time_ly, 0) * 100, 1) AS avg_lead_time_yoy_pct,
    
    -- Trend classification
    CASE
        WHEN yoy.avg_lead_time > yoy.avg_lead_time_ly * 1.1 THEN 'INCREASING'
        WHEN yoy.avg_lead_time < yoy.avg_lead_time_ly * 0.9 THEN 'DECREASING'
        ELSE 'STABLE'
    END AS lead_time_trend,
    
    -- Performance classification
    CASE
        WHEN yoy.p90_lead_time <= 45 THEN 'EXCELLENT'
        WHEN yoy.p90_lead_time <= 60 THEN 'GOOD'
        WHEN yoy.p90_lead_time <= 75 THEN 'FAIR'
        ELSE 'NEEDS_IMPROVEMENT'
    END AS lane_performance

FROM year_over_year AS yoy

ORDER BY 
    origin_country_code,
    dest_facility_nbr,
    ship_year DESC,
    ship_month DESC
