-- Final-review I15b: warn when the newest core_sessions day is more than 3 days old (GA4 export stopped, or the
-- daily build has not run). An outage longer than ga4_lookback_days needs the recovery build in the runbook.
{{ config(severity='warn') }}
select max(session_date) as latest_session_date
from {{ ref('core_sessions') }}
having max(session_date) is null or max(session_date) < date_sub(current_date(), interval 3 day)
