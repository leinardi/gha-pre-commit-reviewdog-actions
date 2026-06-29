# Map SARIF levels to RDJSON severities
def to_sev:
  ( . // "warning" | ascii_downcase ) as $s
  | if   $s == "error"   then "ERROR"
    elif $s == "warning" then "WARNING"
    elif $s == "note"    then "INFO"
    else "WARNING"
    end;

# Convert file:// URI → filesystem path, then strip $GITHUB_WORKSPACE to make it repo-relative.
def to_rel_fs($p):
  ($p // "")
  | sub("^file://"; "")
  | gsub("\\\\"; "/")
  | ( if (env.GITHUB_WORKSPACE) then
        (env.GITHUB_WORKSPACE + "/") as $ws
        | if startswith($ws) then sub("^" + ($ws|gsub("\\\\";"\\\\")); "") else . end
      else . end );

# Ensure a directory path ends with a single slash (or becomes empty string)
def dir_norm:
  ( . // "" | gsub("\\\\"; "/") )
  | if . == "" then "" else ( if endswith("/") then . else . + "/" end ) end;

# Resolve SARIF location to a repo-relative path
def normalize_path($baseuri; $uri):
  # Base dir under repo root (may be "", or e.g. "stacks/base-gcp/")
  (to_rel_fs($baseuri) | dir_norm) as $base
  # If $uri is file://... use that absolute path; else it's a relative path or bare filename
  | ( if ($uri // "" | test("^file://")) then to_rel_fs($uri) else ($base + ($uri // "")) end );

def result_to_diag($run):
  {
    message: (.message.text // .message.markdown // .message // ""),
    code: { value: (.ruleId // "") },
    severity: (.level | to_sev),
    location: (
      ( .locations[0]?.physicalLocation // {} ) as $pl
      | ( $pl.artifactLocation.uri // "" ) as $uri
      | ( $pl.artifactLocation.uriBaseId // "" ) as $baseid
      | ( $run.originalUriBaseIds[$baseid]?.uri // "" ) as $baseuri
      | {
          path: normalize_path($baseuri; $uri),
          range: {
            start: { line: ($pl.region.startLine   // 1), column: ($pl.region.startColumn // 1) },
            end:   { line: ($pl.region.endLine     // ($pl.region.startLine   // 1)),
                     column:($pl.region.endColumn   // ($pl.region.startColumn // 1)) }
          }
        }
    )
  };

{
  source: { name: "trivy", url: "https://github.com/aquasecurity/trivy" },
  diagnostics:
    (
      [ .[] as $doc
        | ($doc.runs // [])[] as $run
        | ($run.results // [])[]
        | result_to_diag($run)
      ]
    )
}
