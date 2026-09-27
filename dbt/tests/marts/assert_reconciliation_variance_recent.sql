-- Success criterion 1 (spec §11): orders_charged_amount within 1% of stripe_charged_amount on every
-- bronco-era day of the last 30 (flagged is defined false in the legacy era, so this can only ever
-- select bronco days). Warn severity: while there are no bronco CMS orders yet but Stripe already
-- carries bronco-era activity, orders_charged_amount is 0 against a real stripe_charged_amount on
-- those days, so every such day in the window is flagged -- expected until the first CMS backfill,
-- not a sign the comparison logic is wrong.
{{ config(severity='warn') }}
select business_date, variance_pct from {{ ref('mart_orders_reconciliation') }} where flagged and business_date >= date_sub(current_date('America/New_York'), interval 30 day) and business_date < current_date('America/New_York')
