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

# sqlfluff's JSON lint output (`--format json`: one array of files per run, on one line) to
# RDJSON. Run by run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f sqlfluff/rdjson.jq`
# on the hook's output.
#
# Each file is {"filepath", "violations": [{"code", "description", "warning", "start_line_no",
# "start_line_pos", "end_line_no", "end_line_pos", ...}]} (sqlfluff 1.x: "line_no", "line_pos").
# sqlfluff prints the paths it was given or absolute ones, so they are made relative to the
# repository root (v1 posted absolute paths as they were). A line that is not that JSON is an
# error.

include "rdjson";

def position($line; $column):
  {line: $line} + (if ($column | type) == "number" then {column: $column} else {} end);

def diagnostic($path):
  if type != "object" or (.description | type) != "string" then
    error("a sqlfluff violation has no description: \(tojson | .[0:200])")
  else
    (.start_line_no // .line_no) as $line
    | if ($line | type) != "number" then error("a sqlfluff violation has no line: \(tojson | .[0:200])") else . end
    | {
        message: .description,
        severity: (if .warning == true then "WARNING" else "ERROR" end),
        location: {
          path: $path,
          range: ({start: position($line; .start_line_pos // .line_pos)}
            + (if (.end_line_no | type) == "number" then {end: position(.end_line_no; .end_line_pos)} else {} end))
        }
      }
      + (if (.code | type) == "string" and .code != ""
         then {code: {value: .code, url: "https://docs.sqlfluff.com/en/stable/reference/rules.html#rule-\(.code)"}}
         else {} end)
  end;

json_documents
| if (.other | length) > 0 then error("sqlfluff printed a line that is not its JSON output: \(.other[0][0:200])")
  elif any(.documents[]; type != "array") then error("sqlfluff's JSON output is not an array of files")
  else
    {
      source: {name: "sqlfluff", url: "https://www.sqlfluff.com/"},
      diagnostics: [
        .documents[][]
        | if type != "object" or (.filepath | type) != "string" or ((.violations // []) | type) != "array"
          then error("a sqlfluff file entry has no filepath or violations: \(tojson | .[0:200])")
          else (.filepath | gsub("\\\\"; "/") | rel_path($workspace)) as $path | (.violations // [])[] | diagnostic($path)
          end
      ]
    }
  end
