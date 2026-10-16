-- Pinned 2026-10-16 to the first CMS backfill: 5,270 paid webapp orders, +-1%. The September investigation's
-- 5,328 was 1.1% higher; no counting basis reproduces it, and gross ticket revenue in the same window matched
-- its pinned $474.1k to $50 (assert_post_launch_ticket_revenue_pinned), so the warehouse figure is the pin.
-- Ruling 1: with raw_cms empty, there are zero webapp orders in this window today. This must
-- return no rows in that state (only a real deficit/excess of webapp order volume once the CMS
-- loader runs should fail it), so the `c > 0` guard is required in addition to the brief's range
-- check -- a bare `count(*)` is 0, not NULL, for an empty window and would otherwise always fail
-- `not between 5217 and 5323`.
with n as (
  select count(*) as c
  from {{ ref('core_orders') }}
  where source_system = 'webapp' and business_date between '2026-06-23' and '2026-09-17' and status in ('Paid','Partial Refund','Refunded')
)
select c from n where c > 0 and c not between 5217 and 5323
