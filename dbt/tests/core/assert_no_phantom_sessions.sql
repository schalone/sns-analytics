select session_key from {{ ref('core_sessions') }} where source = 'accounts.google.com'
