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

# ShellCheck's JSON output (`-f json`: one array of comments per run, on one line) to RDJSON. Run
# by run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f shellcheck/rdjson.jq` on the
# hook's output.
#
# Each comment is {"file", "line", "endLine", "column", "endColumn", "level", "code", "message",
# "fix"}. The level is mapped explicitly: error to ERROR, warning to WARNING, info and style to
# INFO (v1 read the first letter, so style became an unknown "s"); any other level is an error.
# The fix is not posted from here: the diff pass posts ShellCheck's own suggestions. A line that
# is not a JSON array of comments is an error.

include "rdjson";

def severity:
  if . == "error" then "ERROR"
  elif . == "warning" then "WARNING"
  elif . == "info" or . == "style" then "INFO"
  else error("shellcheck level \(tojson) is not error, warning, info or style")
  end;

def diagnostic($workspace):
  if type != "object" or (.file | type) != "string" or (.line | type) != "number"
    or (.code | type) != "number" or (.message | type) != "string"
  then error("a shellcheck comment is not an object with file, line, code and message: \(tojson | .[0:200])")
  else
    {
      message: .message,
      severity: (.level | severity),
      code: {value: "SC\(.code)", url: "https://www.shellcheck.net/wiki/SC\(.code)"},
      location: {
        path: (.file | rel_path($workspace)),
        range: ({start: ({line: .line} + (if (.column | type) == "number" then {column: .column} else {} end))}
          + (if (.endLine | type) == "number"
             then {end: ({line: .endLine} + (if (.endColumn | type) == "number" then {column: .endColumn} else {} end))}
             else {} end))
      }
    }
  end;

json_documents
| if (.other | length) > 0 then error("shellcheck printed a line that is not its JSON output: \(.other[0][0:200])")
  elif any(.documents[]; type != "array") then error("shellcheck's JSON output is not an array of comments")
  else
    {
      source: {name: "shellcheck", url: "https://www.shellcheck.net/"},
      diagnostics: [.documents[][] | diagnostic($workspace)]
    }
  end
