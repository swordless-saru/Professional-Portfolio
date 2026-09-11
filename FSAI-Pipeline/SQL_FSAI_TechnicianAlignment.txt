/*
OWNER: Facilities Analytics Team
PURPOSE: Technician alignment information oriented both horizontal and vertical for flexible development in Tableau
*/

select
  str.*
  , tech.* except(location_id, tech_type_group)
  , mgr.tech_manager

from `facilities-dw.facilities_prod.location_alignment` as str
  inner join ( -- store alignment unpivoted
    select
      location_id
      , tech_type
      , case
        when tech_type in ('GM', 'GM PM', 'Food Equipment') then 'GM'
        when tech_type in ('HVAC/R', 'HVAC/R PM') then 'HVAC/R'
        else tech_type
        end as tech_type_group
      , tech_name
      , tech_userid
      , tech_status
      , tech_phone
    from `facilities-dw.facilities_prod.location_alignment`
      unpivot exclude nulls (
        ( tech_name, tech_userid, tech_status, tech_phone )
        for tech_type
        in (
          (GM_Tech, GM_Tech_UID, GM_Tech_Status, GM_Tech_Phone) as 'GM'
          , (GM_PM_Tech, GM_PM_Tech_UID, GM_PM_Tech_Status, GM_PM_Tech_Phone) as 'GM PM'
          , (Food_Eqpt_Tech, Food_Eqpt_Tech_UID, Food_Eqpt_Tech_Status, Food_Eqpt_Tech_Phone) as 'Food Equipment'
          , (HVACR_Tech, HVACR_Tech_UID, HVACR_Tech_Status, HVACR_Tech_Phone) as 'HVAC/R'
          , (HVACR_PM_Tech, HVACR_PM_Tech_UID, HVACR_PM_Tech_Status, HVACR_PM_Tech_Phone) as 'HVAC/R PM'
          , (Landscape_Tech_One, Landscape_Tech_One_UID, Landscape_Tech_One_Status, Landscape_Tech_One_Phone) as 'Landscape'
          , (Landscape_Tech_Two, Landscape_Tech_Two_UID, Landscape_Tech_Two_Status, Landscape_Tech_Two_Phone) as 'Landscape'
          , (Landscape_Tech_Three, Landscape_Tech_Three_UID, Landscape_Tech_Three_Status, Landscape_Tech_Three_Phone) as 'Landscape'
          , (Landscape_Tech_Four, Landscape_Tech_Four_UID, Landscape_Tech_Four_Status, Landscape_Tech_Four_Phone) as 'Landscape'
        )
      )
    where location_type_code not in ('G')
  ) as tech
  on str.location_id = tech.location_id

  left join ( -- tech managers
    select
      location_id
      , tech_type_group
      , tech_manager
    from `facilities-dw.facilities_prod.location_alignment`
      unpivot exclude nulls (
        ( tech_manager )
        for tech_type_group
        in (
          ( GM_Mgr ) as 'GM'
          , (HVACR_Mgr) as 'HVAC/R'
          , (Landscape_Mgr) as 'Landscape'
        )
      )
  ) as mgr
  on tech.location_id = mgr.location_id
  and tech.tech_type_group = mgr.tech_type_group
