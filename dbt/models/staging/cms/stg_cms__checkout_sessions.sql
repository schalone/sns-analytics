-- checkout_session_key is lower-cased everywhere it is exposed, to match the lower-cased Stripe side.
with latest as ({{ latest_raw('raw_cms', 'checkout_sessions') }})
select lower(key) as checkout_session_key, json_value(payload, '$.status') as status, json_value(payload, '$.memberKey') as member_key,
  json_value(payload, '$.customerHash') as customer_hash, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.eventKey') as event_key,
  cast(json_value(payload, '$.guestCount') as int64) as guest_count, timestamp(json_value(payload, '$.createdAt')) as created_at,
  timestamp(json_value(payload, '$.holdExpiresAt')) as hold_expires_at, timestamp(json_value(payload, '$.lastActivityAt')) as last_activity_at, updated_at
from latest
