# Economic truth layer — design addendum

**Date:** 2026-09-27
**Status:** design approved in conversation, awaiting written review
**Extends:** `2026-09-26-analytics-pipeline-design.md` (the "base spec"). Where the two disagree, this document wins.
**Repo:** `sns-analytics`. No further change to the CMS export API is needed.

## 1. Purpose

This repo is the first deployment of FlockAI, a revenue-intelligence venture for businesses that sell scheduled, perishable experiences. Sip & Script is the design partner. The venture brief of 2026-09-26 sets the first milestone:

> Select any sufficiently supported historical Sip & Script event, in either platform era, and answer what happened: what, where, when, who taught it, capacity, price, when tickets sold, how fast it filled, whether it sold out, gross revenue, payment-processing cost, distributable revenue, S&S's 40% share, supporting ad spend, estimated S&S contribution, and how that compares with similar events.

The base spec delivers trusted orders, revenue and paid-media reporting. It does not compute the revenue split, contribution, a booking curve, or a customer table, and its legacy customer identity does not join to the new platform. This addendum adds those. The optimisation target everywhere is **incremental S&S contribution**, not gross revenue, ROAS or utilisation.

Backlog items covered: DATA-003, ECON-001, MODEL-001 (completion), MODEL-002 (completion), MODEL-003. Out of scope: the descriptive analyses (ANALYSIS-001..003), the Opportunity register, forecasting, any UI, Klaviyo.

## 2. Economics rules (confirmed by the operator, 2026-09-26)

1. The 60/40 split applies **after** Stripe fees.
2. Service fees are part of the split.
3. The split is on final realized revenue: discounts and refunds reduce it.
4. Instructors pay materials (about $6 per student) from their 60%. Materials are **never** subtracted from S&S contribution.
5. S&S pays 100% of advertising.
6. The 60/40 rule is assumed to hold for the whole legacy era. No historical payout records are used.
7. Google Ads is live (relaunched 2026-09-25). Meta is the main paid channel.
8. The legacy WooCommerce site and the new platform have always used the same Stripe account.

Definitions, per ticket booking:

```
realized_revenue       = ticket line value + allocated service fee − allocated discount
net_distributable      = realized_revenue − refunded_amount − disputed_amount − processing_fee
sns_share              = 0.40 × net_distributable
instructor_share       = 0.60 × net_distributable
sns_contribution       = sns_share − allocated_ad_spend        (event level and above)
```

The shares are dbt variables `sns_share_rate: 0.40` and `instructor_share_rate: 0.60`.

`disputed_amount` (added 2026-09-29) is the money Stripe took back through chargebacks the business lost, net of reversals. It is not distributed. A chargeback does not vacate a seat. A refund that failed returns the money and reduces the refunded amount.

**Stated assumptions, to be validated against a hand-worked payout in ECON-001:**

- A fully refunded booking has `net_distributable = −processing_fee`, because Stripe keeps its fee on refunds. The loss is split 60/40 like any other amount.
- Dispute fees count as processing fees on the disputed order.
- A gift card applied to a ticket order is a payment method, not a discount. The booking keeps its full realized revenue. Gift-card **purchase** orders are not bookings and carry no ticket economics, which avoids counting the same money twice.
- A ticket order paid entirely by gift card has no Stripe charge and a processing fee of zero.

## 3. What the data supports (verified 2026-09-27 against BigQuery)

| Fact | Value |
|---|---|
| Legacy orders in `sipandscript_new_ds.orders` | 112,841, from 2016-09-27 to 2026-06-19 |
| Legacy orders with no customer id (guest checkout) | 40,127 (36%) |
| Customer email in the archive | none (no email column on orders) |
| Legacy ticket products | 17,404 across 17,103 events; price always present; capacity missing or zero on 1,236 |
| Events with more than one ticket product | 265 |
| Legacy events table | 15,395 rows, starts 2020-02; 1,035 have no venue |
| Payment-processing fees in the archive | none |

Ticketed legacy events by the year the ticket product was created:

| Year | Ticketed events | Present in archive events table | Seats sold | Sold out |
|---|---|---|---|---|
| 2016–2018 | 183 | 0 | 3,123 | 68 |
| 2019 | 362 | 27 | 3,449 | 49 |
| 2020 | 864 | 742 | 2,463 | 96 |
| 2021 | 1,160 | 1,064 | 11,156 | 259 |
| 2022 | 3,275 | 2,973 | 31,567 | 1,073 |
| 2023 | 2,732 | 2,572 | 20,354 | 814 |
| 2024 | 2,724 | 2,346 | 21,898 | 817 |
| 2025 | 3,761 | 3,438 | 37,685 | 1,252 |
| 2026 | 2,042 | 1,975 | 13,959 | 430 |

Consequences:

- Capacity, price, venue, instructor and sale timestamps are reconstructible for the legacy era from 2020 onward for about 90% of events. Events before 2020 mostly lack an event date in the archive and are usable only if the CMS import carries them.
- Legacy identity and legacy fees cannot come from the archive. Both come from Stripe (§4), with the CMS's imported WordPress orders as the second identity source.

## 4. Stripe loader changes

The loader in `loaders/stripe_loader.py` is already implemented and has not yet run against production. Three changes.

### 4.1 Full-history backfill

`BACKFILL_FROM` becomes `None`: a full load omits the `created` filter and pages the whole account history. Incremental behaviour is unchanged.

### 4.2 No personal or card data at rest

The current loader stores each object exactly as received with `source` expanded. A charge carries billing name, email, phone, address and card details, and the WooCommerce gateway also writes customer name and email into `metadata`. That breaks the base spec's no-PII rule.

A new module `loaders/stripe_sanitize.py` exposes `sanitize(entity, obj) -> dict`. It builds the stored payload from an **allowlist**; anything not listed is dropped.

| Object | Fields kept |
|---|---|
| balance transaction | id, object, type, reporting_category, created, available_on, amount, fee, net, currency, fee_details (type, amount), source |
| charge (as `source`) | id, object, amount, amount_captured, amount_refunded, created, currency, status, paid, refunded, disputed, payment_intent, metadata (allowlisted keys), order_ref, customer_hash |
| refund | id, object, amount, created, currency, status, reason, charge, payment_intent, metadata (allowlisted keys) |
| dispute | id, object, amount, created, currency, status, reason, charge, payment_intent |
| payout | id, object, amount, created, arrival_date, currency, status, type, method |

- Metadata allowlist, confirmed against live charges on 2026-09-27 (§4.5): bronco keys `CheckoutSessionKey`, `OrderNumber`, `EventKey`, `TicketCount`, `AdHocChargeGuid`, `Type`; legacy key `order_id`. (The legacy `order_key` was kept at first and removed on 2026-09-29: nothing reads it, and with the order id it was a credential on the legacy site.) Everything else is dropped, including `customer_email`, `customer_name`, `Customer Email`, `Customer Name`, `signature`, `Summary`, `EventName`, `Venue`, and the integer `OrderId` and `CheckoutSessionId` (database ids never enter the warehouse).
- `order_ref` is the order number parsed from the charge `description` with the pattern `Order #?(\d+)`. The description itself is not stored.
- `customer_hash` is `sha256(lower(trim(email)))` in hex, the same rule the CMS uses. The email is taken from the first of `billing_details.email`, `receipt_email`, metadata `customer_email`, metadata `Customer Email`. It is null when none exists. The email is never written, logged or included in an exception message.

`RawRow` payloads are built from `sanitize(...)` output only. The raw table contract wording in the base spec §4 changes from "the row exactly as received" to "the row as received, after source-specific sanitising".

### 4.3 Tests

- A fixture charge containing an email, name, phone, address, card block and PII metadata produces a payload in which none of those values appear. The test searches the serialised payload for each sentinel string.
- The hash of `" Test@Example.com "` equals the hash of `"test@example.com"` and equals the value the CMS produces for the same address (fixed vector in both repos).
- A full load sends no `created` filter.
- An object type or field not in the allowlist is dropped, not passed through.

### 4.4 The key

One restricted, read-only key for the single Stripe account, with read access to balance transactions, charges, payment intents, refunds, disputes and payouts, and nothing else. It lives in Secret Manager as `stripe-restricted-key` for the job and in a git-ignored local environment for laptop runs. It is never committed or pasted into a document.

### 4.5 Live verification (2026-09-27, read-only, one sampled week per period)

| Period | Succeeded charges | Archive orders matched to a charge | Amounts agree | Email available | Order id found in |
|---|---|---|---|---|---|
| 2017-10 | 14 | 14 of 14 | 14 of 14 | 13 of 14, in metadata only | description |
| 2019-10 | 34 | 34 of 34 | 34 of 34 | all | metadata `order_id` |
| 2021-10 | 273 | 273 of 273 | 273 of 273 | all | metadata `order_id` |
| 2023-10 | 265 | 265 of 265 | 264 of 265 | all | metadata `order_id` |
| 2025-10 | 466 | 464 of 464 | 464 of 464 | all | metadata `order_id` |
| 2026-05 | 366 | 366 of 366 | 366 of 366 | all | metadata `order_id` |
| 2026-07 (bronco) | 492 | n/a | n/a | all | metadata `CheckoutSessionKey`, `OrderNumber` |
| 2026-09 (bronco) | 431 | n/a | n/a | all | metadata `CheckoutSessionKey`, `OrderNumber` |

- Stripe history starts in 2016, the same year as the archive. Every sampled legacy order was paid through Stripe; no other gateway appeared.
- Bronco charges carry **no order GUID**. The base plan's staging model looks for `OrderGuid` and would match nothing. The join keys that exist on both sides are `CheckoutSessionKey` (a GUID, exported on CMS orders) and `OrderNumber`.
- About 1% of bronco charges are ad hoc charges with `AdHocChargeGuid` and no order. They are not bookings.
- Refunds carry no metadata and always carry their charge id, so they resolve through the charge.
- Balance transactions of type `stripe_fee` have no expandable source and belong to no order. They are account-level costs, excluded from booking fees.
- Observed fee on recent charges is 3.17% of the charged amount, all of type `stripe_fee`.

## 5. `platform_era`

`pre_launch` is removed everywhere and replaced by `platform_era STRING NOT NULL` with values `legacy_event_tickets` and `bronco`. The boundary is the dbt variable `launch_date` = 2026-06-19, the last day the archive received data. The brief's 2026-06-21 is the public launch; 06-19 is the data boundary.

| Table | Rule |
|---|---|
| orders, order items, bookings, tickets, refunds | era of the sale: `woocommerce` source → `legacy_event_tickets`, `webapp` → `bronco` |
| events, event economics, event daily | era in which the event took place: `event_date < launch_date` → legacy |
| sessions | era of the session date |
| customers | `first_era` and `eras_seen` (array) |
| marts | carried as a grouping column; no mart aggregates across eras without it |

An event that took place after the boundary can hold bookings from both eras. That is correct and is why bookings and events carry the column independently. The `ops.date_flags` seed for 2026-06-19..22 (`unreliable_ga4`) is unchanged.

## 6. Core model additions and changes

### 6.1 `core.events` — add legacy-only events

Today `core.events` contains only events exported by the CMS. It becomes a union:

1. CMS events (unchanged), key `event_key` = CMS GUID.
2. Legacy events that no CMS event references through `wordpress_source_id`, key `woo-ev-<id>`. Built from ticket products grouped by `tribe_wooticket_for_event`, joined to the archive's events, venues and organizers where present.

For CMS events that came from WordPress, capacity and price fall back to the archive when the CMS value is null. Legacy capacity is the **sum** of `ticket_capacity` over the event's ticket products; legacy price is the seat-weighted average line price, falling back to `regular_price`. New columns: `platform_era`, `capacity_source` (`cms` | `woo_products` | `none`), `has_event_date`.

Legacy venues and instructors that the CMS does not hold get keys `woo-venue-<id>` and `woo-org-<id>` in `core.venues` and `core.instructors`. The organizer email column in the archive is never selected.

### 6.2 `core.customer_identity` — order to customer bridge

Grain: one row per order. Columns: `order_key`, `customer_hash`, `identity_source`.

Resolution order, first match wins:

| Priority | Applies to | Source | `identity_source` |
|---|---|---|---|
| 1 | bronco orders | `customerHash` on the CMS order | `cms` |
| 2 | legacy orders | hash on the matched Stripe charge (§6.3) | `stripe` |
| 3 | legacy orders | CMS order with `source = 'wordpressImport'` and the same `wordpressOrderId` | `cms_import` |
| 4 | legacy orders with a WooCommerce customer id | the most frequent hash resolved for that customer id's other orders | `woo_propagated` |
| 5 | legacy orders with a WooCommerce customer id, still unresolved | surrogate `woo-cust-<id>` | `woo_surrogate` |
| 6 | everything else | null | `unresolved` |

`core.orders.customer_hash` is taken from this bridge and `is_first_order` is computed over it. Imported WordPress orders stay excluded from revenue, as in the base spec; they are used only as an identity source. A dbt test reports resolution coverage by era and year and warns below 98% for 2019 onward.

### 6.3 `core.stripe_transactions` — order matching

`order_key` is resolved in this order: the CMS order whose `checkout_session_key` equals metadata `CheckoutSessionKey`; else the CMS order whose `order_number` equals metadata `OrderNumber`; else `woo-` + metadata `order_id`; else `woo-` + `order_ref`. New columns: `customer_hash`, `match_method` (`checkout_session` | `order_number` | `woo_metadata` | `woo_description` | `adhoc` | `none`). Refund and dispute transactions inherit the order of their charge through the charge id. The base plan's `OrderGuid` lookup is removed.

### 6.4 `core.bookings` — the economics fact

Grain: one ticket order item, that is order × event. Gift-card, materials and other items are excluded.

| Column | Meaning |
|---|---|
| booking_key | the order item key |
| order_key, event_key, customer_hash | foreign keys |
| purchased_at, purchase_date | the order's paid time (created time if unpaid is null), UTC and New York date |
| days_before_event | event date − purchase date |
| seats | quantity |
| list_value | quantity × unit price |
| discount, service_fee | order-level amounts allocated pro rata by line total across **all** items on the order |
| realized_revenue | §2 |
| refunded_amount | bronco: completed refunds from the CMS. legacy: matched Stripe refunds; else the full line when the order status is `refunded`. Allocated pro rata by line total |
| processing_fee | sum of Stripe fees on the order's charge, refund and dispute transactions, allocated pro rata by line total |
| fee_source | `actual` (matched in Stripe) \| `estimated` \| `none` (no card payment) |
| net_distributable, sns_share, instructor_share | §2 |
| platform_era | era of the sale |

The estimate applies only to orders with no Stripe match: `realized_revenue × legacy_fee_rate + legacy_fee_fixed` per order, with dbt variables `legacy_fee_rate: 0.029` and `legacy_fee_fixed: 0.30`. After the first full load the variables are reset to the observed ratio for matched legacy orders. Given the match rates in §4.5 the estimate is expected to apply to very few orders.

For the legacy era the WooCommerce line `total` is already net of discounts, so `discount` is `subtotal − total` and there is no service fee.

### 6.5 `core.event_daily` — the booking curve

Grain: event × calendar day, for events with `has_event_date`. The range runs from the earlier of the first sale and 60 days before the event, to the event date.

Columns: `event_key`, `snapshot_date`, `days_until_event`, `capacity`, `seats_sold_that_day`, `cumulative_seats`, `remaining_capacity`, `pct_sold`, `cumulative_realized_revenue`, `cumulative_sns_share`, `ad_spend_that_day`, `cumulative_ad_spend`, `platform_era`.

Seats are counted net of fully refunded bookings, on the purchase date. Capacity is the final recorded capacity; historical capacity changes are not reconstructible and `pct_sold` is capped at 1.

**Ad spend allocation.** This is a stated allocation convention, not attribution and not a measure of incrementality. Each metro-day of spend in `core.ad_spend` is divided among the events in that metro that sold seats that day, pro rata by seats sold. Spend with no metro is divided among all events that sold seats that day. Spend on a day when no eligible event sold a seat is left unallocated and reported in `ops.unallocated_ad_spend` (date, platform, metro_key, spend). A test asserts allocated plus unallocated equals total spend per day.

### 6.6 `core.event_economics` — one row per event

Dimensions: `event_key`, title, `event_date`, `start_at`, weekday, month, season, `venue_key`, `metro_key`, `instructor_key`, category, `event_type`, theme, `capacity`, `ticket_price`, `platform_era`.

Outcomes: `seats_sold`, `bookings`, `customers`, `utilisation`, `utilisation_band` (`<40`, `40-60`, `60-80`, `80-95`, `95-100`), `sold_out`, `realized_revenue`, `refunded_amount`, `processing_fee`, `fee_actual_share`, `net_distributable`, `sns_share`, `instructor_share`, `instructor_materials_estimate` (seats × `materials_per_seat`, variable default 6.00, informational only), `allocated_ad_spend`, `has_ad_spend_data`, `sns_contribution_before_ads`, `sns_contribution`, `contribution_per_available_seat`, `contribution_per_sold_seat`.

Pace: `first_sale_days_before`, `days_before_at_25pct`, `days_before_at_50pct`, `days_before_at_75pct`, `days_before_at_sellout`. Each is the `days_until_event` of the first `core.event_daily` row at or above the threshold, and null if never reached.

`has_ad_spend_data` is true when `core.ad_spend` holds any row inside the event's selling window. When false, `allocated_ad_spend` is null rather than zero and `sns_contribution` is null, so missing spend history is never read as free demand.

### 6.7 `core.customers` — one row per resolved customer

Grain: `customer_hash`, excluding unresolved orders. Columns: `first_purchase_date`, `most_recent_purchase_date`, `first_era`, `eras_seen`, `lifetime_orders`, `lifetime_events`, `lifetime_seats`, `lifetime_realized_revenue`, `lifetime_sns_share`, `home_metro_key` (the metro of most attended events, ties to the most recent), `first_order_channel` (from `core.session_orders` where a session matched), `is_repeat`, `days_first_to_second_purchase`, `is_surrogate` (true for `woo-cust-` keys).

### 6.8 Transferred seats (added 2026-09-28)

Confirmed by the operator on 2026-09-28: the legacy site moved a seat to another event by creating a new order with a total of zero, one per seat, whose parent is the original paid order. Transfers are common. **The instructor who teaches the class attended earns the money**, so the seat and its money follow the transfer.

Measured in the archive (all years): 7,773 transfer orders carrying 7,773 seats; every parent exists; 7,486 point directly at a paid order, 251 reach one through a chain of two or three transfers, 36 never reach a paid order; 260 paid orders have more transfer seats than seats bought (a seat moved more than once, each move pointing at the original order); 18 parents hold tickets for more than one event; the price per seat differs between the original and the new event for 1,173 parents.

Without this rule the model counts the money twice (on the original event through the payment and on the new event through the transfer order's line value) and leaves the seat on the original event.

**Definitions**

- A **transfer order** is a legacy order that counts as paid by status, has a total of zero, has a parent order, and carries at least one ticket line with value.
- Its **root** is the first ancestor with a total above zero, reached by following parents through other transfer orders, at most five steps. A transfer order with no such ancestor has no root.
- A transfer order that is the parent of another transfer order is **superseded**: its seat moved on again. For each root, its remaining transfer orders of any depth are ranked latest first. Seats are **held** by the latest of them up to the number of ticket seats the root bought. Earlier ones beyond that number are also superseded.
- When the root has no ticket lines (its money sits on other products), its transfers hold their seats with no money.

**Rules**

1. A held seat counts at the transfer order's event, from the transfer order's date. A superseded transfer holds no seat and no money.
2. The root's ticket lines give up the held seats, taking them from its lines in order of line key. A root line's seats become the seats bought less the seats given up.
3. Money follows the seat at the price actually paid: for each seat given up, the root line's realized revenue, refund, processing fee, net distributable and both shares, each divided by the seats that line bought, move to the transfer booking. The transfer order's own line value is not revenue.
4. The transfer booking takes the root's `fee_source`.
5. A transfer booking is cancelled when its moved refund reaches its moved realized revenue, or when the transfer order's own status is refunded.
6. Money is conserved: for every root, the realized revenue, refunds and fees of the root's lines plus those of its transfer bookings equal what the root's lines carried before any transfer.
7. A transfer order belongs to the root's customer. It is not a purchase: it never counts as an order, a first order or a repeat purchase, and it is excluded from order, ticket-order and seat counts in the KPI mart.
8. A transfer order with no root, and a zero-total order with ticket value and no parent (332 orders, $32,154), keep their line value as realized revenue with no fee, as before. Their nature is unknown; they are labelled so they can be excluded.
9. The new platform records transfers on tickets (`transferredFromTicketKey`, status `Transferred`). Its seat rule already follows ticket status. How its money follows a transfer is decided when its data is loaded.

**Columns**

- `core_order_item_economics` and `core_bookings`: `booking_kind` (`purchase` | `transfer_in` | `transfer_superseded` | `unpaid_zero_total`), `seats_purchased`, `seats_transferred_out`, `transfer_root_order_key`.
- `core_orders`: `is_transfer`, `transfer_root_order_key`.
- `core_customer_identity.identity_source` gains the value `transfer_parent`.

**Acquisition views follow the purchase (added 2026-09-29).** In `mart_daily_kpis` and `mart_paid_performance`, a transferred seat's money is reported on the original order: its date, channel, metro and campaign. Event, instructor and customer views report it on the class attended.

**Known limit.** The original event's booking curve shows the seats that stayed, from the original purchase date. It does not show a seat as sold and later released.

## 7. Marts

- `mart.daily_kpis`, `mart.paid_performance`, `mart.orders_reconciliation`: `pre_launch` → `platform_era`.
- `mart.daily_kpis` adds `net_distributable` and `sns_share`.
- `mart.paid_performance` adds `sns_share` and `sns_contribution` (= `sns_share − spend`). ROAS stays for reference; contribution is the decision column.
- `mart.orders_reconciliation` now covers both eras. The 1% variance flag applies to the bronco era; the legacy era reports match rate instead.
- New `mart.event_performance`: `core.event_economics` plus peer benchmarks. The peer group is the same metro, category and weekday class (weekday or weekend) among events in the 365 days before the event, with at least 5 peers. Columns added: `peer_count`, `peer_median_utilisation`, `peer_median_days_before_at_50pct`, `peer_median_contribution_per_available_seat`, `utilisation_vs_peers`, `contribution_per_seat_vs_peers`. This table, joined to `core.event_daily`, answers every question in the milestone in §1.

## 8. Tests

| Test | Asserts |
|---|---|
| shares sum | `sns_share + instructor_share = net_distributable` within one cent, every booking |
| fee source | `estimated` never appears on a bronco booking |
| allocation conserves money | order-level discount, service fee, refund and fee each equal the sum of their allocations across the order's items |
| curve closes | the event-date row of `core.event_daily` has `cumulative_seats = core.event_economics.seats_sold` |
| spend conserves | allocated + unallocated ad spend = total, per day |
| era values | `platform_era` accepted values and not null on every core and mart table |
| identity coverage | warn when resolved share of orders is below 98% for any year from 2019 |
| worked order | one real bronco order, chosen in ECON-001 and checked by hand against Stripe, reproduces its `processing_fee`, `net_distributable` and `sns_share` exactly (pinned by order key, amounts only, no personal data) |
| worked event | one real event reproduces seats, realized revenue and sell-through dates checked by hand |
| existing pinned facts | the two base-spec pinned tests keep passing |

## 9. Known limits

- Events from before 2020 mostly have no event date and drop out of the booking curve unless the CMS holds them.
- Capacity is final capacity. A venue change or capacity increase mid-sale is invisible.
- Legacy partial refunds are known only where the Stripe refund matches the order.
- Ad spend before the Google Ads transfer backfill window and before any Meta export is dropped has no data. Contribution is null there, not inflated.
- Payments taken outside Stripe, if any exist, keep estimated fees and rely on the CMS import for identity. None appeared in the sampled weeks; the first full load measures the true number.
- Charges from 2016 to 2018 hold the email only in metadata and the order id only in the description. Both are handled, but this period has the weakest identity coverage.
- Identity is deterministic on email only. One person with two emails is two customers.

## 10. Success criteria

1. For any event with an event date, one query over `mart.event_performance` and `core.event_daily` answers every question in §1.
2. At least 98% of card-paid bookings in both eras carry `fee_source = 'actual'`.
3. At least 98% of orders from 2019 onward resolve to a customer hash, and customers who bought in both eras appear as one row in `core.customers`.
4. No email address, name, phone number, street address or card detail exists in any dataset the pipeline writes. Verified by a scan of `raw_stripe` payloads for `@` after the first load.
5. The worked order and worked event tests pass.

## 11. Sequencing

Base-plan tasks 1–9 (loaders, CLI, infra script) are implemented. This addendum is delivered as its own plan, in this order:

1. Stripe sanitiser, full-history backfill, tests. Must merge before the first production Stripe load.
2. Amend base-plan tasks 10–14 in place: `platform_era`, the identity bridge, legacy-only events, Stripe order matching.
3. New models: `core.bookings`, `core.event_daily`, `core.event_economics`, `core.customers`, `mart.event_performance`.
4. ECON-001 validation: pick and hand-check the worked order and event, reset the fee variables, record coverage numbers.

## 12. Decisions log

| Decision | Choice | Why |
|---|---|---|
| Era column | `platform_era` replaces `pre_launch` | the brief's canonical name; nothing built on the old one yet |
| Era boundary | 2026-06-19 | last day the archive received data |
| Legacy fees | actual from Stripe full history; estimate only when unmatched | same Stripe account throughout; estimates stay visible through `fee_source` |
| Legacy identity | hash from Stripe first, CMS import second | the archive holds no email and 36% of legacy orders are guest checkouts |
| Bronco Stripe join | `CheckoutSessionKey`, then `OrderNumber` | live charges carry no order GUID; these two exist on both sides |
| PII in Stripe payloads | allowlist sanitiser in the loader | a blocklist fails open when Stripe adds a field |
| Booking grain | ticket order item | matches the brief's customer × order × event grain and allocates cleanly |
| Ad spend on events | pro rata by seats sold per metro-day, remainder reported unallocated | simple, conserves money, and is labelled as allocation rather than attribution |
| Missing ad spend | null contribution, not zero spend | avoids overstating contribution for periods without spend data |
| Materials | reported as an instructor-side estimate only | instructors pay materials from their share |
