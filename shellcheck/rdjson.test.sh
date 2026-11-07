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
# Tests shellcheck/rdjson.jq on ShellCheck's JSON output, recorded from ShellCheck 0.11 (`-f
# json`, which ends without a newline). No tools but jq.
#
# Run: bash shellcheck/rdjson.test.sh

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

RECORDED='[{"file":"bad.sh","line":5,"endLine":5,"column":1,"endColumn":1,"level":"info","code":1009,"message":"The mentioned syntax error was in this if expression.","fix":null},{"file":"bad.sh","line":5,"endLine":5,"column":10,"endColumn":10,"level":"error","code":1073,"message":"Couldn'"'"'t parse this then clause. Fix to allow more checks.","fix":null}]'
converts "ShellCheck comments become RDJSON with SC codes, wiki links and ranges" '
  .source.name == "shellcheck" and (.diagnostics | length) == 2
  and .diagnostics[0] == {"code": {"url": "https://www.shellcheck.net/wiki/SC1009", "value": "SC1009"},
    "location": {"path": "bad.sh", "range": {"end": {"column": 1, "line": 5}, "start": {"column": 1, "line": 5}}},
    "message": "The mentioned syntax error was in this if expression.", "severity": "INFO"}
  and .diagnostics[1].severity == "ERROR"' <<<"${RECORDED}"
converts "each level is mapped explicitly: error, warning, info, and style (to INFO)" '
  [.diagnostics[].severity] == ["ERROR", "WARNING", "INFO", "INFO"]' <<'EOF2'
[{"file":"a.sh","line":1,"column":1,"level":"error","code":1,"message":"e"},{"file":"a.sh","line":2,"column":1,"level":"warning","code":2,"message":"w"},{"file":"a.sh","line":3,"column":1,"level":"info","code":3,"message":"i"},{"file":"a.sh","line":4,"column":1,"level":"style","code":4,"message":"s"}]
EOF2
converts "two runs printed on one line (no newline after -f json) are both read" '(.diagnostics | length) == 4' <<<"${RECORDED}${RECORDED}"
converts "two runs on two lines are both read, and an absolute path is made relative" '
  (.diagnostics | length) == 3 and .diagnostics[2].location.path == "sub/b.sh"' <<<"${RECORDED}${NL}[{\"file\":\"${WS}/sub/b.sh\",\"line\":1,\"column\":1,\"level\":\"warning\",\"code\":2086,\"message\":\"m\"}]"
converts "an empty array is an empty report" '.diagnostics == []' <<<'[]'
refuses "an unknown level is an error" "is not error, warning, info or style" <<<'[{"file":"a.sh","line":1,"column":1,"level":"fatal","code":1,"message":"m"}]'
refuses "a line that is not JSON is an error" "not its JSON output" <<<"bad.sh: No such file${NL}[]"
refuses "a comment without a code is an error" "is not an object with file, line, code and message" <<<'[{"file":"a.sh","line":1,"level":"info","message":"m"}]'
refuses "JSON that is not an array of comments is an error" "not an array of comments" <<<'{"comments": []}'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
