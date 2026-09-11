SELECT
  origin_country_code,
  origin_port_code,
  dest_port_code,
  dest_facility_nbr,
  ship_year,
  ship_month,
  COUNT(*) AS shipment_count,

  -- Central tendency and spread
  AVG(total_lead_time_days)    AS avg_lead_time,
  STDDEV(total_lead_time_days) AS stddev_lead_time,

  -- Percentile distribution
  PERCENTILE(total_lead_time_days, 0.50) AS p50_lead_time,
  PERCENTILE(total_lead_time_days, 0.75) AS p75_lead_time,
  PERCENTILE(total_lead_time_days, 0.90) AS p90_lead_time,
  PERCENTILE(total_lead_time_days, 0.95) AS p95_lead_time,

  -- Segment averages
  AVG(ocean_transit_days) AS avg_ocean_transit,
  AVG(port_dwell_days)    AS avg_port_dwell

FROM shipment_milestones
GROUP BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr, ship_year, ship_month
HAVING COUNT(*) >= 10; -- Exclude lanes with insufficient data
