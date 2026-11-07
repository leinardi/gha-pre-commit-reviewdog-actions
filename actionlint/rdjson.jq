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

# actionlint's one-line output (`-oneline`: `<file>:<line>:<column>: <message> [<kind>]`) to
# RDJSON. Run by run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f actionlint/rdjson.jq`
# on the hook's output.
#
# actionlint has no severity of its own, so every finding is an ERROR (as in v1), except the
# problems it reports from ShellCheck (`shellcheck reported issue in this script:
# SC<code>:<level>:<line>:<column>: ...`), whose level is mapped explicitly: error to ERROR,
# warning to WARNING, info and style to INFO. A line that is not in that format is an error, so
# a report is never silently partial.

include "rdjson";

def shellcheck_severity:
  if . == "error" then "ERROR"
  elif . == "warning" then "WARNING"
  elif . == "info" or . == "style" then "INFO"
  else error("shellcheck level \(tojson) is not error, warning, info or style")
  end;

def diagnostic($workspace):
  . as $line
  | (capture("^(?<file>.+?):(?<line>[0-9]+):(?<column>[0-9]+): (?<message>.*?)(?: \\[(?<kind>[a-z0-9-]+)\\])?$")
     // error("actionlint printed a line that is not `<file>:<line>:<column>: <message>`: \($line[0:200])"))
  | ((.message | capture("shellcheck reported issue in this script: SC(?<code>[0-9]+):(?<level>[a-z]+):")) // null) as $sc
  | {
      message: .message,
      severity: (if $sc then $sc.level | shellcheck_severity else "ERROR" end),
      location: {
        path: (.file | rel_path($workspace)),
        range: {start: {line: (.line | tonumber), column: (.column | tonumber)}}
      }
    }
    + (if $sc then {code: {value: "SC\($sc.code)", url: "https://www.shellcheck.net/wiki/SC\($sc.code)"}}
       elif .kind then {code: {value: .kind, url: "https://github.com/rhysd/actionlint/blob/main/docs/checks.md"}}
       else {} end);

{
  source: {name: "actionlint", url: "https://github.com/rhysd/actionlint"},
  diagnostics: [split("\n")[] | rtrimstr("\r") | strip_ansi | select(test("\\S")) | diagnostic($workspace)]
}
