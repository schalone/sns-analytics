-- Final-review I18: core_search_daily (page x query) is PARTIAL, so per property and day its clicks can only be
-- at most the property total in core_search_totals_daily. Fails if the partial table ever exceeds the total
-- (a duplicated load, a wrong join, or totals missing for a day that has query rows).
with q as (
  select property, date, sum(clicks) as query_clicks from {{ ref('core_search_daily') }} group by 1, 2
)
select q.property, q.date, q.query_clicks, t.clicks as total_clicks
from q
left join {{ ref('core_search_totals_daily') }} t using (property, date)
where q.query_clicks > coalesce(t.clicks, 0)
