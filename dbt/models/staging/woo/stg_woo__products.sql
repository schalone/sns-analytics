-- Verified against sipandscript_new_ds.products (2026-09-27):
--   select type, count(*), countif(venue_id is not null) from products group by 1
--   -> type in ('simple','external','variable'); venue_id is NULL for every row (with_venue = 0
--   for all three types), so the brief's `venue_id is not null` ticket rule never fires.
--   `tribe_wooticket_for_event` (the Tribe Events/Event Tickets postmeta linking a ticket product
--   to its event) is populated for 17404 of 17636 rows and is the real ticket discriminator;
--   the remaining rows split into 4 gift-card-named products and 228 "materials" (kits, guides,
--   apparel, wallpapers, etc). The gift-card name check runs after the ticket check so a workshop
--   like "...Gift Card Lettering for Beginners at Principles Bk" (which does have
--   tribe_wooticket_for_event set) is still classified as a ticket, not a gift card.
select cast(id as string) as woo_product_id, name, type, cast(venue_id as string) as woo_venue_id,
  case
    when tribe_wooticket_for_event is not null then 'ticket'
    when lower(name) like '%gift card%' or lower(name) like '%gift certificate%' then 'gift_card'
    else 'materials'
  end as product_kind,
  cast(tribe_wooticket_for_event as string) as woo_event_id
from {{ source('woo', 'products') }}
