{% macro channel_group(source, medium, campaign, has_gclid) %}
case
  when {{ has_gclid }} or lower({{ medium }}) in ('cpc','ppc','paidsearch','paid_search') and lower({{ source }}) in ('google','bing','yahoo','duckduckgo') then 'Paid Search'
  when lower({{ medium }}) in ('cpc','ppc','paid','paidsocial','paid_social','paid-social','social_paid') then 'Paid Social'
  when lower({{ source }}) in ('facebook','instagram','fb','ig','m.facebook.com','l.facebook.com','l.instagram.com','pinterest','pinterest.com','tiktok','linkedin','twitter','t.co','youtube') then 'Organic Social'
  when lower({{ medium }}) = 'organic' or lower({{ source }}) in ('google','bing','yahoo','duckduckgo','ecosia') then 'Organic Search'
  when lower({{ medium }}) in ('email','e-mail','newsletter') or lower({{ source }}) like '%klaviyo%' then 'Email'
  when {{ source }} is null or {{ source }} = '(direct)' then 'Direct'
  when lower({{ medium }}) = 'referral' then 'Referral'
  else 'Other'
end
{% endmacro %}
