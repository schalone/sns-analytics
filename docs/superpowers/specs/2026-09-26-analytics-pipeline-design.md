# Sip & Script analytics pipeline — design

**Date:** 2026-09-26
**Status:** approved in conversation, awaiting written review
**Repo:** `sns-analytics` (this repo). One companion change lands in `sipandscript-sns.webapp.cms` (the export API, §6).

## 1. Purpose

Every analysis so far (conversion investigation, SEO recovery eval, search query review, Google Ads launch) was a one-off script against GA4, Search Console, Stripe CSV exports and Klaviyo. Each one re-derived the same corrections (purchase double-fire, phantom `accounts.google.com` referral, two Search Console properties, the 6/19 cutover discontinuity) and none of the results persisted.

This pipeline lands every source in BigQuery on a schedule, applies each correction once in a tested model, and exposes clean tables that serve four decisions on one foundation:

1. **Paid acquisition ROI** — tie Google Ads, Paid Social and Pinterest spend to real orders per metro.
2. **Trusted top-line reporting** — one source of truth for orders, revenue, sessions, CVR and AOV.
3. **Event supply and demand** — which cities, venues, dates and prices sell out or under-fill.
4. **Funnel and marketing flows** — where checkout and Klaviyo flows leak.

Phase one (this spec) builds the platform and delivers decisions 1 and 2. Decisions 3 and 4 follow as short specs on the same foundation (§12).

**Consumers:** Claude ad hoc queries via the BigQuery MCP, Looker Studio dashboards, and the existing Slack morning brief repointed at the warehouse.

## 2. What already exists (verified 2026-09-26 via the BigQuery, Dataform, Scheduler and Run APIs)

GCP project `sipandscript`. All live datasets are in the **US multi-region**.

| Asset | State | Use in this design |
|---|---|---|
| `analytics_313669961` — GA4 raw export | Daily tables `events_20220503` … `events_20260924` plus intraday. Full history, current. | **Primary GA4 source.** |
| `sipandscript_new_ds` — WooCommerce mirror | orders (112,841 rows, 2016-09 → 2026-06-19), order_line_items, products, events, venues, organizers. Fed by Cloud Function `function-1` on Pub/Sub topic `sync_wp_to_bigquery_topic`; nothing has written since the cutover. | **Read-only historical archive** for pre-launch orders and events. |
| Superform GA4Dataform (Dataform repo `superform_analytics_313669961`, us-central1) | Licensed package v9, runs 10:00 UTC daily, outputs `superform_outputs_313669961.ga4_events/ga4_sessions`. | **Not depended on.** Left running untouched. |
| Cloud Run job `sns-ads-sync` (us-east1) + schedulers `sns-ads-sync-weekly`, `sns-ga-report-daily` (12:15 UTC) | Google Ads radius sync and the Slack morning brief (`scripts/google-ads/` in the CMS repo). | Pattern reused. Brief repointed at `mart` in phase one. |
| Service accounts `ads-builder@`, `ga4-reader@` | Ads API access, GA4 Data API read. | Not reused; a new `sns-analytics@` SA is created (§9). |
| Datasets `events` (us-east1, 2022), `streaming_s3`, buckets `sipandscript_data`, `sipscript_orders`, `sipandscript_stream` | 2022 experiments, empty or stale. | Ignored. |

Not yet in BigQuery: Search Console, Google Ads spend, Stripe, Klaviyo, the new site's own orders/tickets/events.

## 3. Architecture

```
Google-managed exports           Python loaders (Cloud Run job)         dbt (same job)
─────────────────────            ──────────────────────────────         ─────────────────────
GA4 raw export ──────┐           CMS export API  ──► raw_cms            staging (views)
Google Ads transfer ─┼─► BigQuery Stripe API     ──► raw_stripe   ──►   core (tables)      ──► mart (tables)
                     │           Search Console  ──► raw_gsc             ops (state, run log)
WooCommerce archive ─┘           Spend CSV drop  ──► raw_spend
                                                                         consumers: Claude (BigQuery MCP), Looker Studio, Slack brief
```

**Repo layout**

```
sns-analytics/
  loaders/            Python package. One module per source + CLI: `python -m loaders <source> [--full]`
    common/           BigQuery writer, watermark state, secrets, logging, Slack status
    cms.py  stripe.py  gsc.py  spend_csv.py
  dbt/                dbt-core project (dbt-bigquery). models/staging, models/core, models/marts, tests, seeds
  jobs/               Dockerfile, entrypoint.sh (loaders → dbt build → status post)
  infra/              setup.sh (idempotent gcloud/bq commands: datasets, SA, IAM, secrets, job, schedules)
  tests/              pytest for loaders (recorded fixtures)
  docs/superpowers/   specs and plans
```

**Runtime**

- Python 3.12, `google-cloud-bigquery`, `google-auth`, `stripe`, `requests`, `dbt-bigquery`. No orchestrator; the entrypoint is sequential and each step is idempotent.
- Cloud Run job `sns-analytics`, us-east1, service account `sns-analytics@sipandscript.iam.gserviceaccount.com`, image built from `jobs/Dockerfile` via `gcloud run jobs deploy --source`.
- Cloud Scheduler (us-east1):
  - `sns-analytics-daily` — `0 11 * * *` UTC: all loaders, then `dbt build`. Runs after the GA4 daily table normally lands and before the 12:15 UTC brief.
  - `sns-analytics-hourly` — `30 * * * *` UTC: CMS loader only, then `dbt build --select tag:hourly` (orders, tickets, daily_kpis).
- Local runs use Application Default Credentials; the same CLI and `dbt build` work from a laptop against the same project.

**Datasets** (all US multi-region, created by `infra/setup.sh`)

| Dataset | Writer | Contents |
|---|---|---|
| `raw_cms`, `raw_stripe`, `raw_gsc`, `raw_spend` | loaders | append-only raw rows (§5) |
| `google_ads` | BigQuery Data Transfer | Google Ads reports for customer 186-395-2460 |
| `ops` | loaders + dbt | `load_state`, `run_log` |
| `staging` | dbt | one view per raw entity, latest row per key, typed and renamed |
| `core` | dbt | cleaned entities (§7) |
| `mart` | dbt | decision tables (§8) |

Existing datasets `analytics_313669961` and `sipandscript_new_ds` are read by dbt sources only.

## 4. Raw table contract

Every loader writes to one table per entity with the same shape:

| Column | Type | Meaning |
|---|---|---|
| `key` | STRING | the entity's stable id (GUID from the CMS, Stripe id, or a composite for report rows) |
| `updated_at` | TIMESTAMP | source-side change time, or the report date for daily metrics |
| `payload` | JSON | the row exactly as received |
| `_loaded_at` | TIMESTAMP | load time |
| `_run_id` | STRING | Cloud Run execution id or `local-<ts>` |

Tables are partitioned by `DATE(_loaded_at)` and clustered by `key`. Loaders only append. Staging views pick the latest `updated_at` per `key` (`QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC, _loaded_at DESC) = 1`), so reloads and overlaps are harmless.

`ops.load_state (source, entity, watermark TIMESTAMP, cursor STRING, updated_at)` holds one row per loader entity. A loader reads its watermark, fetches from `watermark − overlap`, appends, and writes the new watermark only after the append succeeds. `--full` ignores the watermark.

`ops.run_log (run_id, logged_at, step, status, row_count, message)` gets one row per loader entity and per dbt invocation. (`rows` is a reserved word in GoogleSQL, hence `row_count`.)

## 5. Loaders

### 5.1 CMS export (`loaders/cms.py`) — primary source for the business model

Calls the export API in §6. Facts (`orders`, `order_items`, `tickets`, `refunds`, `promo_redemptions`, `gift_cards`, `gift_card_transactions`, `checkout_sessions`) load incrementally by `updatedAt` with a 2-hour overlap. Dimensions (`events`, `venues`, `metros`, `instructors`) are small (≈4k events) and load in full on every daily run, incrementally on hourly runs. Initial backfill is `--full` for everything.

### 5.2 Stripe (`loaders/stripe.py`) — reconciliation and fees, not the order model

Restricted read-only API key (Secret Manager `stripe-restricted-key`). Entities: `balance_transactions` (expanded `source`), `refunds`, `disputes`, `payouts`. Incremental by `created` with a 1-day overlap; backfill from 2026-06-19 (earlier Stripe history belongs to WooCommerce and is already in the archive). Stripe `metadata` on payment intents carries the order GUID and seat counts; it is kept in `payload` for the reconciliation join.

### 5.3 Search Console (`loaders/gsc.py`)

Search Analytics API (`searchanalytics/query`) for both properties, `https://sipandscript.com/` and `https://www.sipandscript.com/`, dimensions `date, page, query` and separately `date, page, device, country`; 25k-row paging; per-day incremental with a 3-day overlap because Search Console restates recent days. Backfill the API's full 16 months. The native Search Console bulk export is not used in phase one: a Cloud project can export only one property and the export has no history, whereas the API covers both properties with backfill.

### 5.4 Spend CSV drop (`loaders/spend_csv.py`) — stopgap for Meta and Pinterest

Bucket `gs://sns-analytics-drop/spend/{meta|pinterest}/*.csv`, standard Ads Manager daily-by-campaign exports. Required columns after header normalisation: `date, campaign_name, spend, impressions, clicks` (extra columns are kept in `payload`). Each file loads once; `ops.load_state` records the object name and generation. Replaced by API loaders in phase two.

### 5.5 Google Ads — no loader

BigQuery Data Transfer Service, Google Ads connector, customer `1863952460`, destination `google_ads`, daily, with the maximum backfill the transfer allows. Set up in `infra/setup.sh`.

## 6. CMS export API (change in `sipandscript-sns.webapp.cms`, separate MR)

One read-only controller, `Controllers/AnalyticsExportController.cs`, route `GET /api/export/{entity}`.

**Auth.** `Authorization: Bearer <token>`; token from config `Analytics:ExportApiKey` (Doppler `Analytics__ExportApiKey`, Secret Manager `cms-export-token` on the pipeline side). Constant-time comparison. If the key is not configured the route returns 404; a missing or wrong token returns 401. No member session, no anti-forgery (machine-to-machine GET).

**Query.** `since=<ISO-8601 UTC>` (rows with `updatedAt >= since`), `cursor=<opaque>` (base64 of `updatedAt|key` of the last row returned), `pageSize` ≤ 1000 (default 500), `full=1` (ignore `since`). Rows are ordered by `updatedAt, key`.

**Response.** `{"entity": "orders", "generatedAt": "...", "items": [...], "nextCursor": "..."|null}`. All money in integer cents, all timestamps ISO-8601 UTC, all identifiers GUIDs. Integer database ids never appear (repo rule). No personal data: no names, emails, phone numbers or street addresses. Customers are identified by `memberKey` and `customerHash` = SHA-256 of the lower-cased, trimmed billing email, which lets the warehouse count and cohort customers without holding the email.

**Entities and fields**

| Entity | Fields |
|---|---|
| `orders` | orderKey, orderNumber, status, createdAt, paidAt, updatedAt, currency, subtotalCents, discountCents, serviceFeeCents, giftCardAmountCents, totalCents, promoCode, affiliateKey, memberKey, customerHash, billingCity, billingState, billingZip, checkoutSessionKey, stripeCheckoutSessionId, source (`webapp` \| `wordpressImport`), wordpressOrderId. (The payment intent id is not stored on orders; Stripe reconciliation joins on the order GUID in Stripe metadata.) |
| `order_items` | orderItemKey, orderKey, checkoutSessionKey (nullable), itemType, ticketKey, giftCardKey, eventKey, quantity, unitPriceCents, lineTotalCents, status, createdAt, updatedAt |
| `tickets` | ticketKey, orderKey (nullable), orderItemKey (nullable), eventKey, status, transferredFromTicketKey, createdAt, updatedAt |
| `refunds` | refundKey, orderKey, ticketKey, amountCents, currency, reason (ALWAYS null), status, stripeRefundId, createdAt, completedAt, updatedAt |
| `promo_redemptions` | redemptionKey, orderKey, checkoutSessionKey (nullable), promoCode, eventKey, orderDiscountCents, status, reservedAt, redeemedAt, updatedAt |
| `gift_cards` | giftCardKey, orderKey, initialCents, balanceCents, currency, status, issuedAt, createdAt, updatedAt |
| `gift_card_transactions` | transactionKey, giftCardKey, orderKey, amountCents, type, createdAt, updatedAt |
| `checkout_sessions` | checkoutSessionKey, status, memberKey, customerHash, orderKey, eventKey, guestCount, createdAt, holdExpiresAt, lastActivityAt, updatedAt |
| `events` | eventKey, title, urlPath, eventDate (`yyyy-MM-dd`, venue-local calendar date), startTime (`HH:mm:ss`, venue-local), endTime (`HH:mm:ss`, venue-local), startAtUtc (ISO-8601 UTC, nullable), endAtUtc (ISO-8601 UTC, nullable), timeZone, venueKey, metroKey, instructorKey, category, eventType, theme (may hold several names joined), status, capacity, ticketPriceCents, isVirtual, noTickets, externalTicketUrl, wordpressSourceId, createdAt, updatedAt |
| `venues` | venueKey, name, city, state, zip, latitude, longitude, metroKey, capacity, timeZone, wordpressSourceId, createdAt, updatedAt |
| `metros` | metroKey, name, slug, urlPath, state, centerPlace, centerLatitude, centerLongitude, radiusMiles, createdAt, updatedAt |
| `instructors` | instructorKey, name, urlPath, city, state, startDate (`yyyy-MM-dd`), noLongerTeaches, wordpressSourceId, createdAt, updatedAt |

Envelope: `entity`, `generatedAt`, `items`, `nextCursor` (opaque token; the loader already treats it as opaque).

`updatedAt` is mandatory on every entity. Orders, order items, tickets, checkout sessions, promo redemptions and gift cards have an `UpdatedAt` column; refunds use `COALESCE(CompletedAt, CreatedAt)`; gift card transactions are immutable and use `CreatedAt`. No schema migration is needed. Umbraco entities use the content `UpdateDate`. `startTime`/`endTime` are time-only per the repo rule; `eventDate` is the date.

**Differences found during implementation.** `ticketTypeKey`, `events.publishedAt`, and the `status` fields on venues/metros/instructors are not exported (content is published-only; `instructors.noLongerTeaches` is provided instead). `orders.billing*` come from the order's shipping columns. `promo_redemptions.orderDiscountCents` is the order's total discount, not a per-redemption amount. `refunds.reason` is never exported because it is admin free text. Event `startTime`/`endTime` are venue-local and `startAtUtc`/`endAtUtc` are the same instants in UTC. Cursors are opaque encrypted tokens bound to their entity. `full` accepts `1`/`0`/`true`/`false`.

Events, venues, metros and instructors are read through the typed Umbraco models (published content only). The export runs inside the app's existing request pipeline; pages are capped so a full backfill of 4k events or 6k orders is a few dozen requests.

**Tests.** Integration tests in the CMS `tests/` project: 404 without config, 401 with a bad token, paging returns every row exactly once, `since` filter, no integer ids or emails in any payload.

## 7. Core model (dbt, `core` dataset)

All money in dollars (`cents / 100`), converted once in staging. Dates in `America/New_York` for business days; timestamps stay UTC.

| Table | Grain | Key columns |
|---|---|---|
| `core.orders` | one paid or refunded order | order_key, source_system (`woocommerce` \| `webapp`), pre_launch, order_number, status, created_at, paid_at, business_date, order_type (`ticket` \| `gift_card` \| `materials` \| `other`), gross_revenue, discount, service_fee, gift_card_applied, refunded_amount, net_revenue, seats, promo_code, affiliate_key, member_key, customer_hash, billing_city, billing_state, billing_zip, billing_metro_key, stripe_payment_intent_id, is_first_order |
| `core.order_items` | one line | order_item_key, order_key, item_type, event_key, quantity, unit_price, line_total |
| `core.tickets` | one ticket | ticket_key, order_key, event_key, status, created_at, updated_at |
| `core.refunds` | one refund | refund_key, order_key, amount, status, created_at |
| `core.events` | one event | event_key, title, url_path, event_date, start_at, end_at, venue_key, metro_key, instructor_key, category, event_type, theme, status, capacity, ticket_price, is_virtual, wordpress_source_id, seats_sold, seats_available |
| `core.venues`, `core.metros`, `core.instructors` | one each | as exported |
| `core.sessions` | one GA4 session | session_key (user_pseudo_id + ga_session_id), user_pseudo_id, session_start_at, session_date, landing_page_path, landing_query_q, source, medium, campaign, default_channel_group, has_gclid, device_category, country, region, city, engaged, page_views, is_phantom_referral, pre_launch |
| `core.session_orders` | one order ↔ one session | order_key, session_key, purchase_event_at; one row per order (earliest purchase event with that transaction_id) |
| `core.ad_spend` | one campaign-day | date, platform (`google` \| `meta` \| `pinterest`), campaign_id, campaign_name, metro_key, spend, impressions, clicks |
| `core.search_daily` | one property-page-query-day | date, property, page_path, query, clicks, impressions, position |
| `core.stripe_transactions` | one balance transaction | txn_id, type, created_at, amount, fee, net, order_key (from metadata), refund_id, payout_id |

**Unifying old and new orders.** Pre-launch rows come from `sipandscript_new_ds.orders` + `order_line_items` + `products` (WooCommerce statuses `completed`/`refunded`; `order_type` from the product: `tribe_wooticket_for_event` → ticket, gift card SKUs → gift_card, else materials). Post-launch rows come from `raw_cms`. CMS rows with `source = 'wordpressImport'` are excluded because the archive already holds them. Old events map to new ones through `wordpress_source_id`.

**Metro for old orders.** WooCommerce orders have no event → metro link that survives; `billing_metro_key` is derived from billing zip/city against `core.metros` centres and radii, and `event_metro_key` is used where the ticket's event maps.

**Corrections, each in one model with a test**

| Correction | Model | Test |
|---|---|---|
| GA4 `purchase` double-fire on `/order-confirmation/` | `core.session_orders` keeps one row per transaction_id | unique(order_key) |
| `accounts.google.com` phantom referral | `core.sessions.is_phantom_referral`; source/medium replaced by the user's previous non-phantom session within 30 minutes, else `direct` | no session with source = accounts.google.com |
| Jun 19–22 tracking blackout | `core.sessions.pre_launch` and a `ops.date_flags` seed marking 2026-06-19..22 `unreliable_ga4`; marts exclude those days from CVR | accepted_values |
| Tickets vs materials vs gift cards | `core.orders.order_type` | not_null, accepted_values |
| Refunds net of gross | `core.orders.net_revenue = gross − refunded` | net ≤ gross, net ≥ 0 |
| Old-site vs new-site GA numbers | `pre_launch` on sessions and orders; marts never aggregate across the flag without grouping by it | dbt test that `mart.daily_kpis` carries `pre_launch` |
| Cents → dollars | staging only | money columns non-negative except refunds |

## 8. Phase one marts (`mart` dataset)

| Table | Grain | Columns | Serves |
|---|---|---|---|
| `mart.daily_kpis` | day × channel_group × metro | business_date, pre_launch, channel_group, metro_key, sessions, engaged_sessions, orders, ticket_orders, seats, gross_revenue, net_revenue, cvr (ticket_orders/sessions), aov, new_customers | Slack brief, Looker overview, YoY |
| `mart.paid_performance` | day × platform × campaign | date, platform, campaign_id, campaign_name, metro_key, spend, impressions, clicks, sessions (Google: via gclid/campaign match on `core.sessions`; Meta/Pinterest: via utm campaign), orders, seats, net_revenue, roas, cpa | Ads budget moves per metro |
| `mart.orders_reconciliation` | day | business_date, cms_orders, cms_net_revenue, stripe_charges, stripe_net, stripe_fees, variance_amount, variance_pct, flagged (\|variance_pct\| > 1%) | trust check; alert |

Definitions: `channel_group` is GA4's default channel grouping after the phantom fix; `cvr` uses ticket orders only; `new_customers` = orders where `is_first_order` across both source systems.

## 9. Access, secrets, IAM

- Service account `sns-analytics@sipandscript.iam.gserviceaccount.com`: BigQuery Data Editor on `raw_*`, `ops`, `staging`, `core`, `mart`; Data Viewer on `analytics_313669961`, `sipandscript_new_ds`, `google_ads`; BigQuery Job User; Secret Manager Secret Accessor on the secrets below; Storage Object Viewer on `sns-analytics-drop`.
- Secrets (Secret Manager): `stripe-restricted-key`, `cms-export-token`, `gsc-oauth` if the Search Console API needs a user credential rather than the SA (the SA is added as a user on both properties first; fallback is a stored refresh token). The existing `slack-ads-sync-bot-token` is reused for status posts.
- Google Ads transfer authorises with a user who has read access on customer 186-395-2460.
- Looker Studio and the BigQuery MCP use the user's own Google identity with Data Viewer on `mart` and `core`.

## 10. Error handling and operations

- Loaders are independent: a failure in one is logged to `ops.run_log` and posted to Slack, the others continue, and `dbt build` still runs on what loaded. Watermarks only advance after a successful append, so the next run resumes.
- `dbt build` failures stop the marts from being rebuilt (tables keep their last good state) and post the failing test names to Slack `#analytics`.
- GA4 lateness: `core.sessions` and `core.session_orders` are incremental with a 3-day lookback so late daily tables are absorbed on the next run.
- Every run posts one line to Slack: `sns-analytics daily OK — cms 412 rows · stripe 388 · gsc 21,530 · dbt 41 models, 118 tests` or the failing steps.
- Cost: a few GB scanned per day; well under $5/month.

## 11. Testing

- **Loaders:** pytest with recorded JSON fixtures per source; tests cover paging, watermark advance, overlap idempotence, and the raw table contract. No live API calls in tests.
- **dbt:** schema tests (unique, not_null, relationships, accepted_values) on every core and mart table plus the correction tests in §7. Two data tests pin known facts from the September investigation so the model can't silently drift: post-launch orders Jun 23–Sep 17 within 1% of 5,328 and net ticket revenue within 1% of $474.1k.
- **CMS export:** integration tests listed in §6.
- **End to end:** `infra/setup.sh` is rerunnable; a `--dry-run` job execution against a throwaway dataset prefix (`DBT_TARGET_SCHEMA_PREFIX`) validates the container before schedules are enabled.

**Success criteria for phase one**

1. `mart.orders_reconciliation` variance under 1% on every day of the last 30.
2. The Slack brief's orders, revenue, sessions and CVR come from `mart.daily_kpis` and match the Stripe dashboard for yesterday.
3. Tickets-only YoY for Jun 23–Sep 17 is computable exactly from `core.orders` across both source systems.
4. `mart.paid_performance` shows spend, orders and ROAS per Google Ads campaign for every day since the 2026-09-25 launch.

## 12. Phases and out of scope

- **Phase one (this spec):** repo, infra, four loaders, Google Ads transfer, CMS export API, core model, three marts, brief repoint, Looker overview page.
- **Phase two — acquisition:** Meta Marketing API and Pinterest Ads API loaders replacing the CSV drop; UTM/gclid/fbclid capture in the site; multi-touch attribution mart.
- **Phase three — supply and demand:** sell-through, lead time, capacity utilisation, price-point marts by metro, venue, weekday and category; feeds the Ads radius sync and metro-page decisions.
- **Phase four — funnel and flows:** Klaviyo loader (events, flow and campaign metrics), GA4 event-level checkout funnel, abandoned-checkout mart.

Out of scope for all phases unless re-decided: Shopify (no reporting access), consent management, replacing Superform, backfilling the dead WooCommerce→BigQuery function.

## 13. Decisions log

| Decision | Choice | Why |
|---|---|---|
| Warehouse | BigQuery, US multi-region | GA4 export and archive already there; existing SAs, Run, Scheduler |
| CMS data path | authenticated export API | no DB exposed; Umbraco content resolved by typed models; ships as a normal release |
| GA4 source | raw export, own sessions model | full history; no paid-license dependency; Superform untouched |
| Transform tool | dbt-core in the same container (chosen over Dataform, 2026-09-26) | one repo and one job so ordering is trivial; runs locally with ADC; schema, data and unit tests; dbt-utils and dbt-ga4 ecosystem. Dataform is native and free but would split transforms into a second scheduled system and lacks unit tests |
| Search Console | API loader for both properties | bulk export is one property per project and has no history |
| Google Ads | native BigQuery transfer | free, no code, backfill |
| Meta / Pinterest spend | CSV drop now, API in phase two | no API access set up yet; don't block ROI reporting on it |
| PII | none in the warehouse; `customer_hash` only | analysis needs counts and cohorts, not identities |
| Orders truth | CMS export primary, Stripe for reconciliation | the app DB is Stripe-backed and carries tickets, events and promo context Stripe lacks |
