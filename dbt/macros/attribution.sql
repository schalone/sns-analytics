{#- Final-review I11. GA4 writes the literal '(not set)' (any case) or an empty string where it has no value;
    both mean "unknown" and must not beat the next level of the attribution fallback. -#}
{% macro unset_to_null(expr) -%}
case when lower(trim({{ expr }})) in ('(not set)', '') then null else {{ expr }} end
{%- endmacro %}

{#- A phantom referral is a sign-in or payment round trip that GA4 records as a new referral session: every
    source in var('phantom_referral_sources'), plus any source ending in '.stripe.com' (Stripe Checkout and its
    subdomains). Never NULL. -#}
{% macro is_phantom_referral(source) -%}
coalesce(lower({{ source }}) in (
  {%- for s in var('phantom_referral_sources') %}'{{ s | lower }}'{{ ", " if not loop.last }}{% endfor -%}
) or lower({{ source }}) = 'stripe.com' or ends_with(lower({{ source }}), '.stripe.com'), false)
{%- endmacro %}
