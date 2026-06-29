# Input: an array (slurped from JSONL) of objects:
#   { "__prefix": "stacks/base-gcp/", "payload": { "issues":[...], "errors":[...] } }

def sev_map:
  ( . // "warning" | ascii_downcase ) as $s
  | if   $s == "error"   then "ERROR"
    elif $s == "warning" then "WARNING"
    else "WARNING"
    end;

def strip_dot_slash:
  if startswith("./") then (.[2:]) else . end;

def full_path($p; $f):
  # prefix + filename, then drop leading "./" if any
  ($p + ($f // "")) | strip_dot_slash;

def issue_to_diag($p):
  . as $i
  | {
      message: ($i.message // ""),
      code: (if ($i.rule? and ($i.rule.name?)) then
               { value: ($i.rule.name // ""), url: ($i.rule.link // null) }
             else null end),
      severity: (($i.rule.severity // $i.severity) | sev_map),
      location: {
        path:   full_path($p; $i.range.filename),
        range: {
          start: { line: ($i.range.start.line // 1), column: ($i.range.start.column // 1) },
          end:   { line: ($i.range.end.line   // ($i.range.start.line // 1)),
                   column:($i.range.end.column // ($i.range.start.column // 1)) }
        }
      }
    };

def error_to_diag($p):
  . as $e
  | {
      message: (
        ($e.summary // "") as $s
        | ($s + (if $e.message then ": " + $e.message else "" end))
      ),
      severity: ($e.severity | sev_map),
      location: {
        path:   full_path($p; $e.range.filename),
        range: {
          start: { line: ($e.range.start.line // 1), column: ($e.range.start.column // 1) },
          end:   { line: ($e.range.end.line   // ($e.range.start.line // 1)),
                   column:($e.range.end.column // ($e.range.start.column // 1)) }
        }
      }
    };

{
  source: { name: "tflint", url: "https://github.com/terraform-linters/tflint" },
  diagnostics:
    ( [ .[] as $entry
        | ($entry.__prefix // "") as $p
        | ($entry.payload.issues // [])[] | issue_to_diag($p)
      ]
      +
      [ .[] as $entry
        | ($entry.__prefix // "") as $p
        | ($entry.payload.errors // [])[] | error_to_diag($p)
      ]
    )
}
