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

# Shared helpers for the RDJSON converters, loaded with `jq -L "<repo>/lib"` and
# `include "rdjson";`. run-passes.sh calls every converter with `--arg workspace <repository
# root>`, the absolute path the hooks ran in, so a converter can turn the absolute paths a tool
# prints into the repository-relative paths reviewdog matches against the pull request diff.
#
# Nothing here reads the environment: the workspace is always an explicit argument, so a converter
# behaves the same in a test as on a runner.

# Removes ANSI escape sequences (colours, cursor movement) from a string, for tools that colour
# their messages even when pre-commit runs with --color=never.
def strip_ansi:
  gsub("\u001b\\[[0-9;?]*[ -/]*[@-~]"; "")
  | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)"; "");

# A path relative to $workspace when it lies under it; any other path is returned unchanged, so a
# path outside the repository is never cut down into one that looks like it is inside. A leading
# "./" is dropped too. An empty $workspace changes nothing.
def rel_path($workspace):
  ($workspace | sub("/+$"; "")) as $ws
  | if $ws == "" then .
    elif startswith($ws + "/") then .[($ws | length) + 1:]
    else .
    end
  | sub("^(\\./)+"; "");

# Checks that the input is an RDJSON document reviewdog can read (an object with a diagnostics
# array, each diagnostic an object) and makes every location path, including related locations,
# relative to $workspace. Anything else is an error, never an empty report: a converter that lost
# its input must fail, not post nothing.
def rdjson_normalize($workspace):
  def fix_location: if (.location? | type) == "object" and (.location.path? | type) == "string"
    then .location.path |= rel_path($workspace) else . end;
  if type != "object" then error("the report is not a JSON object")
  elif (.diagnostics | type) != "array" then error("the report has no diagnostics array")
  elif any(.diagnostics[]; type != "object") then error("a diagnostic is not a JSON object")
  else .diagnostics |= map(
      fix_location
      | if (.related_locations? | type) == "array"
        then .related_locations |= map(if type == "object" then fix_location else . end)
        else . end
    )
  end;

# The JSON values a line holds, as an array: one value, or several written one after the other
# with nothing but whitespace between them (`[...][...]`), which is what pre-commit prints when a
# hook that ends its output without a newline (ShellCheck's `-f json`) runs more than once. The
# line is cut where the bracket depth, counted outside strings, returns to zero. Anything else
# around or between the values is an error.
def json_values:
  . as $s
  | try [fromjson] catch (
      ($s | explode) as $c
      | reduce range(0; $c | length) as $i
          ({depth: 0, str: false, esc: false, start: 0, cuts: []};
            $c[$i] as $ch
            | if .str then
                if .esc then .esc = false elif $ch == 92 then .esc = true elif $ch == 34 then .str = false else . end
              elif $ch == 34 then .str = true
              elif $ch == 123 or $ch == 91 then .depth += 1
              elif $ch == 125 or $ch == 93 then
                .depth -= 1
                | if .depth == 0 then .cuts += [[.start, $i + 1]] | .start = $i + 1 else . end
              else . end)
      | if .depth != 0 or .str or ($s[.start:] | test("\\S")) or (.cuts | length) < 2
        then error("not one or more JSON values")
        else [.cuts[] as [$a, $b] | $s[$a:$b] | fromjson]
        end
    );

# Splits a hook's raw output into the JSON documents it printed and its other lines. pre-commit
# runs a hook several times in parallel on parts of the file list (unless the hook sets
# require_serial), and prints the outputs one after the other, so a hook that prints one JSON
# document per run can leave several; jq's fromjson reads only one. A document is either
#   - one line that starts with { or [ and parses as JSON on its own (compact output, JSON Lines),
#     or as several values one after the other (json_values),
#   - or a line that is exactly { or [ through the next line that is exactly } or ] (pretty
#     printed output, whose nested lines are indented).
# ANSI escapes are removed first and a trailing CR is dropped from every line. Returns
# {documents: [...], other: [the remaining lines that are not blank]}; what an "other" line
# means is the converter's call. A pretty-printed document that does not parse, or that is never
# closed, is an error, never skipped.
def json_documents:
  # split/1 and index/1 take literal strings, and add/0 rather than join/1 builds the document:
  # splits/1 and join/1 are quadratic on a large output.
  [split("\n")[] | rtrimstr("\r") | if index("\u001b") then strip_ansi else . end] as $lines
  | reduce range(0; $lines | length) as $i
      ({documents: [], other: [], start: null, closer: null};
        $lines[$i] as $line
        | if .start != null then
            if $line == .closer then
              .documents += [$lines[.start:$i + 1] | map(. + "\n") | add | fromjson]
              | .start = null | .closer = null
            else . end
          elif $line == "{" or $line == "[" then
            .start = $i | .closer = (if $line == "{" then "}" else "]" end)
          elif ($line[0:1] == "{" or $line[0:1] == "[") and (($line | try json_values catch null) != null) then
            .documents += ($line | json_values)
          elif ($line | test("\\S")) then
            .other += [$line]
          else . end)
  | if .start != null then
      error("a JSON document that starts at line \(.start + 1) of the hook output is never closed")
    else {documents, other} end;
