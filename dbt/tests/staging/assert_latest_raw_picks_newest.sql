select s.order_key
from {{ ref('stg_cms__orders') }} s
join (select key, max(updated_at) as max_updated from {{ source('raw_cms', 'orders') }} group by key) r on r.key = s.order_key
where s.updated_at < r.max_updated
