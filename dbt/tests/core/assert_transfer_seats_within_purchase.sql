-- For every root of a legacy seat transfer, the seats its transfers hold plus the seats left on its own
-- ticket lines must equal the ticket seats it bought, and the transfer_in bookings must carry exactly the
-- seats held. A root with no ticket lines bought no seat to count against: there, every transfer that was
-- not itself superseded must hold all its own seats. No economics line may carry negative seats.
with bought as (
  select li.order_key, sum(coalesce(li.quantity, 1)) as seats
  from {{ ref('stg_woo__order_line_items') }} li
  join {{ ref('stg_woo__products') }} p using (woo_product_id)
  where p.product_kind = 'ticket'
  group by 1
),
held as (
  select root_order_key as order_key, sum(seats_held) as seats, sum(if(is_superseded, 0, seats)) as unsuperseded_seats
  from {{ ref('core_seat_transfers') }} where root_order_key is not null group by 1
),
held_on_bookings as (
  select transfer_root_order_key as order_key, sum(seats) as seats
  from {{ ref('core_order_item_economics') }} where booking_kind = 'transfer_in' group by 1
),
remaining as (
  select order_key, sum(seats) as seats
  from {{ ref('core_order_item_economics') }} where item_kind = 'ticket' group by 1
)
select h.order_key, 'seats_do_not_add_up' as problem
from held h
join bought b using (order_key)
left join remaining r using (order_key)
left join held_on_bookings hb using (order_key)
where h.seats + coalesce(r.seats, 0) != b.seats
   or h.seats != coalesce(hb.seats, 0)
union all
select h.order_key, 'root_without_ticket_lines_does_not_hold_transfer_seats'
from held h
left join bought b using (order_key)
left join held_on_bookings hb using (order_key)
where b.order_key is null
  and (h.seats != h.unsuperseded_seats or h.seats != coalesce(hb.seats, 0))
union all
select order_item_key, 'negative_seats'
from {{ ref('core_order_item_economics') }}
where seats < 0
