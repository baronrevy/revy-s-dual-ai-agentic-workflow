# Minimal JSON Schema (draft 2020-12 subset) validator.
#
# Usage: jq -n --slurpfile schema S.json --slurpfile doc D.json -f jsonschema.jq
# Output: a JSON array of error strings; empty means valid.
# Errors prefixed "SCHEMA:" mean the schema itself is unusable. The caller must
# treat those as an internal failure, never as "valid".
#
# Fail closed: a schema that uses any keyword outside supported_keywords is
# rejected as a whole, so a rule can never be silently skipped.
# "x-regex": true is a local extension: the string must compile as a regex.

def supported_keywords: [
  "$schema", "$id", "$comment", "$defs", "$ref", "title", "description",
  "type", "enum", "const", "required", "properties", "additionalProperties",
  "items", "minItems", "maxItems", "uniqueItems", "minimum", "maximum",
  "minLength", "maxLength", "pattern", "oneOf", "x-regex"
];

def subschemas:
  if type != "object" then empty else
    .,
    ((.properties // {}) | .[] | subschemas),
    (if (.items | type) == "object" then .items | subschemas else empty end),
    (if (.additionalProperties | type) == "object" then .additionalProperties | subschemas else empty end),
    ((.oneOf // []) | .[] | subschemas),
    ((.["$defs"] // {}) | .[] | subschemas)
  end;

def check_schema($root):
  ($root | subschemas) as $s
  | if ($s | type) != "object" then "SCHEMA: subschema is not an object"
    else
      (($s | keys) - supported_keywords) as $unk
      | (if ($unk | length) > 0 then "SCHEMA: unsupported keyword(s): \($unk | join(", "))" else empty end),
        (if $s | has("pattern") then
           (try ("" | test($s.pattern) | empty) catch "SCHEMA: invalid pattern \($s.pattern)")
         else empty end),
        (if $s | has("$ref") then
           (if ($s["$ref"] | startswith("#/")) and
               ($root | getpath($s["$ref"] | ltrimstr("#/") | split("/")) | type) == "object"
            then empty else "SCHEMA: unresolvable $ref \($s["$ref"])" end)
         else empty end)
    end;

def type_ok($t):
  if $t == "integer" then type == "number" and . == floor
  else type == $t end;

def v($root; $s; $p):
  . as $x
  | (if $s | has("$ref") then
       $x | v($root; $root | getpath($s["$ref"] | ltrimstr("#/") | split("/")); $p)
     else empty end),
    (if $s | has("type") then
       ([$s.type] | flatten) as $ts
       | if any($ts[]; . as $t | $x | type_ok($t)) then empty
         else "\($p): expected \($ts | join(" or ")), got \($x | type)" end
     else empty end),
    (if $s | has("const") then
       (if $x == $s.const then empty else "\($p): must be \($s.const | tojson)" end)
     else empty end),
    (if $s | has("enum") then
       (if any($s.enum[]; . == $x) then empty
        else "\($p): must be one of \($s.enum | map(tojson) | join(", "))" end)
     else empty end),
    (if ($x | type) == "object" then
       (($s.required // []) | .[] as $k | select(($x | has($k)) | not) | "\($p): missing required key \"\($k)\""),
       (($s.properties // {}) | to_entries[] as $e
         | select($x | has($e.key))
         | $x[$e.key] | v($root; $e.value; "\($p).\($e.key)")),
       (if $s.additionalProperties == false then
          ($x | keys[]) as $k
          | select((($s.properties // {}) | has($k)) | not)
          | "\($p): unknown key \"\($k)\""
        elif ($s.additionalProperties | type) == "object" then
          ($x | keys[]) as $k
          | select((($s.properties // {}) | has($k)) | not)
          | $x[$k] | v($root; $s.additionalProperties; "\($p).\($k)")
        else empty end)
     else empty end),
    (if ($x | type) == "array" then
       (if $s | has("items") then
          range(0; $x | length) as $i | $x[$i] | v($root; $s.items; "\($p)[\($i)]")
        else empty end),
       (if ($s | has("minItems")) and ($x | length) < $s.minItems then
          "\($p): needs at least \($s.minItems) item(s)" else empty end),
       (if ($s | has("maxItems")) and ($x | length) > $s.maxItems then
          "\($p): allows at most \($s.maxItems) item(s)" else empty end),
       (if $s.uniqueItems == true and ($x | unique | length) != ($x | length) then
          "\($p): items must be unique" else empty end)
     else empty end),
    (if ($x | type) == "number" then
       (if ($s | has("minimum")) and $x < $s.minimum then "\($p): must be >= \($s.minimum)" else empty end),
       (if ($s | has("maximum")) and $x > $s.maximum then "\($p): must be <= \($s.maximum)" else empty end)
     else empty end),
    (if ($x | type) == "string" then
       (if ($s | has("minLength")) and ($x | length) < $s.minLength then
          "\($p): must be at least \($s.minLength) character(s)" else empty end),
       (if ($s | has("maxLength")) and ($x | length) > $s.maxLength then
          "\($p): must be at most \($s.maxLength) character(s)" else empty end),
       (if ($s | has("pattern")) and ($x | test($s.pattern) | not) then
          "\($p): does not match the required format" else empty end),
       (if $s["x-regex"] == true then
          (try ("" | test($x) | empty) catch "\($p): not a valid regular expression")
        else empty end)
     else empty end),
    (if $s | has("oneOf") then
       [ $s.oneOf[] as $b | [ $x | v($root; $b; $p) ] ] as $results
       | ($results | map(select(length == 0)) | length) as $ok
       | if $ok == 1 then empty
         elif $ok == 0 then "\($p): matches none of the allowed forms"
         else "\($p): matches more than one allowed form" end
     else empty end);

$schema[0] as $root
| [ check_schema($root) ] as $schema_errors
| if ($schema_errors | length) > 0 then $schema_errors
  else [ $doc[0] | v($root; $root; "$") ]
  end
