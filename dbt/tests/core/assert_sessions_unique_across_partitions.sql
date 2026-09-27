-- Ruling 3 (controller): same assertion as a `unique` test on session_key, but exists as its own
-- singular test so the phase-one plan's requirement to verify session_key stays unique across
-- insert_overwrite partitions (full-refresh, then incremental) is checked explicitly and by name,
-- independent of the generic `unique` data_test declared on this column in schema.yml.
select session_key from {{ ref('core_sessions') }} group by session_key having count(*) > 1
