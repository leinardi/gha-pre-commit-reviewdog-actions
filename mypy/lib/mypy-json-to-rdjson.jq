# Input: an array of mypy JSON objects (slurped from JSON Lines)
# Example item:
# {"file":".../file.py","line":8,"column":0,"message":"...","hint":null,"code":"arg-type","severity":"error"}

def to_severity:
  ( . | ascii_downcase ) as $s
  | if   $s == "error"   then "ERROR"
    elif $s == "warning" then "WARNING"
    else "WARNING"
    end;

def strip_ws_prefix:
  # Normalize path separators, then remove "$GITHUB_WORKSPACE/" prefix if present.
  # Fallback to original path if env is unset or not a prefix.
  (. | gsub("\\\\"; "/")) as $p
  | if (env.GITHUB_WORKSPACE) then
      (env.GITHUB_WORKSPACE + "/") as $ws
      | if ($p | startswith($ws)) then ($p | sub("^" + ($ws|gsub("\\\\";"\\\\")); "")) else $p end
    else
      $p
    end;

{
  source: {
    name: "mypy",
    url:  "https://mypy-lang.org/"
  },
  diagnostics:
    [ .[]
      # Ignore context/notes if they ever slip in; your hook already hides context.
      | select((.severity|ascii_downcase) != "note")
      # Construct message, append [code] when present.
      | {
          message: (.message + (if .code then " [" + .code + "]" else "" end)),
          severity: (.severity | to_severity),
          location: {
            path: (.file | strip_ws_prefix),
            range: {
              start: { line: .line, column: .column }
            }
          }
        }
    ]
}
