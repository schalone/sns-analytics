{#
  Builds a failure-safe UTC instant from a venue-local DATE (`date_expr`) + already-parsed
  TIME-of-day expression (`time_expr`) + IANA time zone name (`zone_expr`). The caller owns any
  time-string parsing/defaulting (e.g. `coalesce(safe.parse_time(...), time '00:00:00')`) before
  passing it in as `time_expr` -- a `time_expr` that itself evaluates to NULL (an unparseable time
  string with no default applied) propagates safely to a NULL result here rather than erroring or
  being silently masked.

  Task 14b fix round 1: `TIMESTAMP(datetime, zone)` raises "Invalid time zone" for a non-NULL but
  unrecognised zone string, which would fail the whole core_events build the first time a real CMS
  event carries a bad zone. `SAFE.TIMESTAMP` catches that -- and a NULL zone, which simply
  propagates to NULL rather than erroring -- and returns NULL instead, so the outer `coalesce`
  falls back to interpreting the same local date+time as America/New_York, mirroring the site's
  own fallback behaviour for a zone it does not recognise.
#}
{% macro event_instant(date_expr, time_expr, zone_expr) %}
coalesce(
  safe.timestamp(datetime({{ date_expr }}, {{ time_expr }}), {{ zone_expr }}),
  safe.timestamp(datetime({{ date_expr }}, {{ time_expr }}), 'America/New_York')
)
{% endmacro %}
