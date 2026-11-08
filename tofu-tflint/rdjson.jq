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

# The output of pre-commit-opentofu's tofu_tflint hook with `--args=--format=json` to RDJSON. Run
# by run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f tofu-tflint/rdjson.jq` on the
# hook's output.
#
# The hook first runs `tflint --init` and prints "Command 'tflint --init' successfully done:"
# with its output (or "... failed:", and stops). Then, for every directory where tflint failed,
# it prints "TFLint in <dir>/:" and tflint's JSON report, {"issues": [...], "errors": [...]}, with
# file names relative to <dir>. The header lines are coloured even with --color=never (a reset
# sequence), so ANSI escapes are removed first.
#
# The hook prints the report with `echo -e`, which turns the \n and \t escapes inside JSON
# strings into real line breaks and tabs. tflint writes its report on one line, so the lines of
# one block are joined back with \n and real tabs are escaped again before parsing. A block that
# still does not parse, a report that is not tflint's schema (an object with an "issues" and an
# "errors" array of objects, nothing else), a failed `tflint --init`, or output with no block at
# all (a failed hook always prints one) is an error.

include "rdjson";

def severity:
  (. // "" | ascii_downcase) as $s
  | if $s == "error" then "ERROR"
    elif $s == "warning" then "WARNING"
    elif $s == "notice" or $s == "info" then "INFO"
    else error("tflint severity \(tojson) is not error, warning or notice")
    end;

def path($dir; $workspace):
  if (.range.filename? | type) == "string" and .range.filename != "" then
    (.range.filename | if startswith("/") then . else $dir + . end | rel_path($workspace))
  else ($dir | rtrimstr("/") | rel_path($workspace) | if . == "" or . == "." then "." else . end)
  end;

def range:
  if (.range.start.line? | type) == "number" then
    {range: ({start: {line: .range.start.line, column: (.range.start.column // 1)}}
      + (if (.range.end.line? | type) == "number"
         then {end: {line: .range.end.line, column: (.range.end.column // 1)}} else {} end))}
  else {} end;

def issue($dir; $workspace):
  {
    message: (.message // error("a tflint issue has no message")),
    severity: (.rule.severity | severity),
    location: ({path: path($dir; $workspace)} + range)
  }
  + (if (.rule.name? | type) == "string"
     then {code: ({value: .rule.name} + (if (.rule.link? | type) == "string" then {url: .rule.link} else {} end))}
     else {} end);

def problem($dir; $workspace):
  {
    message: ([.summary, .message] | map(select(type == "string" and . != "")) | join(": ")
              | if . == "" then error("a tflint error has no summary or message") else . end),
    severity: ((.severity // "error") | severity),
    location: ({path: path($dir; $workspace)} + range)
  };

[split("\n")[] | rtrimstr("\r") | if index("\u001b") then strip_ansi else . end] as $lines
| if any($lines[]; startswith("Command 'tflint --init' failed:")) then
    error("`tflint --init` failed in the hook; its output is in the log")
  else . end
| reduce $lines[] as $line ({blocks: []};
    ($line | capture("^TFLint in (?<dir>.*):$") // null) as $header
    | if $header then .blocks += [{dir: $header.dir, lines: []}]
      elif (.blocks | length) > 0 then .blocks[-1].lines += [$line]
      else . end)
| .blocks
| if length == 0 then error("the hook output has no \"TFLint in <dir>/:\" report") else . end
| {
    source: {name: "tflint", url: "https://github.com/terraform-linters/tflint"},
    diagnostics: [
      .[]
      | (.dir | if . == "" then "" elif endswith("/") then . else . + "/" end) as $dir
      | (.lines | until(length == 0 or (.[-1] | test("\\S")); .[:-1])
         | until(length == 0 or (.[0] | test("\\S")); .[1:])
         | map(gsub("\t"; "\\t")) | join("\\n")) as $text
      | ($text | try fromjson catch error("the tflint report for \($dir) is not JSON: \($text[0:200])"))
      | if type != "object" then error("the tflint report for \($dir) is not a JSON object") else . end
      | if (keys - ["errors", "issues"]) != [] or (.issues | type) != "array" or (.errors | type) != "array"
           or any(.issues[], .errors[]; type != "object")
        then error("the tflint report for \($dir) is not tflint's JSON schema ({\"issues\": [...], \"errors\": [...]}): \(tojson | .[0:200])")
        else . end
      | (.issues[] | issue($dir; $workspace)), (.errors[] | problem($dir; $workspace))
    ]
  }
