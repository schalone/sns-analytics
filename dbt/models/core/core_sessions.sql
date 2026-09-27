{{ config(materialized='incremental', incremental_strategy='insert_overwrite', partition_by={'field': 'session_date', 'data_type': 'date'}, tags=['hourly']) }}
{% set lookback = 3 %}
-- Ruling 3 (controller): insert_overwrite only replaces the partitions present in this query's
-- output. A session that starts the day before the incremental window opens can have tail events
-- land inside the window; reading events only from `lookback` days back would split that session
-- across two runs (a stale/duplicate row in the old partition and a fresh one in the new
-- partition, breaking uniqueness). Fix: read one extra day of events (`lookback + 1`) so
-- aggregation and the phantom-referral lag() below see the whole session and its true
-- predecessor, but only ever emit rows whose session_date falls inside the `lookback`-day window
-- (see the final filter). The extra day's own partition is left untouched here -- it was already
-- written, with its own one-day buffer, by an earlier run whose window included it.
--
-- That one-day buffer covers a session genuinely spanning midnight, but real GA4 export data has
-- a worse case found while verifying this fix: the same (user_pseudo_id, ga_session_id) can get a
-- single stray late hit days after the session actually ended (a client resending a stale cached
-- session id -- observed 2026-09-27: ga_session_id 1790128411 for user 1792276838.1790113388 had
-- its session_start/page_view on 2026-09-22/23, then one more `view_item` hit landed in the
-- 2026-09-25 daily table). Re-aggregating that alone, on a run whose read window no longer
-- includes 09-22/23, mints a second, wrong-partitioned row for a session_key whose true row
-- already exists further back -- a duplicate no fixed-size read buffer can rule out in general.
-- Guarded against directly below: an incremental run never emits a session_key that already has a
-- row in an older, out-of-window partition of this same table.
with ev as (
  select
    user_pseudo_id,
    (select value.int_value from unnest(event_params) where key = 'ga_session_id') as ga_session_id,
    event_name, event_timestamp, parse_date('%Y%m%d', event_date) as event_date,
    (select value.string_value from unnest(event_params) where key = 'page_location') as page_location,
    (select value.string_value from unnest(event_params) where key = 'source') as ep_source,
    (select value.string_value from unnest(event_params) where key = 'medium') as ep_medium,
    (select value.string_value from unnest(event_params) where key = 'campaign') as ep_campaign,
    (select coalesce(value.int_value, safe_cast(value.string_value as int64)) from unnest(event_params) where key = 'session_engaged') as session_engaged,
    session_traffic_source_last_click.manual_campaign.source as lc_source,
    session_traffic_source_last_click.manual_campaign.medium as lc_medium,
    session_traffic_source_last_click.manual_campaign.campaign_name as lc_campaign,
    session_traffic_source_last_click.google_ads_campaign.campaign_id as lc_google_ads_campaign_id,
    collected_traffic_source.gclid as gclid,
    device.category as device_category, geo.country, geo.region, geo.city
  from {{ source('ga4', 'events') }}
  where regexp_contains(_table_suffix, r'^\d{8}$')
  {% if is_incremental() %}
    and _table_suffix >= format_date('%Y%m%d', date_sub(current_date(), interval {{ lookback + 1 }} day))
  {% else %}
    and _table_suffix >= format_date('%Y%m%d', date('{{ var("ga4_start_date") }}'))
  {% endif %}
),
sess as (
  select
    concat(user_pseudo_id, '.', cast(ga_session_id as string)) as session_key, user_pseudo_id,
    timestamp_micros(min(event_timestamp)) as session_start_at, min(event_date) as session_date,
    array_agg(page_location ignore nulls order by event_timestamp limit 1)[safe_offset(0)] as landing_page,
    coalesce(max(lc_source), array_agg(ep_source ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as raw_source,
    coalesce(max(lc_medium), array_agg(ep_medium ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as raw_medium,
    coalesce(max(lc_campaign), array_agg(ep_campaign ignore nulls order by event_timestamp limit 1)[safe_offset(0)]) as campaign,
    max(lc_google_ads_campaign_id) as google_ads_campaign_id,
    max(gclid) as gclid,
    max(session_engaged) = 1 as engaged,
    countif(event_name = 'page_view') as page_views,
    any_value(device_category) as device_category, any_value(country) as country, any_value(region) as region, any_value(city) as city
  from ev where ga_session_id is not null
  group by 1, 2
),
fixed as (
  -- phantom accounts.google.com referral: inherit the same user's previous non-phantom session within 30 minutes, else direct
  select s.*,
    raw_source = 'accounts.google.com' as is_phantom_referral,
    lag(raw_source) over (partition by user_pseudo_id order by session_start_at) as prev_source,
    lag(raw_medium) over (partition by user_pseudo_id order by session_start_at) as prev_medium,
    lag(campaign) over (partition by user_pseudo_id order by session_start_at) as prev_campaign,
    lag(session_start_at) over (partition by user_pseudo_id order by session_start_at) as prev_start
  from sess s
),
final as (
  select session_key, user_pseudo_id, session_start_at, session_date, landing_page,
    regexp_extract(landing_page, r'^https?://[^/]+(/[^?#]*)') as landing_page_path,
    regexp_extract(landing_page, r'[?&]q=([^&#]+)') as landing_query_q,
    case when is_phantom_referral and prev_source is not null and prev_source != 'accounts.google.com' and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_source
         when is_phantom_referral then '(direct)' else coalesce(raw_source, '(direct)') end as source,
    case when is_phantom_referral and prev_source is not null and prev_source != 'accounts.google.com' and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_medium
         when is_phantom_referral then '(none)' else coalesce(raw_medium, '(none)') end as medium,
    case when is_phantom_referral and timestamp_diff(session_start_at, prev_start, minute) <= 30 then prev_campaign else campaign end as campaign,
    google_ads_campaign_id, gclid, gclid is not null as has_gclid, engaged, page_views, device_category, country, region, city, is_phantom_referral,
    session_date < date('{{ var("launch_date") }}') as pre_launch
  from fixed
)
select final.*, {{ channel_group('source', 'medium', 'campaign', 'has_gclid') }} as default_channel_group
from final
{% if is_incremental() %}
left join (
  select distinct session_key
  from {{ this }}
  where session_date < date_sub(current_date(), interval {{ lookback }} day)
) as protected
  on protected.session_key = final.session_key
where final.session_date >= date_sub(current_date(), interval {{ lookback }} day)
  and protected.session_key is null
{% endif %}
