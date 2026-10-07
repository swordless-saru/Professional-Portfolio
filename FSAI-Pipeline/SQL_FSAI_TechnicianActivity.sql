/*
OWNER: Facilities Analytics Team
PURPOSE: Compile activity tracking and timestamps from all required platforms into a single table.
*/

-- set table stats query to string
declare qa string;
set qa = '''
-- PUBLISH UPDATED STATS --
insert into `facilities-dw.facilities_prod.table_qa` (project_name, dataset_name, table_name, last_update_dt, record_cnt, duplicate_records, run_dt)
select
  table_catalog as project_name
  , table_schema as dataset_name
  , table_name
  , datetime(creation_time) as last_update_dt
  , ( select count(activity_id) from `facilities-dw.facilities_prod.technician_activity` ) as record_cnt -- UPDATE TABLE NAME
  , ( -- count duplicate records
    select count(activity_id)
    from (
      select activity_id, count(activity_id) as cnt
      from `facilities-dw.facilities_prod.technician_activity` -- UPDATE TABLE NAME
      group by activity_id
      having cnt > 1
      )
  ) as duplicate_records
  , current_datetime() as run_dt
from `facilities-dw.facilities_prod.INFORMATION_SCHEMA.TABLES`
where table_name = 'technician_activity' -- UPDATE TABLE NAME
'''
;

begin

create or replace table `facilities-dw.facilities_prod.technician_activity`
cluster by tracking_nbr
as (

with
isp as ( -- ISP
  select
    isp.activity_id
    , ppl.provider_id as provider_id
    , ppl.provider_name as provider_name
    , isp.technician_user_id as user_id
    , coalesce(ppl.first_name, algn.first_name) as first_name
    , coalesce(ppl.last_name, algn.last_name) as last_name
    , coalesce(concat(ppl.first_name, ' ', ppl.last_name ), concat(algn.first_name, ' ', algn.last_name )) as full_name
    , activity_type as work_type
    , cast(isp.local_start_time as datetime) as check_in_datetime
    , cast(isp.local_end_time as datetime) as check_out_datetime
    , isp.tracking_no as tracking_nbr
    , 'isp' as src

  from `facilities-source.facilities_ods.technician_activity` as isp

    left join `facilities-dw.facilities_stage.service_people` as ppl -- connect on win
      on cast(isp.technician_win_no as string) = ppl.employee_id
      or isp.technician_user_id = ppl.user_id
    
    left join `facilities-dw.facilities_stage.tech_alignment` as algn
      on isp.technician_user_id = algn.user_id

  where isp.technician_user_id not in ('testtec')
)

, ftm as ( -- FTM
  select distinct
    ftm.record_id_nbr as activity_id
    , coalesce( ppl.provider_id, ftm.provider_id ) as provider_id
    , coalesce( ppl.provider_name, pro.provider_name ) as provider_name
    , cast( ppl.user_id as string) as user_id
    , coalesce( ppl.first_name, ftm.technician_first_name ) as first_name
    , coalesce( ppl.last_name, ftm.technician_last_name ) as last_name
    , upper( coalesce( concat( ppl.first_name, ' ', ppl.last_name ), concat( ftm.technician_first_name, ' ', ftm.technician_last_name ) ) ) as full_name
    , upper( ftm.work_type ) as work_type
    , cast( ftm.check_in_date_time as datetime ) as check_in_datetime
    , case -- check_out_datetime
      when ftm.check_out_date_time >= cast( current_date('America/Chicago') as datetime ) then null --nullify irrational dates
      else cast( ftm.check_out_date_time as datetime )
      end as check_out_datetime
    , ftm.tracking_number as tracking_nbr
    , 'ftm' as src

  from `facilities-source.facilities_ods.field_tech_mobile` as ftm

    inner join `facilities-dw.facilities_stage.service_people` as ppl
    on ftm.user_id = ppl.id

    left join `facilities-source.facilities_ods.service_providers` as pro
    on ftm.provider_id = pro.provider_id

  where
    ftm.tracking_number > 0
    and ftm.tracking_number is not null
    and extract( year from ftm.check_in_date_time ) < 9000
    and extract( year from ftm.check_out_date_time ) < 9000
)

, ivr as ( -- IVR
  select
    ci.ivr_id as activity_id
    , cast( null as int64 ) as provider_id
    , cast( null as string ) as provider_name
    , cast( null as string ) as user_id
    , cast( null as string ) as first_name
    , cast( null as string ) as last_name
    , cast( null as string ) as full_name
    , ivr.work_type
    , cast(ci.check_in_date_time as datetime) as check_in_datetime
    --, cast(co.check_out_date_time as datetime) as check_out_datetime
    , case
      when
        coalesce( cast(co.check_out_date_time as datetime), cast(co.last_check_out_date_time as datetime) ) < cast(ci.check_in_date_time as datetime)
        and cast(ci.check_in_date_time as datetime) < datetime_sub(current_datetime, interval 7 day) then null
      else coalesce( cast(co.check_out_date_time as datetime), cast(co.last_check_out_date_time as datetime) )
      end as check_out_datetime
    , ivr.tracking_number as tracking_nbr
    , 'ivr' as src

  from ( -- complete workorder list
    select distinct
      tracking_number
      , 'Repair' as work_type
    from `facilities-source.facilities_ods.workorder_ivr`
    ) as ivr

    left join ( -- check-in
      with ci as (select * from `facilities-source.facilities_ods.workorder_ivr` where ivr_action = 1)

      select
        ci.*
        , row_number() over (partition by ci.tracking_number order by ci.check_in_date_time) as idx
      from (
        select
          max( ci.ivr_id ) as ivr_id
          , ci.tracking_number
          , coalesce(ts.ivr_date_time, ci.ivr_date_time) as check_in_date_time

        from ci

          left join ( -- revert to XML and Web updated timestamps
            select distinct
              tracking_number
              , case
                when
                  tracking_number is not null
                  and lead(check_in_source) over (partition by tracking_number order by ivr_date_time) in ('xml','web')
                  and lead(cast(ivr_date_time as date)) over (partition by tracking_number order by ivr_date_time) = cast(ivr_date_time as date) -- same date, different time
                  then lead(ivr_date_time) over (partition by tracking_number order by ivr_date_time)
                else ivr_date_time
                end as ivr_date_time
            from ci
          ) as ts
          on ci.tracking_number = ts.tracking_number
          and ci.ivr_date_time = ts.ivr_date_time

        where
          ci.tracking_number = ts.tracking_number
          or ci.tracking_number is null
        
        group by
          ci.tracking_number
          , coalesce(ts.ivr_date_time, ci.ivr_date_time)
      ) as ci
    ) as ci
    on ivr.tracking_number = ci.tracking_number

    left join ( -- check-out
      with co as (select * from `facilities-source.facilities_ods.workorder_ivr` where ivr_action = 2)

      select
        co.tracking_number
        , row_number() over (partition by co.tracking_number order by co.ivr_date_time) as idx
        , coalesce(ts.ivr_date_time, co.ivr_date_time) as check_out_date_time
        , max(coalesce(ts.ivr_date_time, co.ivr_date_time)) over (partition by co.tracking_number) as last_check_out_date_time

      from co

        left join ( -- revert to XML and Web updated timestamps
          select distinct
            tracking_number
            , case
              when
                tracking_number is not null
                and lead(check_in_source) over (partition by tracking_number order by ivr_date_time) in ('xml','web')
                and lead(cast(ivr_date_time as date)) over (partition by tracking_number order by ivr_date_time) = cast(ivr_date_time as date) -- same date, different time
                then lead(ivr_date_time) over (partition by tracking_number order by ivr_date_time)
              else ivr_date_time
              end as ivr_date_time
          from co
        ) as ts
        on co.tracking_number = ts.tracking_number
        and co.ivr_date_time = ts.ivr_date_time

      where
        co.tracking_number = ts.tracking_number
        or co.tracking_number is null
    ) as co
    on ci.tracking_number = co.tracking_number
    and ci.idx = co.idx
)

, chng as ( -- WO Change History
  select
    tracking_number
    , change_time
    , old_value
    , new_value
  from `facilities-source.facilities_ods.workorder_change_history`
  where upper( change_event ) = 'PROVIDER'
)

, pro as ( -- Activity Provider
  select
    ts.tracking_number
    , ts.provider_id
    , pro.provider_name
    , ts.start_datetime
    , ts.end_datetime

  from ( -- find start and end timestamps for each provider
    -- first provider, using call date as the starting timestamp
    select
      chng.tracking_number
      , cast( chng.old_value as int64 ) as provider_id
      , wo.call_date as start_datetime
      , datetime_sub( cast(chng.change_time as datetime), interval 1 second ) as end_datetime
    from chng
      inner join (
        select tracking_number, min(change_time) as min_change_time from chng group by tracking_number
      ) as orig
      on chng.tracking_number = orig.tracking_number
      and chng.change_time = orig.min_change_time
      
      inner join `facilities-source.facilities_ods.workorder` as wo
      on chng.tracking_number = wo.tracking_nbr

    union all

    -- remaining providers
    select
      chng.tracking_number
      , cast( chng.new_value as int64 ) as provider_id
      , cast( chng.change_time as datetime ) as start_datetime
      , datetime_sub( cast( lead(chng.change_time) over (partition by chng.tracking_number order by chng.tracking_number, chng.change_time) as datetime ), interval 1 second ) as end_datetime
    from chng
    ) as ts

    left join `facilities-source.facilities_ods.service_providers` as pro
    on ts.provider_id = pro.provider_id
)

, ppl as ( -- Tech Info
  select
    upper( replace( user_id, ' ', '' ) ) as user_id
    , upper(trim(first_name)) as first_name
    , upper(trim(last_name)) as last_name
    , upper(concat(trim(first_name), ' ', trim(last_name))) as full_name
    , org_role
    , insource_start_date
    , insource_exit_date
    , home_location
  from `facilities-dw.facilities_stage.tech_alignment`
  where trim(user_id) != ''
)

select
  ts.activity_id
  , coalesce( pro.provider_id, ts.provider_id ) as provider_id
  , upper( coalesce( pro.provider_name, ts.provider_name ) ) as provider_name
  , upper( ts.user_id ) as user_id
  , coalesce( ppl.first_name, upper( ts.first_name ) ) as first_name
  , coalesce( ppl.last_name, upper( ts.last_name ) ) as last_name
  , coalesce( ppl.full_name, upper( ts.full_name ) ) as full_name
  , ppl.org_role
  , ppl.insource_start_date
  , ppl.insource_exit_date
  , ppl.home_location
  , upper( ts.work_type ) as work_type
  , ts.check_in_datetime
  , coalesce( ts.check_out_datetime, wo.completion_date ) as check_out_datetime
  , case -- calculate duration
    when ts.check_in_datetime is null or ts.check_out_datetime is null then null
    when ts.check_out_datetime < ts.check_in_datetime then null
    when datetime_diff(ts.check_out_datetime, ts.check_in_datetime, minute) > 1440 then null
    else datetime_diff(ts.check_out_datetime, ts.check_in_datetime, minute)
    end as activity_minutes
  , if(ts.tracking_nbr = 0, null, ts.tracking_nbr) as tracking_nbr
  , ts.src

from ( -- union all timestamp data
  -- ISP
  select isp.* from isp -- use all that is available from ISP since it is the latest application

  union all

  -- FTM
  select ftm.*
  from ftm
    left join (select distinct tracking_nbr from isp) as dup -- exclude ISP workorders from FTM data
    on ftm.tracking_nbr = dup.tracking_nbr
  where dup.tracking_nbr is null

  union all

  -- IVR
  select ivr.*
  from ivr
    left join ( -- exclude ISP and FTM workorders from IVR data, unless check-in occurs after final ISP/FTM check-out
      select tracking_nbr, max(check_out_datetime) as max_check_out_datetime
      from (
        select distinct tracking_nbr, check_out_datetime from isp
        union all
        select distinct tracking_nbr, check_out_datetime from ftm
        ) as ts
      group by tracking_nbr
      ) as dup
    on ivr.tracking_nbr = dup.tracking_nbr
  where
    dup.tracking_nbr is null
    or ivr.check_in_datetime > dup.max_check_out_datetime
) as ts

  -- exclude tracking numbers not found in the primary workorders table
  left join (select distinct tracking_nbr, location_id, completion_date from `facilities-dw.facilities_prod.workorders`) as wo
  on ts.tracking_nbr = wo.tracking_nbr

  left join pro
  on ts.tracking_nbr = pro.tracking_number
  and cast( check_in_datetime as datetime ) >= pro.start_datetime
  and (
    cast( check_in_datetime as datetime ) < pro.end_datetime
    or pro.end_datetime is null
  )

  left join ppl
  on ts.user_id = ppl.user_id

where
  (
  wo.tracking_nbr is not null
  or ts.tracking_nbr is null
  or ts.tracking_nbr = 0
  )

)
;
execute immediate qa; --publish table stats

exception when error then --if update fails, still publish table stats

execute immediate qa; --publish table stats
end
;
