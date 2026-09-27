-- Final-review I17c: warn, not error, until the pinned figure is confirmed against the warehouse after the
-- first CMS backfill; raise to error (delete this config line) once confirmed. The pinned $474.1k is GROSS
-- ticket revenue (the amount charged for ticket orders, before refunds), hence gross_revenue below.
{{ config(severity='warn') }}
-- Ruling 1: unlike the order-count pinned test, this one needs no extra empty-state guard: with
-- zero matching webapp ticket orders, sum(gross_revenue) over an empty set is NULL, and
-- `NULL not between ...` evaluates to NULL/unknown, which the outer WHERE filters out -- so this
-- naturally returns no rows when raw_cms is empty, and only fails once real webapp ticket revenue
-- in the window falls outside the pinned range.
select r from (
  select sum(gross_revenue) as r
  from {{ ref('core_orders') }}
  where source_system = 'webapp' and business_date between '2026-06-23' and '2026-09-17'
    and status in ('Paid','Partial Refund','Refunded') and order_type = 'ticket'
) where r not between 469359 and 478841
