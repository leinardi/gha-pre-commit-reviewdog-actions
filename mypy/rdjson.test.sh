#!/usr/bin/env bash
#
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
#
# Tests mypy/rdjson.jq on mypy's JSON output, including lines recorded from mypy 2.x through
# pre-commit 4.6.2 (paths changed to the test workspace). No tools but jq.
#
# Run: bash mypy/rdjson.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib"
CONVERTER="${HERE}/rdjson.jq"
WS=/home/runner/work/repo/caller

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
	if [[ -n "${2:-}" ]]; then
		while IFS= read -r line; do printf '       %s\n' "${line}"; done <<<"$2"
	fi
}

# convert: the hook output on stdin through the converter, exactly as lib/run-passes.sh runs it
# (raw input, -L lib, --arg workspace), then through rdjson_normalize as run-passes.sh does.
# Prints the compact, key-sorted RDJSON; fails like the converter.
convert() {
	jq -R -s -L "${LIB}" --arg workspace "${WS}" -f "${CONVERTER}" |
		jq -c -S -L "${LIB}" --arg workspace "${WS}" 'include "rdjson"; rdjson_normalize($workspace)'
}

# converts NAME EXPECTED (a jq expression over the RDJSON, which must be true) < INPUT
converts() {
	local name="$1" expect="$2" input result
	input="$(cat)"
	if result="$(convert <<<"${input}" 2>&1)" && [[ "$(jq -r "${expect}" <<<"${result}" 2>&1)" == true ]]; then
		ok "${name}"
	else
		not_ok "${name}" "${result}"
	fi
}

# refuses NAME PATTERN < INPUT: the converter must fail with a message matching PATTERN.
refuses() {
	local name="$1" pattern="$2" input result
	input="$(cat)"
	if result="$(convert <<<"${input}" 2>&1)"; then
		not_ok "${name} (it converted)" "${result}"
	elif grep -q -- "${pattern}" <<<"${result}"; then
		ok "${name}"
	else
		not_ok "${name} (wrong message)" "${result}"
	fi
}

converts "mypy JSON lines become RDJSON with 1-based columns, codes and relative paths" '
  .source.name == "mypy" and (.diagnostics | length) == 2
  and .diagnostics[0] == {"code": {"url": "https://mypy.readthedocs.io/en/stable/_refs.html#code-return-value", "value": "return-value"},
    "location": {"path": "pkg/bad.py", "range": {"end": {"column": 13, "line": 6}, "start": {"column": 12, "line": 6}}},
    "message": "Incompatible return value type (got \"int\", expected \"str\")", "severity": "ERROR"}
  and .diagnostics[1].location.path == "pkg/bad.py" and .diagnostics[1].location.range.start == {"line": 9, "column": 17}' <<EOF2
{"file": "${WS}/pkg/bad.py", "line": 6, "column": 11, "end_line": 6, "end_column": 12, "message": "Incompatible return value type (got \"int\", expected \"str\")", "hint": null, "code": "return-value", "severity": "error"}
{"file": "${WS}/pkg/bad.py", "line": 9, "column": 16, "end_line": 9, "end_column": 17, "message": "Name \"l\" is not defined", "hint": null, "code": "name-defined", "severity": "error"}
EOF2
converts "notes are dropped, a hint is appended, a column of -1 is left out" '
  (.diagnostics | length) == 1 and .diagnostics[0].message == "m\nuse x"
  and .diagnostics[0].location.range == {"start": {"line": 3}} and (.diagnostics[0] | has("code") | not)' <<'EOF2'
{"file": "a.py", "line": 3, "column": -1, "message": "m", "hint": "use x", "code": null, "severity": "error"}
{"file": "a.py", "line": 3, "column": 0, "message": "context", "hint": null, "code": null, "severity": "note"}
EOF2
converts "a mypy config-file message becomes a warning on that file (recorded from mypy 2.x)" '
  .diagnostics == [{"location": {"path": "mypy.ini"}, "message": "[mypy]: check_untyped_defs: Not a boolean: True", "severity": "WARNING"}]' <<'EOF2'
mypy.ini: [mypy]: check_untyped_defs: Not a boolean: True
EOF2
converts "an empty output is an empty report" '.diagnostics == []' </dev/null
refuses "a line that is neither JSON nor a config message is an error" "neither JSON nor a config-file message" <<'EOF2'
Traceback (most recent call last):
EOF2
refuses "a JSON line that is not a mypy error is an error" "is not an error object" <<'EOF2'
{"file": "a.py"}
EOF2
refuses "an unknown severity is an error" "is not error, warning or note" <<'EOF2'
{"file": "a.py", "line": 1, "column": 0, "message": "m", "severity": "fatal"}
EOF2

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
