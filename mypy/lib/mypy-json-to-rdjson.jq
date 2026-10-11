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
