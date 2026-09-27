with latest as ({{ latest_raw('raw_cms', 'promo_redemptions') }})
select key as redemption_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.checkoutSessionKey') as checkout_session_key,
  json_value(payload, '$.promoCode') as promo_code, json_value(payload, '$.eventKey') as event_key,
  cast(json_value(payload, '$.discountCents') as int64) / 100 as discount, json_value(payload, '$.status') as status,
  timestamp(json_value(payload, '$.reservedAt')) as reserved_at, timestamp(json_value(payload, '$.redeemedAt')) as redeemed_at, updated_at
from latest
