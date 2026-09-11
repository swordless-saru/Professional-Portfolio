SELECT
  LOAD_ID,
  TRAILER_ID,
  -- Select best ready timestamp based on data quality rules
  DATETIME(
    CASE
      WHEN ABS(DATETIME_DIFF(EST_READY_TS, CURRENT_READY_TS, SECOND)) <= 2
      THEN GREATEST(CURRENT_READY_TS, FIRST_CHANGE_TS)  -- Timestamp wasn't updated
      ELSE CURRENT_READY_TS
    END,
    TIME_ZONE_NAME
  ) AS READY_TS,

  -- Coalesce departure from multiple sources (priority order)
  DATETIME_TRUNC(COALESCE(
    DATETIME(load_status.DEPART_TS_UTC, tz.TIME_ZONE_NAME),      -- Source 1: Most reliable
    DATETIME(trip_movement.ACTUAL_DEPART_TS_UTC, tz.TIME_ZONE_NAME),  -- Source 2
    trip.DEPART_TS                                              -- Source 3: Fallback
  ), SECOND) AS BEGIN_TRIP_TS
FROM load_data;
