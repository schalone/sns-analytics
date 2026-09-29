{{ config(severity='warn') }}
-- The new platform records a seat transfer on its tickets: the old ticket gets status 'Transferred' and the
-- new ticket carries transferred_from_ticket_key. The seat rule already follows ticket status (a Transferred
-- ticket holds no seat), but the money rule for new-platform transfers is not yet decided: today the old
-- item's money stays on the original event while its seat leaves it. Legacy transfers follow a decided rule
-- (the seat and the money paid for it move to the class attended; see core_seat_transfers and
-- core_order_item_economics). One row per ticket status, with a count, while any such ticket exists, so the
-- first new-platform transfer is visible until its money rule is decided and built.
select status,
  count(*) as tickets,
  countif(status = 'Transferred') as transferred_status,
  countif(transferred_from_ticket_key is not null) as with_transferred_from
from {{ ref('stg_cms__tickets') }}
where status = 'Transferred' or transferred_from_ticket_key is not null
group by status
