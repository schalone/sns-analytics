-- Any stored Stripe payload containing an @ means personal data reached the warehouse.
select 'balance_transactions' as entity, key from {{ source('raw_stripe', 'balance_transactions') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'refunds', key from {{ source('raw_stripe', 'refunds') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'disputes', key from {{ source('raw_stripe', 'disputes') }} where strpos(to_json_string(payload), '@') > 0
union all
select 'payouts', key from {{ source('raw_stripe', 'payouts') }} where strpos(to_json_string(payload), '@') > 0
