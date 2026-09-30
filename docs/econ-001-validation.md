# ECON-001 validation

Date run: 2026-09-28
Commit: model code at `385445d` (no model SQL changed during validation); tests, script and docs added in the
commits that follow it on `feat/phase-one`.

Updated 2026-09-29: the model now deducts net disputed (chargeback) money and nets failed refunds (commit
`89fb4f4`), and the KPI and paid-performance marts credit a transferred seat's money to the original purchase
(commit `cdf71a4`). Every figure below that those changes move was re-queried from the `dev_flock_*` build
after them; the worked orders and worked events carry no dispute and are unchanged.

Updated 2026-09-30: a legacy order refunded by status alone no longer refunds money a lost chargeback already
took (see "Known limits"). One order changed; the S&S figures for 2023 and in total below were re-queried.

**Where these figures come from.** Every figure below was queried from a build in the `dev_flock_*`
datasets (`dev_flock_staging`, `dev_flock_core`, `dev_flock_mart`, `dev_flock_ops`), which read the real raw
and archive datasets. The production `staging`, `core`, `mart` and `ops` datasets have not been rebuilt with
these models. `dev_flock_core` also holds a stale table `orders_flag_transfers__dbt_tmp214157898899`, left
over from an interrupted build; no model reads it.

**Data available.** The legacy WooCommerce archive (2016 to 2026-06-19) and the full Stripe history are
loaded. The new platform's CMS tables are empty (no bronco orders, no metros, no CMS events) and no ad spend
is loaded. Everything validated here is therefore legacy.

Orders are identified by `woo-<id>` and events by `woo-ev-<id>` only. No personal data is recorded.

## Rules validated

The economics rules of the design addendum (`docs/superpowers/specs/2026-09-27-economics-and-booking-curve-design.md`),
checked against the worked orders and events below. Where a rule reads
"model computes it as specified", the worked orders prove that the model applies the rule exactly as written
to Stripe's own figures. That the business actually splits its money this way is the owner's statement; it
cannot be checked without payout records, which are not used.

| Rule | Result |
|---|---|
| 1. The 60/40 split applies after Stripe fees | Model computes it as specified: in all three worked orders the shares equal 0.40 and 0.60 of Stripe's charge less refund less Stripe's own fee, to the cent. |
| 2. Service fees are part of the split | Not exercised: the legacy site charged no service fee. Proven by unit tests only. |
| 3. The split is on final realized revenue; discounts and refunds reduce it | Model computes it as specified: woo-348795 (discounted, 21.00 off) and woo-345525 (fully refunded). Chargebacks reduce it too (see the dispute row below). |
| 4. Materials are never subtracted from S&S | Model computes it as specified: on woo-ev-269869 `sns_share` 406.38 = 0.40 x 1,015.95 while the materials estimate (90.00) is shown separately. |
| 5. S&S pays 100% of advertising | Not exercised: no ad spend is loaded. |
| 6. The 60/40 rule holds for the whole legacy era | Assumed, not verifiable: no payout records are used. |
| 7. Google Ads is live; Meta is the main paid channel | Not a model rule; not exercised (no spend loaded). |
| 8. Both platforms use the same Stripe account | Supported for legacy: 96,864 legacy charges match an archive order. Bronco not yet testable. |
| Stated assumption: a fully refunded booking has net = -fee | Model computes it as specified: woo-345525 net -2.19; Stripe kept its 2.19 fee and the refund carried no fee of its own. |
| Stated assumption: dispute fees count as processing fees | Exercised on real data, not hand-checked. Stripe records a dispute as an `adjustment` with reporting category `dispute` (a withdrawal) or `dispute_reversal` (money returned). On the orders the model counts: 52 withdrawals, -5,265.80, carrying 780.00 of dispute fees, and 20 reversals, +2,528.80, returning 195.00 of fees. The fees are in `processing_fee`; the net withdrawn money, 2,737.00 over 32 orders, is `disputed_amount` and is deducted from net distributable. 14 further disputed orders (995.00 net: 11 failed, 2 cancelled, 1 on-hold) are not orders the model counts. `assert_allocation_conserves_money` checks each order's split against Stripe. |
| Stated assumptions on gift cards as payment | Rule confirmed by the owner on 2026-09-30: a seat paid for with a gift card earns the instructor 60% of the class price, so it is an ordinary booking at ticket value, split 60/40, with no Stripe fee, as the model treats it. Not exercised on data: no legacy order records a gift card applied, and no bronco order is loaded. |
| Transferred seats (§6.8): the seat and its money follow the transfer | Model computes it as specified: woo-373065 and woo-ev-259204. That a moved seat's money goes to the instructor of the class attended is the owner's statement. |

## Worked orders

Each order was chosen by a query on `core_bookings`, then checked against Stripe with
`scripts/econ_check_order.py --legacy <id>`, which reads charges, refunds and balance transactions straight
from Stripe and shares no code with the loaders or dbt. The hand arithmetic uses Stripe's figures only.
All three are pinned in `dbt/tests/core/assert_worked_order.sql`.

### woo-348795: a discounted purchase

Business date 2025-01-14, two ticket lines of one seat each, 21.00 of discount, no refund, no transfer, and
the only 2025 order meeting all of those conditions.

| Figure | From Stripe, by hand | From core_bookings | Difference |
|---|---|---|---|
| Charged / realized | 119.00 | 55.25 + 63.75 = 119.00 | 0.00 |
| Refunded | 0.00 | 0.00 | 0.00 |
| Stripe fee | 3.75 | 1.741071 + 2.008929 = 3.75 | 0.00 |
| Net distributable | 119.00 - 0 - 3.75 = 115.25 | 115.25 | 0.00 |
| S&S share (40%) | 46.10 | 46.10 | 0.00 |
| Instructor share (60%) | 69.15 | 69.15 | 0.00 |

### woo-345525: a refunded purchase

Business date 2025-01-02, one seat, order status `refunded`, fully refunded in Stripe, no transfer. One of
140 such orders in 2025; in the Stripe data the model reads, none of the 140 has a refund transaction
carrying a fee.

| Figure | From Stripe, by hand | From core_bookings | Difference |
|---|---|---|---|
| Charged / realized | 65.00 | 65.00 | 0.00 |
| Refunded | 65.00 | 65.00 | 0.00 |
| Stripe fee | 2.19 (charge 2.19, refund 0.00) | 2.19 | 0.00 |
| Net distributable | 65.00 - 65.00 - 2.19 = -2.19 | -2.19 | 0.00 |
| S&S share (40%) | -0.876 | -0.876 | 0.00 |
| Instructor share (60%) | -1.314 | -1.314 | 0.00 |

The booking counts no seat (`net_seats` 0, cancelled).

### woo-373065: a root order that gave one seat to a transfer

Business date 2025-03-14, one line of 2 seats at 75.00, 150.00 paid, no refund. In the archive, order
woo-466389 (total 0, parent woo-373065, completed, not itself a parent) moved one seat to event woo-ev-440181.
Stripe has one charge, on the root. One of 14 such orders in 2025.

| Figure | From Stripe | Per seat, by hand | Root booking (woo-li-97913, woo-ev-355204) | Transfer booking (woo-li-117820, woo-ev-440181, `transfer_in`) | Sum | Difference |
|---|---|---|---|---|---|---|
| Charged / realized | 150.00 | 75.00 | 75.00 | 75.00 | 150.00 | 0.00 |
| Refunded | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |
| Stripe fee | 4.65 | 2.325 | 2.325 | 2.325 | 4.65 | 0.00 |
| Net distributable | 145.35 | 72.675 | 72.675 | 72.675 | 145.35 | 0.00 |
| S&S share (40%) | 58.14 | 29.07 | 29.07 | 29.07 | 58.14 | 0.00 |
| Instructor share (60%) | 87.21 | 43.605 | 43.605 | 43.605 | 87.21 | 0.00 |

The root booking shows `seats_purchased` 2, `seats_transferred_out` 1, one seat; the transfer booking has
`transfer_root_order_key = 'woo-373065'` and one seat.

## Worked events

Both events were counted by hand from the archive tables (`woo.orders`, `woo.order_line_items`,
`woo.products`), bypassing every core model. Sale date is `coalesce(date_paid_gmt, date_created_gmt)` in New
York time. Both are pinned in `dbt/tests/core/assert_worked_event.sql`.

### woo-ev-269869: sold out, no transfers

Event date 2024-03-03, capacity 15. Twelve orders, all completed, no parent, none of them the parent of any
order, one ticket product, 70.00 a seat. One of 53 sold-out 2024 events meeting the selection conditions.

| Figure | Counted by hand from the archive | From core_event_economics |
|---|---|---|
| Seats sold | 15 | 15 |
| Realized revenue | 15 x 70.00 = 1,050.00 | 1,050.00 |
| First sale (days before) | 2024-02-15: 17 | 17 |
| 25% / 50% / 75% sold (days before) | 14 / 13 / 12 | 14 / 13 / 12 |
| Sellout (days before) | 2024-02-23: 9 | 9 |

Daily seats by hand: 02-15 1, 02-17 2, 02-18 2, 02-19 5, 02-20 2, 02-21 2, 02-23 1. The model's booking curve
(`core_event_daily`) shows the same daily counts, reaching 15 seats, 1,050.00 and 406.38 of S&S share on
2024-02-23.

The one-row milestone answer (`mart_event_performance`) for this event: Sunday, 13:00 local, spring,
capacity 15, 70.00 a ticket, 15 seats, 12 bookings, 12 customers, utilisation 1.0, sold out, realized
1,050.00, fee 34.05 (all from Stripe), net 1,015.95, S&S 406.38, instructor 609.57, materials estimate 90.00,
pace 17 / 14 / 13 / 12 / 9. Null by design today: metro, category, event type and theme (no CMS dimensions
loaded), peers (need metros), ad spend and contribution (no spend loaded; null rather than zero).

### woo-ev-259204: sold out, three seats transferred in, none lost

Event date 2024-03-21, capacity 17.

| Figure | Counted by hand from the archive | From the model |
|---|---|---|
| Purchased seats | 14 (9 orders at 65.00 a seat) | - |
| Transfer orders for this event | 3 (total 0, parent set, completed, none a parent of another order) | 3 `transfer_in` bookings |
| Seats sold | 14 + 3 = 17 | 17 |
| Money on transferred seats | 70.00 + 70.00 + 65.00 = 205.00 | 205.00 |
| Realized revenue | 910.00 + 205.00 = 1,115.00 | 1,115.00 |
| First sale (days before) | 2024-01-22: 59 | 59 |
| Sellout (days before) | 2024-03-19: 2 | 2 |

The transferred seats by hand: two came from root order woo-239448 (140.00 for 2 seats of another event, so
70.00 each), and one from root order woo-247662 (65.00 for 1 seat). Root woo-247662 moved its single seat twice: first
to another event (2024-02-28), then to this one (2024-03-11); the later transfer holds the seat and the earlier
one is superseded. The model agrees on each of the three: roots woo-239448, woo-239448, woo-247662, 70.00,
70.00, 65.00, dated 2024-03-11.

What the hand count cannot establish: it proves seats, realized revenue, sale dates and which paid order each
transferred seat came from. It does not prove the processing fee or shares of the transferred seats (those
come from the roots' Stripe charges, a path woo-373065 covers), it relies on the operator's description of
how the site recorded a move (there is no record of the move itself), and capacity is the model's final
capacity, not recounted.

## Legacy economics by year

From `core_bookings` (legacy era, by purchase year) and `core_event_economics` (dated legacy events, by event
year). 2026 runs to the end of the legacy era, 2026-06-18.

| Year | Realized revenue | Disputed | S&S share | Net seats | Sold-out events (event year) |
|---|---|---|---|---|---|
| 2016 | 2,435.00 | 0.00 | 943.54 | 45 | - |
| 2017 | 63,163.50 | 0.00 | 24,036.69 | 929 | - |
| 2018 | 130,076.50 | 0.00 | 48,417.41 | 1,880 | - |
| 2019 | 196,029.69 | 65.00 | 73,661.41 | 2,997 | - |
| 2020 | 205,708.49 | 455.00 | 76,794.66 | 2,797 | 77 of 422 |
| 2021 | 616,555.18 | 740.00 | 230,946.78 | 8,976 | 172 of 794 |
| 2022 | 1,911,280.64 | 460.00 | 722,294.36 | 27,510 | 603 of 2,408 |
| 2023 | 1,427,664.39 | 204.00 | 538,541.67 | 19,326 | 415 of 2,126 |
| 2024 | 1,440,467.10 | 553.00 | 547,047.96 | 19,811 | 481 of 1,955 |
| 2025 | 2,365,095.94 | 260.00 | 896,060.50 | 33,663 | 732 of 2,785 |
| 2026 | 1,274,908.00 | 0.00 | 485,412.10 | 18,188 | 409 of 1,555 |
| All | 9,633,384.43 | 2,737.00 | 3,644,157.08 | 136,122 | 2,889 of 12,045 |

Disputed is net chargeback money, already deducted from S&S share (S&S falls by 0.40 of it). "of N" counts dated legacy events that sold at least one seat. No legacy event before 2020 has an event date.
Realized revenue and S&S share include 32,153.50 of zero-total orders with no parent and 2,140.00 of transfer
orders that never reach a paid order, 34,293.50 in all, labelled `booking_kind = 'unpaid_zero_total'`. Their
nature is not established (see "Zero-total orders with ticket value and no paid origin" below); exclude them
with `booking_kind != 'unpaid_zero_total'`.

## Coverage

**Stripe charges by match method and year.**

| Year | Charges | Order id in metadata | Order id in description | Ad hoc | No order |
|---|---|---|---|---|---|
| 2016 | 242 | 0 | 38 | 0 | 204 |
| 2017 | 710 | 0 | 710 | 0 | 0 |
| 2018 | 1,337 | 1,225 | 112 | 0 | 0 |
| 2019 | 2,210 | 2,210 | 0 | 0 | 0 |
| 2020 | 2,532 | 2,532 | 0 | 0 | 0 |
| 2021 | 6,737 | 6,737 | 0 | 0 | 0 |
| 2022 | 20,451 | 20,401 | 0 | 0 | 50 |
| 2023 | 14,792 | 14,774 | 0 | 0 | 18 |
| 2024 | 14,786 | 14,766 | 0 | 0 | 20 |
| 2025 | 21,501 | 21,486 | 0 | 0 | 15 |
| 2026 | 17,900 | 11,882 | 0 | 58 | 5,960 |

**Identity and fee source by year, legacy orders from 2019.** "Resolved" means a real customer hash
(not a surrogate for a WooCommerce account). "Card-paid" bookings are those with a Stripe fee, actual or
estimated.

| Year | Orders | Resolved | Resolved share | Card-paid bookings | Actual fee share |
|---|---|---|---|---|---|
| 2019 | 2,290 | 2,211 | 96.55% | 2,141 | 99.81% |
| 2020 | 2,604 | 2,541 | 97.58% | 2,091 | 100% |
| 2021 | 6,813 | 6,750 | 99.08% | 6,409 | 100% |
| 2022 | 22,430 | 22,311 | 99.47% | 21,337 | 99.99% |
| 2023 | 15,957 | 15,931 | 99.84% | 15,204 | 100% |
| 2024 | 16,294 | 16,246 | 99.71% | 15,598 | 100% |
| 2025 | 26,753 | 26,725 | 99.90% | 25,804 | 99.99% |
| 2026 | 14,781 | 14,765 | 99.89% | 14,285 | 99.99% |

Bookings vs `core_orders` for the new platform could not be compared: no bronco order is loaded.

## Success criteria (addendum spec §10)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | One query over `mart_event_performance` and `core_event_daily` answers every milestone question for a dated event | Cannot be evaluated yet | The query runs and, for woo-ev-269869, returns seats, money, shares, pace and the curve, all matching the hand count. Metro, category, peer benchmarks and contribution after ad spend are null because no CMS dimensions and no spend are loaded. |
| 2 | At least 98% of card-paid bookings in both eras carry an actual Stripe fee | Cannot be evaluated yet | No bronco booking exists. Legacy era: every year from 2019 is at least 99.81% (the lowest, 2019), and only 14 legacy bookings in all use the estimated fee. |
| 3 | At least 98% of orders from 2019 resolve to a customer, and cross-era customers are one row | Not met | 2019: 96.55%, 2020: 97.58% (every later year is above 99%). The shortfall is guest orders with no Stripe charge: 67 of 2019's 70 and all 36 of 2020's unresolved orders have gross revenue 0. It is fixed archive data. The cross-era half cannot be evaluated: no bronco customer exists. |
| 4 | No email, name, phone, street address or card detail in any written dataset | Met, for what was checked | Checked: (a) `assert_no_pii_columns` matches every column NAME in the four datasets dbt writes (staging, core, mart, ops) against a pattern for email, phone, name, street, address, card, last4, purchaser and attendee, and finds none (two gift-card columns, an amount and a record GUID, match through "card" and are exempt by exact name); (b) `assert_no_email_in_raw_stripe` scans every payload in the four `raw_stripe` tables for `@` and finds none. Not checked: column VALUES in the dbt datasets, and values in the other raw datasets (`raw_cms`, `raw_gsc`, `raw_spend`). Billing city, state and ZIP are stored on orders; they are not on the criterion's list. |
| 5 | The worked order and worked event tests pass | Cannot be evaluated yet | The spec asks for a bronco worked order and none can be chosen until bronco orders are loaded. Legacy era: `assert_worked_order` (three legacy orders) and `assert_worked_event` (two events) pass; `assert_worked_bronco_order_pinned` will warn once a bronco booking is two days old until one is checked and pinned. |

## Legacy fee estimate

Matched legacy charges: 96,864 charges, 9,836,419.88 charged, 314,616.03 of fees. Implied rate
(fees - 0.30 per charge) / amount = 285,556.83 / 9,836,419.88 = 0.0290. `legacy_fee_rate` stays 0.029 and
`legacy_fee_fixed` 0.30. The estimate applies to 14 bookings, 33.43 of fees in all.

## Warnings outstanding

Final build (`dbt build --exclude core_sessions core_session_orders`, `dev_flock_*`, 2026-09-30): PASS 335,
WARN 6, ERROR 0, of 341. Five warnings are ones the runbook already expects; the sixth,
`assert_raw_gsc_fresh`, fires because no Search Console load has run since 2026-09-27 (no job is deployed):

| Test | Rows | Cause |
|---|---|---|
| `assert_raw_cms_orders_fresh` | 1 | `raw_cms.orders` is empty; nothing loaded in the last day. |
| `assert_raw_gsc_fresh` | 1 | `raw_gsc.page_query` last loaded 2026-09-27; nothing loaded in the last two days. |
| `assert_webapp_orders_present` | 1 | No new-platform orders: the CMS export is not loaded. |
| `assert_reconciliation_variance_recent` | 28 | Recent bronco days have Stripe charges but no CMS orders to reconcile against (the count follows today's date). |
| `assert_stripe_charges_carry_a_join_key` | 1 | 2016: 204 of 242 charges carry no order reference (fixed archive data). |
| `assert_identity_coverage` | 2 | Legacy 2019 (96.55%) and 2020 (97.58%) resolved identity, below 98%. |

`assert_worked_bronco_order_pinned` passes today and will warn once a bronco booking is more than two days old.
The legacy totals above were re-queried after the build (realized 9,633,384.43, disputed 2,737.00, S&S
3,644,157.08, 136,122 seats).

## Investigations

### Unresolved identity (legacy orders)

| Year | Unresolved | Gross revenue 0 | With a matched Stripe charge | Guest checkout | Remainder: paid, no matched charge |
|---|---|---|---|---|---|
| 2016 | 31 | 1 | 30 | 31 | 0 |
| 2017 | 136 | 0 | 134 | 136 | 2 |
| 2018 | 37 | 33 | 3 | 37 | 1 |
| 2019 | 70 | 67 | 0 | 70 | 3 |
| 2020 | 36 | 36 | 0 | 36 | 0 |
| 2021 | 41 | 41 | 0 | 41 | 0 |
| 2022 | 50 | 49 | 0 | 50 | 1 |
| 2023 | 8 | 7 | 0 | 8 | 1 |
| 2024 | 17 | 17 | 0 | 17 | 0 |
| 2025 | 7 | 6 | 0 | 7 | 1 |
| 2026 | 8 | 7 | 0 | 8 | 1 |

Every unresolved legacy order is a guest checkout, and no transfer order is unresolved. From 2019 nearly all
have gross revenue 0, so there is no charge to carry an email. In 2016-2017 the orders do have a matched
charge, but that charge carries no customer hash (in that period the email sits only in charge metadata).
The remainder, 10 orders in all, are in a paid status with gross revenue above 0 and no matched charge: paid
outside Stripe or by a charge the matcher could not tie to them. Which is not established.

### Transfers

| Year of transfer | Transfers | Holding a seat | Superseded | No root | Money moved (realized) | S&S share moved | Days after purchase: Q1 / median / Q3 (max) | Weekday 09:00-17:59 NY | To an event in a different year |
|---|---|---|---|---|---|---|---|---|---|
| 2022 | 1,902 | 1,742 | 148 | 12 | 114,358.75 | 43,442.19 | 12 / 23 / 43 (1,043) | 73.3% | 165 |
| 2023 | 1,311 | 1,183 | 126 | 2 | 80,953.25 | 30,491.73 | 10 / 22 / 42 (1,131) | 67.2% | 139 |
| 2024 | 1,474 | 1,344 | 117 | 13 | 90,326.30 | 34,747.34 | 12 / 26 / 49 (647) | 63.8% | 114 |
| 2025 | 1,865 | 1,738 | 124 | 3 | 115,574.00 | 44,178.48 | 11 / 25 / 43 (753) | 68.6% | 154 |
| 2026 | 1,221 | 1,120 | 99 | 2 | 74,608.00 | 28,558.17 | 10 / 22 / 41 (333) | 63.6% | 49 |
| All | 7,773 | 7,127 | 614 | 32 | 475,820.30 | 181,417.92 | 11 / 24 / 44 (1,131) | 67.9% | 621 |

No transfer predates 2022. The minimum gap is 0 days every year. The different-year count compares the new
event's year with the root's earliest event year; 200 transfers could not be compared because one of the two
events has no date. About two thirds of transfers were made in office hours on a weekday, which suggests
staff made most of them, but the archive does not record who did. The spec's archive measurement found 36
transfer orders that never reach a paid order; the model has 32 with no root. The difference of 4 was not
investigated.

### Zero-total orders with ticket value and no paid origin

Orders with no parent, labelled `unpaid_zero_total`:

| Year | Orders | Seats | Realized revenue | Order discount equals item value |
|---|---|---|---|---|
| 2016 | 1 | 2 | 130.00 | 0 |
| 2017 | 1 | 1 | 65.00 | 0 |
| 2018 | 42 | 72 | 4,707.50 | 0 |
| 2019 | 70 | 136 | 9,030.00 | 0 |
| 2020 | 42 | 54 | 2,445.50 | 0 |
| 2021 | 56 | 84 | 5,297.50 | 0 |
| 2022 | 52 | 81 | 5,291.00 | 0 |
| 2023 | 20 | 22 | 1,449.00 | 6 |
| 2024 | 22 | 26 | 1,738.00 | 22 |
| 2025 | 11 | 12 | 800.00 | 11 |
| 2026 | 15 | 19 | 1,200.00 | 15 |
| All | 332 | 509 | 32,153.50 | 54 (4,148.00) |

Also labelled `unpaid_zero_total`: 32 transfer orders with no root (32 seats, 2,140.00). In all, 364 orders,
541 seats, 34,293.50.

The 332 orders match the operator's figure. The operator believes they are **likely** tickets bought with gift
cards; this is not verified. From mid-2023 almost every one carries an order-level discount equal to its whole
item value while its line still carries that value, a pattern that fits a gift card or voucher recorded as a
coupon; before 2023 there is no discount on them at all. The model keeps their line value as realized revenue
with no fee.

How gift cards are counted. The owner confirmed on 2026-09-30 that a seat paid for with a gift card earns the
instructor 60% of the class price: it is an ordinary booking, at ticket value, split 60/40, with no Stripe fee,
which is how the model already treats it. For these orders, if they are gift-card redemptions (likely,
unverified):

- Gift card **sale** lines are not bookings. Event figures, instructor share and S&S share therefore count a
  seat paid for with a gift card once, at ticket value, when the seat is booked.
- Order gross revenue (`core_orders.gross_revenue`, the order total) counts the gift card sale when the card
  is sold, and counts the redemption order at its order total, which is zero.
- No model adds the two together (`mart_daily_kpis` reports order revenue and booking S&S share as separate
  columns), so no double count exists in any model today. One would arise only if gift card sale revenue
  were added to booking revenue.

Not established: that these 332 orders are gift card redemptions at all (the owner said "likely"); and how
gift cards were redeemed in general (card sales, 41,198.25, exceed the value of these orders, 32,153.50).

### Stripe charges with no order

| Year | Charges | Amount | <$50 | $50-100 | $100-250 | $250-1,000 | >$1,000 | Customer also in core_customers |
|---|---|---|---|---|---|---|---|---|
| 2016 | 204 | 13,941.67 | 0 | 155 | 48 | 1 | 0 | 18 |
| 2022 | 50 | 17,960.00 | 5 | 0 | 0 | 45 | 0 | 17 |
| 2023 | 18 | 7,182.00 | 0 | 0 | 0 | 18 | 0 | 9 |
| 2024 | 20 | 7,980.00 | 0 | 0 | 0 | 20 | 0 | 8 |
| 2025 | 15 | 5,985.00 | 0 | 0 | 0 | 15 | 0 | 9 |
| 2026 | 5,960 | 543,600.00 | 21 | 4,292 | 1,548 | 96 | 3 | 238 |
| All | 6,267 | 596,648.67 | 26 | 4,447 | 1,596 | 195 | 3 | 299 |

All are charges (no `payment` rows), and all carry a customer hash. Of 2026, 5,950 charges (540,007.00) are
new-platform charges from 2026-06-19 on, which cannot match until the CMS orders are loaded; 10 (3,593.00) are
legacy. The legacy remainder over ten years is 56,641.67: 2016's 204 charges carry no order reference, and from
2022 a steady 15-50 charges a year of 250-1,000 each. The owner confirmed on 2026-09-30 what they are: private
and corporate events invoiced directly through Stripe. They are real revenue outside the event economics and
have no model yet; the rule for instructor pay on them is future scope.

### Undated legacy events

| Year of first sale | Undated events | Seats | S&S share | Share of that year's legacy seats | Share of that year's legacy S&S |
|---|---|---|---|---|---|
| 2016 | 3 | 63 | 1,291.90 | 100% | 100% |
| 2017 | 40 | 935 | 24,274.58 | 100% | 100% |
| 2018 | 127 | 1,970 | 50,649.86 | 100% | 100% |
| 2019 | 300 | 2,944 | 72,195.74 | 91.2% | 90.8% |
| 2020 | 25 | 172 | 4,383.20 | 7.0% | 6.4% |
| 2021 | 12 | 21 | 469.49 | 0.2% | 0.2% |
| 2022 | 14 | 32 | 418.96 | 0.1% | 0.1% |
| 2023 | 79 | 216 | 21,826.99 | 1.1% | 4.1% |
| 2024 | 65 | 465 | 41,519.19 | 2.3% | 7.4% |
| 2025 | 161 | 1,363 | 44,884.11 | 3.9% | 4.9% |
| 2026 | 5 | 6 | 504.32 | 0.0% | 0.1% |
| All | 831 | 8,187 | 262,418.33 | 6.0% | 7.2% |

Undated events are outside the booking curve and pace figures. Before 2020 that is nearly everything (spec §9,
confirmed). In 2023-2024 undated events carry far more S&S per seat than dated ones, which suggests private
bookings or non-class products sold as event tickets; not established.

### Gift cards sold in the archive

| Year | Lines | Orders | Amount (realized) |
|---|---|---|---|
| 2016 | 5 | 5 | 376.25 |
| 2017 | 9 | 9 | 665.00 |
| 2018 | 16 | 16 | 1,322.00 |
| 2019 | 19 | 19 | 1,715.00 |
| 2020 | 11 | 11 | 900.00 |
| 2021 | 43 | 43 | 3,810.00 |
| 2022 | 114 | 112 | 10,641.00 |
| 2023 | 110 | 110 | 6,130.00 |
| 2024 | 69 | 69 | 5,958.00 |
| 2025 | 81 | 81 | 7,186.00 |
| 2026 | 30 | 30 | 2,495.00 |
| All | 507 | 505 | 41,198.25 |

Gift card lines are not bookings and carry no ticket economics. How legacy gift cards were redeemed is not
established: the archive has no redemption record and no legacy order records a gift card applied.

## Not yet validated

- Bronco order economics on real data. The order-level discount and service fee allocation are proven by unit
  tests only.
- How money follows a transfer on the new platform.
- Peer benchmarks on real data (no metros loaded).
- Contribution after ad spend on real data (no spend loaded).
- The hourly job's cost with the economics models (`core_stripe_transactions` to `core_bookings`) in the hourly build.
- The dispute figures above against Stripe by hand: they are measured, not hand-checked.
- Chains of more than five transfers (none exist today).
- Private and corporate event revenue: no model (see "Stripe charges with no order").

## Known limits

- **Fixed 2026-09-30: a refunded-status order with a lost dispute was deducted twice.** When a legacy
  order's status is `refunded` but Stripe holds no refund for it, each item refunded its own realized revenue
  (the status fallback), and a lost dispute on the same order deducted the money again. The fallback now
  refunds `greatest(realized_revenue - disputed_amount, 0)` per item, and the item stays cancelled. The one
  order affected, woo-238645 (69.00, lost chargeback of 69.00), went from refunded 69.00, net distributable
  -86.30, S&S share -34.52 to refunded 0.00, net -17.30 (Stripe's fee only), S&S share -6.92. Legacy refunded
  money fell by 69.00 and net distributable rose by 69.00.
- **Partially refunded multi-seat legacy bookings still count every seat.** A legacy booking has no ticket
  status, so it gives up its seats only when its refund reaches its whole realized revenue; a partial refund
  of a two-seat line leaves both seats counted.
- **`has_ad_spend_data` reads partial coverage as complete.** It is true when any platform has spend on a
  day of the selling window, so a day with Meta spend loaded and Google spend missing counts as covered.
- **The legacy surrogate customer key does not conceal the account id.** `woo-cust-<hash>` is a hash of the
  WooCommerce customer id, a small integer; anyone who can enumerate ids can recover which account a key
  belongs to.

## Stripe in the daily job

The Stripe history is loaded and its watermark set, so `infra/setup.sh` and `jobs/entrypoint.sh` now default
the daily job's `SOURCES` to `cms,stripe,gsc,spend`, which loads Stripe incrementally. A missing watermark
makes the Stripe steps fail loudly (`no Stripe watermark for <entity>: run once with --full to load
history`) rather than reload the whole account history; the history load is a deliberate one-off,
`python -m loaders run --sources stripe --full`. No daily job is deployed yet: `infra/setup.sh` has never
been run (`docs/handoff.md`), so the job it will create starts with `SOURCES=cms,stripe,gsc,spend`.
