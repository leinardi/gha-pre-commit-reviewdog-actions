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
