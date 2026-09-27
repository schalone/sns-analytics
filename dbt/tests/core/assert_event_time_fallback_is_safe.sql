-- Fix round 1: verifies event_instant (dbt/macros/event_instant.sql, also used by
-- core_events.sql) is failure-safe against an unrecognised/invalid time_zone string and against a
-- NULL time_expr, on literals only (no table scan). Returns a row for any mismatch between the
-- macro's actual output and the expected value.
with cases as (
  -- 1. Valid zone: 2026-01-15 19:00 America/Chicago (CST, UTC-6 in January) -> 2026-01-16 01:00:00 UTC
  select 'valid zone' as case_name,
    {{ event_instant("date('2026-01-15')", "time '19:00:00'", "'America/Chicago'") }} as actual,
    timestamp('2026-01-16 01:00:00 UTC') as expected
  union all
  -- 2. Invalid (unrecognised) zone string: must fall back to the America/New_York result --
  -- 2026-01-15 19:00 America/New_York (EST, UTC-5 in January) -> 2026-01-16 00:00:00 UTC
  select 'invalid zone string',
    {{ event_instant("date('2026-01-15')", "time '19:00:00'", "'Not/AZone'") }},
    timestamp('2026-01-16 00:00:00 UTC')
  union all
  -- 3. NULL zone: same New York fallback result as case 2
  select 'null zone',
    {{ event_instant("date('2026-01-15')", "time '19:00:00'", "cast(null as string)") }},
    timestamp('2026-01-16 00:00:00 UTC')
  union all
  -- 4. Malformed time string, passed unparsed with no midnight default applied: a NULL time_expr
  -- must propagate safely to a NULL result rather than erroring or being silently masked.
  select 'malformed time string',
    {{ event_instant("date('2026-01-15')", "safe.parse_time('%H:%M:%S', 'not-a-time')", "'America/Chicago'") }},
    cast(null as timestamp)
)
select * from cases where actual is distinct from expected
