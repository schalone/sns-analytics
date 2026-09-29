-- Ad spend that no event absorbed: no event in that metro sold a seat that day.
select date, platform, metro_key, spend
from {{ ref('core_ad_spend_allocation') }}
where event_key is null
