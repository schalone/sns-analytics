-- Instructors in the legacy system. The source table also holds an email column, deliberately not selected.
select cast(id as string) as woo_organizer_id, name, status, location, date(start_date) as start_date
from {{ source('woo', 'organizers') }}
