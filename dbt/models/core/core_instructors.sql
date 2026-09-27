{{ config(tags=['hourly']) }}
select instructor_key, name, url_path, city, state, start_date, no_longer_teaches, wordpress_source_id, updated_at
from {{ ref('stg_cms__instructors') }}
