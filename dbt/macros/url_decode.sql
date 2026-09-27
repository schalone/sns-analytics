{#
  Decodes a percent-encoded (application/x-www-form-urlencoded style) string: '+' becomes a
  space, '%XX' becomes the byte 0xXX, everything else passes through as its own UTF-8 bytes. The
  pieces are re-assembled as BYTES (in order, via a STRING_AGG over an UNNEST ... WITH OFFSET) and
  then decoded back to STRING with SAFE_CONVERT_BYTES_TO_STRING, so invalid UTF-8 yields NULL
  instead of erroring the query. NULL in (or, in practice, an empty match) yields NULL out: an
  empty/NULL `expr` produces an empty or NULL array from REGEXP_EXTRACT_ALL, UNNEST of that is
  zero rows, and STRING_AGG over zero rows is NULL.
#}
{% macro url_decode(expr) %}
safe_convert_bytes_to_string((
  select string_agg(
    case when regexp_contains(piece, r'^%[0-9A-Fa-f]{2}$') then from_hex(substr(piece, 2))
         else cast(piece as bytes)
    end,
    b''
    order by piece_offset
  )
  from unnest(regexp_extract_all(replace({{ expr }}, '+', ' '), r'%[0-9A-Fa-f]{2}|[^%]+|%')) as piece with offset piece_offset
))
{% endmacro %}
