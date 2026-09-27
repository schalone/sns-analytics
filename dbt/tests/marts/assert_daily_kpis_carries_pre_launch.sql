-- Controller ruling 4: fails until both eras are present in mart_daily_kpis. Verified 2026-09-27:
-- core_sessions spans both sides of the 2026-06-19 launch (2.37M rows from 2025-01-01), so with
-- the null-safe grid join fixed (ruling 5), mart_daily_kpis carries both pre_launch values today
-- through its session rows (count(distinct pre_launch) = 2) even though core_orders has no
-- new-site rows yet. Kept at error severity (no override needed).
select 1 from (select count(distinct pre_launch) as n from {{ ref('mart_daily_kpis') }}) where n < 2
