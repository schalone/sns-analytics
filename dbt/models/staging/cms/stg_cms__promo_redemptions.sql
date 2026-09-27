-- The CMS export API's final review renamed this field to `orderDiscountCents` (it is
-- the order's total discount, not a per-redemption amount) and the old `discountCents` spelling is
-- never exported. Exposed as `order_discount`; the old `discount` column is removed (grepped
-- `dbt/` -- nothing downstream referenced `stg_cms__promo_redemptions.discount`).
with latest as ({{ latest_raw('raw_cms', 'promo_redemptions') }})
select key as redemption_key, json_value(payload, '$.orderKey') as order_key, json_value(payload, '$.checkoutSessionKey') as checkout_session_key,
  json_value(payload, '$.promoCode') as promo_code, json_value(payload, '$.eventKey') as event_key,
  cast(json_value(payload, '$.orderDiscountCents') as int64) / 100 as order_discount, json_value(payload, '$.status') as status,
  timestamp(json_value(payload, '$.reservedAt')) as reserved_at, timestamp(json_value(payload, '$.redeemedAt')) as redeemed_at, updated_at
from latest
