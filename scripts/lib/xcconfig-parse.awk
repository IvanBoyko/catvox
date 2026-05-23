# Shared xcconfig parser used by scripts/lib/read-xcconfig-value.sh and
# scripts/lib/emit-xcconfig-env.sh.
#
# Modes (selected by -v mode=...):
#   single  -- print the trimmed value for the row whose key matches -v key=...
#              and exit. Prints nothing if the key is absent.
#   all     -- print every "KEY\tVALUE" row found (tab-separated). Caller is
#              responsible for further processing (validation, escaping).
#
# Recognises lines of the form "KEY = VALUE" where KEY contains only
# [A-Za-z0-9_]. xcconfig conditional qualifiers ("KEY[sdk=*]"), #include
# directives, and line continuations are not interpreted -- matching the
# historical behaviour of read-xcconfig-value.sh. The active config files only
# use the simple form.

BEGIN {
  FS = "="
  if (mode == "") { mode = "single" }
}

# Strip ASCII whitespace from both ends of the given string.
function trim(s) {
  sub(/^[ \t\r\n]+/, "", s)
  sub(/[ \t\r\n]+$/, "", s)
  return s
}

# Extract everything after the first "=" on the line, joined with "=".
function value_after_eq(   i, parts, v) {
  v = $2
  for (i = 3; i <= NF; i++) {
    v = v "=" $i
  }
  return v
}

{
  # Cheap reject of comment-only and blank lines before the regex match.
  line = $0
  sub(/^[ \t]+/, "", line)
  if (line == "" || line ~ /^\/\// || line ~ /^#/) { next }
}

mode == "single" {
  if ($1 ~ "^[ \t]*" key "[ \t]*$") {
    print trim(value_after_eq())
    exit
  }
}

mode == "all" {
  k = trim($1)
  if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { next }
  print k "\t" trim(value_after_eq())
}
