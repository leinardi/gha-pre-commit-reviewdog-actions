# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
