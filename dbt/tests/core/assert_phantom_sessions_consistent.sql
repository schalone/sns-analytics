select session_key
from {{ ref('core_sessions') }}
where is_phantom_referral
  and (
    (source = '(direct)') != (coalesce(campaign, '') = '(direct)')
    or (medium = '(none)' and source != '(direct)')
  )
