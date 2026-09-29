# Google Ads search launch — 2026-09-25

Paid search to regain visibility on the top non-brand terms while the SEO win-back slices reach prod.
Built through the Google Ads API by `scripts/google-ads/build_campaigns.py` (idempotent; `--report` reads back state).

## Why these terms
Search Console, 1 Jul–23 Sep 2026, both properties: "calligraphy classes near me" 5,305 impressions / 859 clicks at
average position 58.8 (was 3.5 in spring); generic "calligraphy class(es)" ~2,100 impressions at position 6–11;
city-named variants (nyc, atlanta, houston, austin, chicago, san antonio, seattle, LA, dallas, dc) ~1,000 impressions.
Brand variants: 5,934 impressions / 3,131 clicks.

## Account
- Customer 186-395-2460 "Sip & Script" (not a manager). Conversion tracking ID AW-18474746935. Auto-tagging on.
- API access: service account `ads-builder@sipandscript.iam.gserviceaccount.com` (Standard user on the account), key
  `~/.config/gcloud/sns-ads-builder-key.json`, config `~/.config/gcloud/sns-google-ads.yaml`. Google Ads API enabled on
  Cloud project `sipandscript`; access level is granted to the project (developer tokens were sunset 2026-09-09).
- Account clean-up done 2026-09-25 (Stephen's call: tickets only, no calls, no directions): empty Performance Max
  "Campaign #1" REMOVED; account-level call asset (603) 921-6205 unlinked; account-level Business Profile location sync
  unlinked (no address/directions on ads). Google-hosted actions "Local actions - Directions" / "Clicks to call" cannot be
  removed or edited via API (MUTATE_NOT_ALLOWED) but their goal categories are non-biddable at account + campaign level.
  Conversion goals: PURCHASE is the only biddable category at account level and on all 18 SNS campaigns
  (BEGIN_CHECKOUT set non-biddable; it still records as a secondary action).

## What was built (created PAUSED; all 18 ENABLED 2026-09-25 after GTM verification)
| Campaign | Budget | Targeting | Ad groups | Keywords | Landing |
|---|---|---|---|---|---|
| SNS \| Search \| Near Me \| {16 metros} | $45/day shared | 40 mi radius (presence), EN | 1 each | 34 each (17 generic × phrase+exact) | /metros/{slug}/ |
| SNS \| Search \| City Named \| National | $15/day | US, EN | 21 (one per metro) | 512 (city aliases × templates) | /metros/{slug}/ |
| SNS \| Search \| Brand | $5/day | US, EN | 1 | 10 | / |
| SNS \| Search \| Near Me \| Rest of US (added later 2026-09-25) | $10/day | 14 radii (Charlotte, S. Florida, Jacksonville, Iowa City, Salt Lake City, Louisville, Lehigh Valley 30 mi, Columbus, Cincinnati + held Houston, Scottsdale, Connecticut, Detroit, Austin), EN | 1 | 34 | /events/ (browser geolocation) |

- Near-me metros: Boston, Bay Area, NYC, Washington DC, Dallas, Los Angeles, Chicago, Nashville, Tampa, Seattle,
  Raleigh-Durham, NH & Maine, San Antonio, Rhode Island, Atlanta, Philadelphia. Held (thin supply ≤13 classes in 40 mi):
  Houston, Scottsdale, Connecticut, Detroit, Austin — they still get city-named ad groups.
- Bidding: Maximize clicks (TARGET_SPEND) with $2.00 CPC ceiling; switch to Maximize conversions after ~30 purchases.
- Networks: Google Search only (no partners, no display). Daily total $75 ≈ $2,280/month (Stephen added $10/day for Rest of US on top of the $2,000 cap).
- Builder gotcha: Google renames non-shared budgets to the campaign name; the builder now looks budgets up by either name (a re-run once created two orphan budgets, removed same day).
- Shared negative list "SNS | Negatives | Calligraphy classes" (45 terms) on all 18 campaigns.
- Sitelinks on every campaign: Private Events, Corporate & Teams, Gift Cards, FAQs.
- RSAs: pinned city headline + 14 shared headlines, 4 descriptions; every claim is on the live metro pages
  (all materials + drink included, beginner friendly, no experience needed, 4.9 rating / 10,000+ students, tickets from $65).
- Conversion actions: "Ticket purchase" (PURCHASE, primary, label `PshgCLq8qIUdELeIuelE`) and
  "Begin checkout" (BEGIN_CHECKOUT, secondary, label `xBweCKO3sIUdELeIuelE`).

## GTM wiring (Stephen)
The site already pushes `{event:'purchase', ecommerce:{transaction_id, value, currency, items}}` and
`{event:'begin_checkout', ecommerce:{…}}` to the dataLayer (`Views/Partials/siteAnalytics.cshtml` `trackGoogle`).
1. Tag **Conversion Linker** — trigger All Pages.
2. Variables (Data Layer Variable, version 2): `DLV - ecommerce.transaction_id`, `DLV - ecommerce.value`, `DLV - ecommerce.currency`.
3. Trigger **Custom Event** `purchase`; trigger **Custom Event** `begin_checkout`.
4. Tag **Google Ads Conversion Tracking**: Conversion ID `18474746935`, label `PshgCLq8qIUdELeIuelE`,
   Value = `{{DLV - ecommerce.value}}`, Currency = `{{DLV - ecommerce.currency}}`,
   **Transaction ID = `{{DLV - ecommerce.transaction_id}}`** (dedups the known order-confirmation double-fire). Trigger: `purchase`.
5. Tag Google Ads Conversion Tracking: label `xBweCKO3sIUdELeIuelE`, no value, trigger `begin_checkout`.
6. Preview on a test order, publish. Ads → Goals → Conversions should show "Ticket purchase" status Recording within a day.

Status 2026-09-25: published and verified from the live gtm.js (container GTM-KZXPLN): Conversion Linker present; purchase
tag maps transaction_id / value / currency to Data Layer Variable macros; begin_checkout tag maps value / currency.
First publish had the three fields as literal text (would have collapsed every order onto one transaction ID) — fixed.

## Launch and cadence
1. GTM published → enable the 18 campaigns in the UI (or `campaign.status = ENABLED` via the API).
2. 48 h: impressions/CTR per campaign, search terms report → add negatives.
3. Weekly: search terms, budget pacing vs $2,000, per-metro CPC; move budget toward metros with purchases.
4. ~30 purchases: switch near-me + city-named to Maximize conversions (then tCPA).
5. Link Google Ads ↔ GA4 (property 313669961) for cross-checking; add `accounts.google.com` to GA4 referral exclusions.

## Weekly radius sync (automated, added 2026-09-25)
`scripts/google-ads/sync_radii.py` runs as Cloud Run job **sns-ads-sync** (project sipandscript, us-east1, service account
ads-builder, no secrets) on Cloud Scheduler **sns-ads-sync-weekly** = Mondays 11:00 UTC (7am EDT / 6am EST). Tests:
`python -m unittest test_sync_radii` in that folder. Redeploy: `gcloud run jobs deploy sns-ads-sync --source scripts/google-ads --region us-east1 --project sipandscript --service-account ads-builder@sipandscript.iam.gserviceaccount.com --set-env-vars STATE_BUCKET=sns-ads-sync`.
Run now: `gcloud run jobs execute sns-ads-sync --region us-east1 --project sipandscript --wait`.

What it does each run: reads metro campaigns + Rest of US radii from the account, pulls all bookable in-person classes
(51 per-state calls to `/api/events/near`, sold-out excluded), then applies Stephen's "if there's inventory, show it" rules:
Rest of US radius with 0 classes → removed; uncovered classes → greedy 40 mi clusters → new radius each; metro campaign with
0 classes → paused + label `sync:paused` (only sync-paused campaigns are ever re-enabled, at ≥1); any radius ≥13 classes for
4 consecutive runs → flagged "ready for a metro page" (never auto-created). Constants at the top of the script.
State: `gs://sns-ads-sync/history.json` (per-key counts, keyed by rounded lat/lng) + `snapshots/YYYY-MM-DD.json`.
Summary → Slack via `SLACK_WEBHOOK_URL` (Secret Manager secret to be attached; until then it only logs).
First run 2026-09-25: 826 classes, +35 radii (San Clemente 22, Denver 14, Jupiter FL 10, Omaha 9, Pittsburgh 8 … down to
1-class towns), Rest of US now 49 radii on $10/day.

## Daily performance report (added 2026-09-25 evening)
Same job, `--report` mode, Cloud Scheduler **sns-ads-report-daily** = every day 12:00 UTC (8am EDT / 7am EST) → #analytics.
Yesterday + last-7-day totals, per-campaign spend vs budget with flags (no impressions 7d / budget-capped / non-eligible
status), top 12 search terms by 7-day cost. Read-only. Run now: `gcloud run jobs execute sns-ads-sync --region us-east1 --project sipandscript --args=--report --wait`.

Same evening: Rest of US budget → $50/day (account total $115/day ≈ $3,500/mo). Stephen's intent: metro campaigns that
under-spend should eventually donate budget to the ones that don't — revisit after the first weeks of reports.
Ad copy: all 39 ads had "Drink Included With Class", "Sip, Learn & Letter" and "…over a drink…" replaced (Google
alcohol-information limit on 4 ads, AND a drink is not universally part of the ticket — venue-dependent). NOTE the live
metro pages still say "all materials and a drink included" — site copy to correct.

## Morning brief with AI narrative (added 2026-09-25 evening)
`--brief` mode = Claude narrative + GA4 website report (`ga_report.py`) + Google Ads report in ONE Slack message,
Scheduler **sns-ga-report-daily** (repointed) at 12:15 UTC; **sns-ads-report-daily** PAUSED (kept for ad-hoc use).
- `ai_summary.py`: Claude Opus 5 (`claude-opus-5`, effort low, server-side fallbacks "default"), system prompt pins the
  business context and forbids invented numbers; any failure/refusal → brief posts without the narrative.
- Auth = **Workload Identity Federation, no API key**: Cloud Run's ads-builder identity token (audience
  https://api.anthropic.com) is exchanged for an Anthropic token by the SDK. Console resources: issuer `google-cloud`
  (https://accounts.google.com), service account `svac_01R9YZ7NYdEL3Ys53FbUto2f`, rule `fdrl_01DeyYjK2CitumthUG1dqVm5`
  (audience + claims sub=107455532153348511019, email=ads-builder@sipandscript.iam.gserviceaccount.com), org
  6b6f3926-f414-4288-9d14-d9c85e874398, workspace wrkspc_01TezEU4bYbdcBZRj2tnSAue (all set as job env vars; also the
  defaults in the module). Local run: `GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/sns-ads-builder-key.json`.
- GA4 gotcha: a multi-dateRange runReport with a `transactionId` dimension returns identical rows per range with summed
  metrics — query each range separately. GA4's `transactions` metric does NOT dedupe (939 events vs 853 unique IDs / 14d).

## Slack delivery: card + thread + charts (added 2026-09-25 night)
`slack_post.py` posts with the **Ad Sync Bot** Slack app (second app, plain non-rotating `xoxb-` token in Secret Manager
`slack-ads-sync-bot-token`, scopes chat:write + files:write, bot invited to #analytics C0C459A46ET): Block Kit parent
(narrative, 5-field GA grid, ads totals + pacing, biggest movers = top-5 campaigns that served + flagged, flags footer),
thread reply with the full GA + Ads text, and two 28-day PNG charts (`charts.py`, matplotlib) uploaded into the thread via
files.getUploadURLExternal / completeUploadExternal. No bot token → plain-text webhook fallback (no thread).
Gotcha: the first "Ad Sync" app had token rotation ON (xoxe.xoxb-, 12 h expiry, reinstall only via OAuth redirect) —
unusable for a daily job and cannot be turned off; hence the second app. Job memory raised to 1Gi for matplotlib.

## 2026-09-26 fixes
- **Misconfigured bidding (Philadelphia, Seattle, Tampa flagged; all 16 affected):** campaign-level Maximize Clicks on a
  SHARED budget → `bidding_strategy_system_status = MISCONFIGURED_SHARED_BUDGET`. Fix: portfolio strategy
  `SNS | Portfolio | Max clicks $2 cap (Near Me shared budget)` (biddingStrategies/12251705786) attached to the 16
  near-me campaigns; all now ELIGIBLE. Builder updated (portfolio for any shared budget).
- **Inventory guard in the radius sync:** no mutations if bookable classes < 100 or fell > 50% vs the previous run
  (`_inventory` history in state); posts a NOT APPLIED alert instead. Baseline seeded at 826.
- Still "Approved (limited)" for alcohol information after the copy change: Dallas and Washington DC near-me ads only
  (2 of 39). Likely the landing page ("a drink included") or brand name; appeal in the UI or fix the metro copy.
- **Scheduler 403 on first scheduled brief (2026-09-26 08:15):** `roles/run.invoker` grants `run.jobs.run` but NOT
  `run.jobs.runWithOverrides`, and the daily schedules pass `--brief` as a container override. Fixed by granting
  `roles/run.developer` to ads-builder on the job `sns-ads-sync` only. Weekly sync (no override) was unaffected.
- **/order-confirmation as a landing page (diagnosed 2026-09-26, 14 d):** 318 sessions `checkout.stripe.com / referral`
  (Stripe redirect starts a new GA4 session → purchase credited to Referral), 175 `(direct)` with 124 NEW users (cookie
  loss in in-app browsers → attribution lost entirely), and shared ticket pages re-firing purchase (one orderGuid: 26
  sessions / 15 purchase events). Stephen added `checkout.stripe.com` + `accounts.google.com` to GA4 unwanted referrals
  2026-09-26. Open: once-only purchase fire (server side); client-id carry-through for in-app browsers (Matt).
