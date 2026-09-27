-- Final-review I11: no session may keep a phantom-referral source (any of var('phantom_referral_sources') or a
-- *.stripe.com source) -- core_sessions re-attributes every one of them. is_phantom_referral is never NULL.
select session_key, source, is_phantom_referral
from {{ ref('core_sessions') }}
where {{ is_phantom_referral('source') }}
   or is_phantom_referral is null
