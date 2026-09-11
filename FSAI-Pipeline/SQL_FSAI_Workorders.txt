/*
OWNER: Facilities Analytics Team
PURPOSE: Comprehensive workorder extraction with technician alignment and location hierarchy
FEATURES: Multiple JOINs, COALESCE chains, Business logic encoding, Dynamic date ranges
*/

SELECT
  -- Location Information
  loc.location_id,
  loc.location_name,
  loc.location_type_code,
  loc.region_id,
  loc.region_name,
  loc.district_id,
  loc.district_name,
  loc.market_id,
  loc.market_name,
  loc.state_code,
  loc.city_name,
  loc.latitude,
  loc.longitude,
  loc.open_date,
  loc.square_footage,
  
  -- Workorder Details
  wo.workorder_id,
  wo.workorder_type_code,
  wo.workorder_type_desc,
  wo.priority_code,
  CASE wo.priority_code
    WHEN 'E' THEN 'Emergency'
    WHEN 'U' THEN 'Urgent'
    WHEN 'R' THEN 'Routine'
    WHEN 'P' THEN 'Planned'
    ELSE 'Other'
  END AS priority_desc,
  wo.status_code,
  wo.status_desc,
  wo.created_ts,
  wo.scheduled_ts,
  wo.started_ts,
  wo.completed_ts,
  wo.closed_ts,
  
  -- Age Calculations
  DATETIME_DIFF(COALESCE(wo.completed_ts, CURRENT_TIMESTAMP), wo.created_ts, HOUR) AS hours_open,
  DATETIME_DIFF(COALESCE(wo.started_ts, wo.completed_ts), wo.scheduled_ts, HOUR) AS hours_to_start,
  DATETIME_DIFF(wo.completed_ts, wo.started_ts, HOUR) AS hours_to_complete,
  
  -- Technician Information
  tech.tech_id,
  tech.tech_name,
  tech.tech_type,
  CASE tech.tech_type
    WHEN 'GM' THEN 'General Maintenance'
    WHEN 'HVAC' THEN 'HVAC/Refrigeration'
    WHEN 'FOOD' THEN 'Food Equipment'
    WHEN 'LAND' THEN 'Landscaping'
    ELSE 'Specialist'
  END AS tech_type_desc,
  tech.employment_status,
  mgr.manager_name AS tech_manager,
  
  -- Equipment Details
  equip.equipment_id,
  equip.equipment_type,
  equip.equipment_category,
  equip.manufacturer,
  equip.model_number,
  equip.install_date,
  DATETIME_DIFF(CURRENT_DATE, equip.install_date, YEAR) AS equipment_age_years,
  
  -- Service Provider (for outsourced work)
  COALESCE(vendor.vendor_name, 'Internal') AS service_provider,
  vendor.vendor_type,
  
  -- Cost Information
  COALESCE(wo.parts_cost, 0) AS parts_cost,
  COALESCE(wo.labor_cost, 0) AS labor_cost,
  COALESCE(wo.parts_cost, 0) + COALESCE(wo.labor_cost, 0) AS total_cost,
  
  -- SLA Compliance
  CASE
    WHEN wo.priority_code = 'E' AND DATETIME_DIFF(wo.started_ts, wo.created_ts, HOUR) <= 4 THEN 'MET'
    WHEN wo.priority_code = 'U' AND DATETIME_DIFF(wo.started_ts, wo.created_ts, HOUR) <= 24 THEN 'MET'
    WHEN wo.priority_code = 'R' AND DATETIME_DIFF(wo.started_ts, wo.created_ts, HOUR) <= 72 THEN 'MET'
    WHEN wo.completed_ts IS NULL THEN 'IN_PROGRESS'
    ELSE 'MISSED'
  END AS sla_status,
  
  -- Calendar Alignment
  cal.fiscal_year,
  cal.fiscal_quarter,
  cal.fiscal_month,
  cal.fiscal_week,
  cal.day_of_week_name

FROM `facilities-dw.facilities_prod.workorders` AS wo

  INNER JOIN `facilities-dw.facilities_prod.locations` AS loc
    ON wo.location_id = loc.location_id
    AND loc.current_ind = 'Y'

  LEFT JOIN `facilities-dw.facilities_prod.technician_assignments` AS ta
    ON wo.location_id = ta.location_id
    AND wo.workorder_type_code = ta.service_type_code
    AND wo.created_ts BETWEEN ta.effective_start_date AND COALESCE(ta.effective_end_date, '9999-12-31')

  LEFT JOIN `facilities-dw.facilities_prod.technicians` AS tech
    ON ta.tech_id = tech.tech_id

  LEFT JOIN `facilities-dw.facilities_prod.technician_managers` AS mgr
    ON tech.manager_id = mgr.manager_id

  LEFT JOIN `facilities-dw.facilities_prod.equipment` AS equip
    ON wo.equipment_id = equip.equipment_id

  LEFT JOIN `facilities-dw.facilities_prod.vendors` AS vendor
    ON wo.vendor_id = vendor.vendor_id

  INNER JOIN `core-dw.calendar_dim` AS cal
    ON EXTRACT(DATE FROM wo.created_ts) = cal.calendar_date

WHERE wo.created_ts >= CURRENT_TIMESTAMP - INTERVAL 180 DAY
  AND loc.location_type_code NOT IN ('CLOSED', 'TEMP')
  
ORDER BY wo.created_ts DESC
