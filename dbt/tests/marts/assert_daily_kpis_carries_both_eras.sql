-- Controller ruling 4 (renamed from assert_daily_kpis_carries_pre_launch): mart_daily_kpis must
-- carry both platform eras (count(distinct platform_era) = 2), the platform_era analogue of the
-- old pre_launch check.
select n from (select count(distinct platform_era) as n from {{ ref('mart_daily_kpis') }}) where n < 2
