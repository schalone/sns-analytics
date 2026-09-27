-- Final-review I18: [date, page] is complete, so over the last 28 days of data its clicks must be within 10% of
-- the property totals ([date]) for each property (the two aggregate slightly differently: by page vs by
-- property). Warn only: a gap means the page load is incomplete for some days.
{{ config(severity='warn') }}
with bounds as (
  select property, date_sub(max(date), interval 27 day) as start_date, max(date) as end_date
  from {{ ref('core_search_totals_daily') }} group by 1
),
totals as (
  select t.property, sum(t.clicks) as total_clicks
  from {{ ref('core_search_totals_daily') }} t join bounds b using (property)
  where t.date between b.start_date and b.end_date group by 1
),
pages as (
  select p.property, sum(p.clicks) as page_clicks
  from {{ ref('core_search_page_daily') }} p join bounds b using (property)
  where p.date between b.start_date and b.end_date group by 1
)
select totals.property, totals.total_clicks, pages.page_clicks
from totals left join pages using (property)
where totals.total_clicks > 0
  and abs(coalesce(pages.page_clicks, 0) - totals.total_clicks) > 0.10 * totals.total_clicks
