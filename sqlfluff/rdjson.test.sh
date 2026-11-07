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
# Tests sqlfluff/rdjson.jq on sqlfluff's JSON lint output (`--format json`, the 3.x shape, and the
# 1.x line_no/line_pos fields). No tools but jq.
#
# Run: bash sqlfluff/rdjson.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib"
CONVERTER="${HERE}/rdjson.jq"
WS=/home/runner/work/repo/caller
# shellcheck disable=SC2034 # not every converter test uses NL
NL=$'\n'

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

converts "violations become RDJSON with codes, warnings and repository-relative paths" '
  .source.name == "sqlfluff" and (.diagnostics | length) == 2
  and .diagnostics[0] == {"code": {"url": "https://docs.sqlfluff.com/en/stable/reference/rules.html#rule-LT01", "value": "LT01"},
    "location": {"path": "models/a b.sql", "range": {"end": {"column": 9, "line": 1}, "start": {"column": 7, "line": 1}}},
    "message": "Expected single whitespace.", "severity": "ERROR"}
  and .diagnostics[1].severity == "WARNING" and .diagnostics[1].location.path == "models/c.sql"' <<EOF2
[{"filepath": "${WS}/models/a b.sql", "violations": [{"start_line_no": 1, "start_line_pos": 7, "code": "LT01", "description": "Expected single whitespace.", "name": "layout.spacing", "warning": false, "fixes": [], "start_file_pos": 6, "end_line_no": 1, "end_line_pos": 9, "end_file_pos": 8}], "statistics": {}}, {"filepath": "models/c.sql", "violations": [{"start_line_no": 2, "start_line_pos": 1, "code": "AM04", "description": "Query produces an unknown number of result columns.", "warning": true}]}]
EOF2
converts "two runs on two lines are both read; a file without violations adds nothing" '(.diagnostics | length) == 2' <<'EOF2'
[{"filepath": "a.sql", "violations": [{"start_line_no": 1, "start_line_pos": 1, "code": "LT01", "description": "d"}]}]
[{"filepath": "b.sql", "violations": []}, {"filepath": "c.sql", "violations": [{"start_line_no": 1, "start_line_pos": 1, "code": "LT02", "description": "d"}]}]
EOF2
converts "sqlfluff 1.x line_no and line_pos are read too" '.diagnostics[0].location.range == {"start": {"line": 4, "column": 2}}' <<'EOF2'
[{"filepath": "a.sql", "violations": [{"line_no": 4, "line_pos": 2, "code": "L001", "description": "d"}]}]
EOF2
refuses "a line that is not JSON is an error" "not its JSON output" <<'EOF2'
WARNING    Unable to lint a.sql due to an internal error.
[]
EOF2
refuses "a file entry without a filepath is an error" "no filepath or violations" <<<'[{"violations": []}]'
refuses "a violation without a line is an error" "has no line" <<<'[{"filepath": "a.sql", "violations": [{"description": "d"}]}]'
refuses "JSON that is not an array of files is an error" "not an array of files" <<<'{"filepath": "a.sql"}'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
