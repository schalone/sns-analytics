with a as (select date, sum(spend) as spend from {{ ref('core_ad_spend_allocation') }} group by 1),
s as (select date, sum(spend) as spend from {{ ref('core_ad_spend') }} group by 1)
select coalesce(a.date, s.date) as date, a.spend as allocated_plus_unallocated, s.spend as total
from a full outer join s using (date)
where abs(coalesce(a.spend, 0) - coalesce(s.spend, 0)) > 0.01
