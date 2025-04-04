SET joined_subquery_requires_alias = 0;
SET max_threads = 1;
-- It affects number of read rows and max_rows_to_read.
SET max_bytes_before_external_sort = 0;
SET max_bytes_ratio_before_external_sort = 0;
SET max_bytes_before_external_group_by = 0;
SET max_bytes_ratio_before_external_group_by = 0;

-- incremental streaming usecase
-- that has sense only if data filling order has guarantees of chronological order

DROP TABLE IF EXISTS target_table;
DROP TABLE IF EXISTS logins;
DROP TABLE IF EXISTS mv_logins2target;
DROP TABLE IF EXISTS checkouts;
DROP TABLE IF EXISTS mv_checkouts2target;

-- that is the final table, which is filled incrementally from 2 different sources

CREATE TABLE target_table Engine=SummingMergeTree() ORDER BY id
SETTINGS index_granularity=128, index_granularity_bytes = '10Mi'
AS
   SELECT
     number as id,
     maxState( toDateTime(0, 'UTC') ) as latest_login_time,
     maxState( toDateTime(0, 'UTC') ) as latest_checkout_time,
     minState( toUInt64(-1) ) as fastest_session,
     maxState( toUInt64(0) ) as biggest_inactivity_period
FROM numbers(50000)
GROUP BY id
SETTINGS max_insert_threads=1;

-- source table #1

CREATE TABLE logins (
    id UInt64,
    ts DateTime('UTC')
) Engine=MergeTree ORDER BY id;


-- and mv with something like feedback from target table

CREATE MATERIALIZED VIEW mv_logins2target TO target_table
AS
   SELECT
     id,
     maxState( ts ) as latest_login_time,
     maxState( toDateTime(0, 'UTC') ) as latest_checkout_time,
     minState( toUInt64(-1) ) as fastest_session,
     if(max(current_latest_checkout_time) > 0, maxState(toUInt64(ts - current_latest_checkout_time)), maxState( toUInt64(0) ) ) as biggest_inactivity_period
   FROM logins
   LEFT JOIN (
       SELECT
          id,
          maxMerge(latest_checkout_time) as current_latest_checkout_time

        -- normal MV sees only the incoming block, but we need something like feedback here
        -- so we do join with target table, the most important thing here is that
        -- we extract from target table only row affected by that MV, referencing src table
        -- it second time
        FROM target_table
        WHERE id IN (SELECT id FROM logins)
        GROUP BY id
    ) USING (id)
   GROUP BY id;


-- the same for second pipeline
CREATE TABLE checkouts (
    id UInt64,
    ts DateTime('UTC')
) Engine=MergeTree ORDER BY id;

CREATE MATERIALIZED VIEW mv_checkouts2target TO target_table
AS
   SELECT
     id,
     maxState( toDateTime(0, 'UTC') ) as latest_login_time,
     maxState( ts ) as latest_checkout_time,
     if(max(current_latest_login_time) > 0, minState( toUInt64(ts - current_latest_login_time)), minState( toUInt64(-1) ) ) as fastest_session,
     maxState( toUInt64(0) ) as biggest_inactivity_period
   FROM checkouts
   LEFT JOIN (SELECT id, maxMerge(latest_login_time) as current_latest_login_time FROM target_table WHERE id IN (SELECT id FROM checkouts) GROUP BY id) USING (id)
   GROUP BY id;

-- This query has effect only for existing tables, so it must be located after CREATE.
SYSTEM STOP MERGES target_table;
SYSTEM STOP MERGES checkouts;
SYSTEM STOP MERGES logins;

-- feed with some initial values
INSERT INTO logins SELECT number as id,    '2000-01-01 08:00:00' from numbers(50000);
INSERT INTO checkouts SELECT number as id, '2000-01-01 10:00:00' from numbers(50000);

-- ensure that we don't read whole target table during join
-- by this time we should have 3 parts for target_table because of prev inserts
-- and we plan to make two more inserts. With index_granularity=128 and max id=1000
-- we expect to read not more than:
--      1000 rows read from numbers(1000) in the INSERT itself
--      1000 rows in the `IN (SELECT id FROM table)` in the mat views
--      (1000/128) marks per part * (3 + 2) parts * 128 granularity = 5120 rows
--      Total: 7120
set max_rows_to_read = 7120;

INSERT INTO logins    SELECT number as id, '2000-01-01 11:00:00' from numbers(1000);
INSERT INTO checkouts SELECT number as id, '2000-01-01 11:10:00' from numbers(1000);

-- by this time we should have 5 parts for target_table because of prev inserts
-- and we plan to make two more inserts. With index_granularity=128 and max id=1
-- we expect to read not more than:
--      1 mark per part * (5 + 2) parts * 128 granularity + 1 (numbers(1)) = 897 rows
set max_rows_to_read = 897;

INSERT INTO logins    SELECT number+2 as id, '2001-01-01 11:10:01' from numbers(1);
INSERT INTO checkouts SELECT number+2 as id, '2001-01-01 11:10:02' from numbers(1);


set max_rows_to_read = 0;

select '-- unmerged state';

select
   id,
   finalizeAggregation(latest_login_time) as current_latest_login_time,
   finalizeAggregation(latest_checkout_time) as current_latest_checkout_time,
   finalizeAggregation(fastest_session)  as current_fastest_session,
   finalizeAggregation(biggest_inactivity_period)  as current_biggest_inactivity_period
from target_table
where id in (1,2)
ORDER BY id, current_latest_login_time, current_latest_checkout_time;

select '-- merged state';

SELECT
     id,
     maxMerge(latest_login_time) as current_latest_login_time,
     maxMerge(latest_checkout_time) as current_latest_checkout_time,
     minMerge(fastest_session) as current_fastest_session,
     maxMerge(biggest_inactivity_period) as current_biggest_inactivity_period
FROM target_table
where id in (1,2)
GROUP BY id
ORDER BY id;

DROP TABLE IF EXISTS logins;
DROP TABLE IF EXISTS mv_logins2target;
DROP TABLE IF EXISTS checkouts;
DROP TABLE IF EXISTS mv_checkouts2target;
DROP TABLE target_table;
