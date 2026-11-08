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

# The output of pre-commit-opentofu's tofu_trivy hook with SARIF output to RDJSON. Run by
# run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f tofu-trivy/rdjson.jq` on the hook's
# output.
#
# The hook runs `trivy conf <dir>` in every directory with a changed file. Each run prints one
# pretty-printed SARIF document on stdout and its log lines on stderr, which pre-commit
# interleaves into one output: the log lines are skipped, the SARIF documents are read with
# json_documents. A result's location is its artifactLocation: a file:// URI, or a path relative
# to the run's originalUriBaseIds entry (the scanned directory); either is made relative to the
# repository root. The level is mapped explicitly (error to ERROR, warning to WARNING, note and
# none to INFO; a result without one takes its rule's default level, else SARIF's "warning").
# Output with no SARIF document at all (a failed hook always prints one), a document that is not
# SARIF, or a result without a location is an error.
#
# Every other line must be one Trivy prints around a scan, or the report may be partial (a later
# scan that failed, a SARIF document cut off on one line): a DEBUG, INFO or WARN log line
# ("<RFC 3339 time>\t<LEVEL>\t..."), the version notice ("📣 Notices:", its "  - " items and
# "To suppress version checks, ..."), or a download progress bar ("1.2 MiB / 3.4 MiB [...").
# An ERROR or FATAL log line, and any other line, is an error.

include "rdjson";

def severity:
  if . == "error" then "ERROR"
  elif . == "warning" then "WARNING"
  elif . == "note" or . == "none" then "INFO"
  else error("SARIF level \(tojson) is not error, warning, note or none")
  end;

# Decodes the UTF-8 bytes in $bytes (numbers 0-255) to a string. Overlong forms, surrogates,
# code points above U+10FFFF and cut-off sequences are an error.
def utf8_decode($bytes):
  reduce $bytes[] as $x ({cps: [], need: 0, cp: 0, min: 0};
      if .need == 0 then
        if $x < 128 then .cps += [$x]
        elif $x >= 194 and $x < 224 then .need = 1 | .cp = $x - 192 | .min = 128
        elif $x >= 224 and $x < 240 then .need = 2 | .cp = $x - 224 | .min = 2048
        elif $x >= 240 and $x < 245 then .need = 3 | .cp = $x - 240 | .min = 65536
        else error("a percent-escape in a SARIF URI is not UTF-8 (byte \($x))")
        end
      elif $x >= 128 and $x < 192 then
        .cp = .cp * 64 + ($x - 128) | .need -= 1
        | if .need > 0 then .
          elif .cp < .min or .cp > 1114111 or (.cp >= 55296 and .cp < 57344) then
            error("a percent-escape in a SARIF URI is not valid UTF-8 (U+\(.cp))")
          else .cps += [.cp]
          end
      else error("a percent-escape in a SARIF URI is not UTF-8 (a cut-off sequence)")
      end)
  | if .need != 0 then error("a percent-escape in a SARIF URI ends inside a UTF-8 sequence") else .cps | implode end;

# Decodes the %XX escapes in a URI path: each run of them is a sequence of UTF-8 bytes (a space is
# %20, é is %C3%A9).
def uri_decode:
  def hex: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1];
  gsub("(?<run>(?:%[0-9A-Fa-f]{2})+)"; utf8_decode([.run | ltrimstr("%") | split("%")[] | hex]));

def fs_path:
  if startswith("file://") then sub("^file://"; "") | uri_decode else uri_decode end;

def result_path($run; $workspace):
  (.locations[0]?.physicalLocation.artifactLocation // error("a trivy result has no location: \(.ruleId // "")")) as $loc
  | ($loc.uri // error("a trivy result location has no uri: \(.ruleId // "")")) as $uri
  | if ($uri | startswith("file://")) then $uri | fs_path
    else
      (($run.originalUriBaseIds // {})[$loc.uriBaseId // ""].uri // "" | fs_path
       | if . == "" or endswith("/") then . else . + "/" end) + ($uri | uri_decode)
    end
  | rel_path($workspace);

def result_diagnostic($run; $rules; $workspace):
  .ruleId as $id
  | (.locations[0]?.physicalLocation.region // {}) as $region
  | {
      message: (.message.text // .message.markdown // error("a trivy result has no message: \($id // "")")),
      severity: ((.level // $rules[$id // ""].defaultConfiguration.level // "warning") | severity),
      location: {
        path: result_path($run; $workspace),
        range: ({start: {line: ($region.startLine // 1), column: ($region.startColumn // 1)}}
          + (if ($region.endLine | type) == "number"
             then {end: {line: $region.endLine, column: ($region.endColumn // 1)}} else {} end))
      }
    }
    + (if ($id | type) == "string"
       then {code: ({value: $id} + (if ($rules[$id].helpUri | type) == "string" then {url: $rules[$id].helpUri} else {} end))}
       else {} end);

def check_other_lines:
  reduce .[] as $line ({notices: false};
    if ($line | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})\t(DEBUG|INFO|WARN)\t")) then .notices = false
    elif ($line | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})\t(ERROR|FATAL)\t")) then
      error("trivy reported an error, so the report may be incomplete: \($line[0:300])")
    elif ($line | test("^\\s*(📣 )?Notices:\\s*$")) then .notices = true
    elif .notices and ($line | test("^\\s+- ")) then .
    elif ($line | startswith("To suppress version checks, run Trivy scans with the --skip-version-check flag")) then .notices = false
    elif ($line | test("^\\s*[0-9.]+ [KMGT]?i?B / [0-9.]+ [KMGT]?i?B \\[")) then .
    else error("an unexpected line in the hook output (a failed scan or a cut-off report?): \($line[0:300])")
    end)
  | true;

json_documents
| (.other | check_other_lines) as $_
| .documents
| if length == 0 then error("the hook output has no SARIF document") else . end
| {
    source: {name: "trivy", url: "https://github.com/aquasecurity/trivy"},
    diagnostics: [
      .[]
      | if type != "object" or (.runs | type) != "array" then error("a JSON document in the hook output is not SARIF (no runs)") else . end
      | .runs[] as $run
      | ([($run.tool.driver.rules // [])[] | select(type == "object" and (.id | type) == "string") | {key: .id, value: .}] | from_entries) as $rules
      | ($run.results // [])[]
      | result_diagnostic($run; $rules; $workspace)
    ]
  }
