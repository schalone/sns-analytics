-- Fixed literals through the url_decode macro; returns a row for any mismatch (fail on any row).
with cases as (
  select 'San+Francisco%2C+CA' as input, 'San Francisco, CA' as expected
  union all select 'Washington%2C+DC', 'Washington, DC'
  union all select 'caf%C3%A9', 'café'
  union all select '100%', '100%'
  union all select 'plain', 'plain'
  union all select cast(null as string), cast(null as string)
)
select input, expected, {{ url_decode('input') }} as actual
from cases
where {{ url_decode('input') }} is distinct from expected
