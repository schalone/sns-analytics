-- Success criterion 1 (spec §11): variance under 1% on every day of the last 30. Warn severity:
-- mart_orders_reconciliation has zero rows today (it starts at launch_date and there are no
-- new-site orders or Stripe rows yet), so this is inert until real data lands.
{{ config(severity='warn') }}
select business_date, variance_pct from {{ ref('mart_orders_reconciliation') }} where flagged and business_date >= date_sub(current_date('America/New_York'), interval 30 day) and business_date < current_date('America/New_York')
