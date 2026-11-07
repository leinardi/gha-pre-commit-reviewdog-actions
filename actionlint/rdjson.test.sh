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
# Tests actionlint/rdjson.jq on actionlint's one-line output (`-oneline`). No tools but jq.
#
# Run: bash actionlint/rdjson.test.sh

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

converts "a finding becomes an ERROR with its kind as the code" '
  .source.name == "actionlint" and .diagnostics == [{"code": {"url": "https://github.com/rhysd/actionlint/blob/main/docs/checks.md", "value": "expression"},
    "location": {"path": ".github/workflows/ci.yaml", "range": {"start": {"column": 13, "line": 4}}},
    "message": "got unexpected character '"'"'+'"'"' while lexing expression", "severity": "ERROR"}]' <<'EOF2'
.github/workflows/ci.yaml:4:13: got unexpected character '+' while lexing expression [expression]
EOF2
converts "ShellCheck findings take ShellCheck's level, mapped explicitly, and its SC code" '
  [.diagnostics[] | [.severity, .code.value]] == [["ERROR", "SC2154"], ["WARNING", "SC2034"], ["INFO", "SC2086"], ["INFO", "SC2006"]]' <<'EOF2'
.github/workflows/a.yaml:10:9: shellcheck reported issue in this script: SC2154:error:1:6: x is referenced but not assigned [shellcheck]
.github/workflows/a.yaml:11:9: shellcheck reported issue in this script: SC2034:warning:1:1: y appears unused [shellcheck]
.github/workflows/a.yaml:12:9: shellcheck reported issue in this script: SC2086:info:1:6: Double quote to prevent globbing [shellcheck]
.github/workflows/a.yaml:13:9: shellcheck reported issue in this script: SC2006:style:1:5: Use $(...) notation [shellcheck]
EOF2
converts "an absolute path is made relative, blank lines and colour codes are ignored" '
  .diagnostics[0].location.path == ".github/workflows/b.yaml" and (.diagnostics | length) == 1' <<<"${NL}"$'\e[0m'"${WS}/.github/workflows/b.yaml:1:1: m [syntax-check]${NL}"
refuses "a line in another format is an error" "is not \`<file>:<line>:<column>: <message>\`" <<<"could not read config"
refuses "an unknown ShellCheck level is an error" "is not error, warning, info or style" <<<"a.yaml:1:1: shellcheck reported issue in this script: SC1:fatal:1:1: m [shellcheck]"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
