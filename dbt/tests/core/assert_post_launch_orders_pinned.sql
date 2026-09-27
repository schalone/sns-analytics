-- Final-review I17c: warn, not error, until the pinned figure is confirmed against the warehouse after the
-- first CMS backfill; raise to error (delete this config line) once confirmed.
{{ config(severity='warn') }}
-- Ruling 1: with raw_cms empty, there are zero webapp orders in this window today. This must
-- return no rows in that state (only a real deficit/excess of webapp order volume once the CMS
-- loader runs should fail it), so the `c > 0` guard is required in addition to the brief's range
-- check -- a bare `count(*)` is 0, not NULL, for an empty window and would otherwise always fail
-- `not between 5275 and 5381`.
with n as (
  select count(*) as c
  from {{ ref('core_orders') }}
  where source_system = 'webapp' and business_date between '2026-06-23' and '2026-09-17' and status in ('Paid','Partial Refund','Refunded')
)
select c from n where c > 0 and c not between 5275 and 5381
