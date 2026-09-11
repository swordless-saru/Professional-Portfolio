/*
OWNER: Facilities Analytics Team
PURPOSE: Create monthly snapshot of Core Data...just in case
*/

declare tablename string;
declare expiration timestamp;
declare query string;

-- Add current date to table name
set tablename = concat(
  "`facilities-dw.facilities_backup.core_data_"
  , format_date('%Y%m%d', current_date('America/Chicago'))
  ,"`"
  )
;

-- Set snapshot to expire after 2 years
set expiration = date_add(current_timestamp(), interval 720 day);

-- Compile query
set query = concat(
  "create snapshot table"
  , tablename
  , "clone `facilities-dw.facilities_prod.core_data` options(expiration_timestamp = timestamp '"
  , expiration
  ,"')"
  )
;

execute immediate query;
