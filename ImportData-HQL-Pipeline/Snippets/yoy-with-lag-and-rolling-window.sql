SELECT
  lm.*,

  -- Same month, prior year - offset by 12 periods
  LAG(avg_lead_time, 12) OVER (
    PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
    ORDER BY ship_year, ship_month
  ) AS avg_lead_time_ly,

  LAG(p90_lead_time, 12) OVER (
    PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
    ORDER BY ship_year, ship_month
  ) AS p90_lead_time_ly,

  -- Rolling 3-month average to reduce month-to-month noise
  AVG(avg_lead_time) OVER (
    PARTITION BY origin_country_code, origin_port_code, dest_port_code, dest_facility_nbr
    ORDER BY ship_year, ship_month
    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
  ) AS rolling_3mo_avg

FROM lane_metrics AS lm;
