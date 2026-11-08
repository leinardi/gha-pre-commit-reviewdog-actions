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

# mypy's JSON output (`--output json`: one JSON object per line) to RDJSON. Run by run-passes.sh
# as `jq -R -s -L lib --arg workspace <root> -f mypy/rdjson.jq` on the hook's output.
#
# Each line is {"file", "line", "column", "end_line", "end_column", "message", "hint", "code",
# "severity"}; mypy's columns are 0-based (its text output adds 1) and RDJSON's are 1-based, so 1
# is added. A column of -1 means none. Notes (severity "note") are context for an error and are
# dropped, as before. mypy also prints its config-file problems as plain lines,
# `<file>: [<section>]: <message>`; each becomes a warning on that file. Any other line, or a JSON
# value that is not a mypy error object, is an error: the report is never silently partial.

include "rdjson";

def severity:
  if . == "error" then "ERROR"
  elif . == "warning" then "WARNING"
  else error("mypy severity \(tojson) is not error, warning or note")
  end;

def position($line; $column):
  {line: $line} + (if ($column | type) == "number" and $column >= 0 then {column: ($column + 1)} else {} end);

def diagnostic($workspace):
  if type != "object" or (.file | type) != "string" or (.line | type) != "number"
    or (.message | type) != "string" or (.severity | type) != "string"
  then error("a mypy JSON line is not an error object: \(tojson | .[0:200])")
  else
    {
      message: (.message + (if (.hint | type) == "string" and .hint != "" then "\n" + .hint else "" end)),
      severity: (.severity | severity),
      location: {
        path: (.file | gsub("\\\\"; "/") | rel_path($workspace)),
        range: ({start: position(.line; .column)}
          + (if (.end_line | type) == "number" and .end_line > 0
             then {end: position(.end_line; .end_column)} else {} end))
      }
    }
    + (if (.code | type) == "string" and .code != ""
       then {code: {value: .code, url: "https://mypy.readthedocs.io/en/stable/_refs.html#code-\(.code)"}}
       else {} end)
  end;

def config_problem($workspace):
  capture("^(?<file>[^:]+): \\[(?<section>[^\\]]+)\\]: (?<message>.+)$")
  // error("mypy printed a line that is neither JSON nor a config-file message: \(.[0:200])")
  | {message: "[\(.section)]: \(.message)", severity: "WARNING",
     location: {path: (.file | rel_path($workspace))}};

json_documents
| {
    source: {name: "mypy", url: "https://mypy-lang.org/"},
    diagnostics: (
      [.documents[] | select(type != "object" or .severity != "note") | diagnostic($workspace)]
      + [.other[] | config_problem($workspace)]
    )
  }
