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
# Tests tofu-tflint/rdjson.jq on the output of pre-commit-opentofu's tofu_tflint hook (v2.4.2:
# coloured headers, `echo -e` of tflint's one-line JSON report per failing directory). No tools
# but jq.
#
# Run: bash tofu-tflint/rdjson.test.sh

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

R=$'\e[0m'
Y=$'\e[0m\e[33m'
G=$'\e[0m\e[32m'
INIT="${G}Command 'tflint --init' successfully done:${R}${NL}All plugins are already installed${NL}${NL}${NL}${NL}"
ISSUE='{"issues":[{"rule":{"name":"terraform_unused_declarations","severity":"warning","link":"https://github.com/terraform-linters/tflint-ruleset-terraform/blob/v0.13.0/docs/rules/terraform_unused_declarations.md"},"message":"variable \"x\" is declared but not used","range":{"filename":"main.tf","start":{"line":1,"column":1},"end":{"line":1,"column":13}},"callers":[]}],"errors":[]}'

converts "an issue gets its directory prefix, rule, link, severity and range" '
  .source.name == "tflint" and .diagnostics == [{"code": {"url": "https://github.com/terraform-linters/tflint-ruleset-terraform/blob/v0.13.0/docs/rules/terraform_unused_declarations.md", "value": "terraform_unused_declarations"},
    "location": {"path": "stacks/a/main.tf", "range": {"end": {"column": 13, "line": 1}, "start": {"column": 1, "line": 1}}},
    "message": "variable \"x\" is declared but not used", "severity": "WARNING"}]' <<<"${INIT}${Y}TFLint in stacks/a/:${R}${NL}${ISSUE}${NL}"
converts "several directories, the root one (./) included, and tflint errors are all read" '
  [.diagnostics[] | [.location.path, .severity, .message]]
  == [["stacks/a/main.tf", "WARNING", "variable \"x\" is declared but not used"], ["main.tf", "WARNING", "variable \"x\" is declared but not used"], [".", "ERROR", "Failed to load configurations: boom"]]' <<<"${INIT}${Y}TFLint in stacks/a/:${R}${NL}${ISSUE}${NL}${Y}TFLint in ./:${R}${NL}${ISSUE}${NL}${Y}TFLint in ./:${R}${NL}"'{"issues":[],"errors":[{"summary":"Failed to load configurations","message":"boom","severity":"error"}]}'"${NL}"
converts "\\n and \\t that echo -e turned into a line break and a tab are put back" '
  .diagnostics[0].message == "line one\n\tline two"' <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[{"rule":{"name":"r","severity":"notice"},"message":"line one'"${NL}"$'\t''line two","range":{"filename":"a.tf","start":{"line":2,"column":3}}}],"errors":[]}'"${NL}"
converts "a notice is INFO" '.diagnostics[0].severity == "INFO"' <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[{"rule":{"name":"r","severity":"notice"},"message":"m","range":{"filename":"a.tf","start":{"line":1,"column":1}}}],"errors":[]}'
refuses "a failed tflint --init is an error" "tflint --init. failed" <<<"${R}Command 'tflint --init' failed:${R}${NL}Failed to install a plugin"
refuses "output without any TFLint block is an error" "has no \"TFLint in <dir>/:\" report" <<<"${INIT}"
refuses "a block that is not JSON is an error" "is not JSON" <<<"${Y}TFLint in ./:${R}${NL}Error: something"
refuses "an unknown severity is an error" "is not error, warning or notice" <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[{"rule":{"name":"r","severity":"fatal"},"message":"m","range":{"filename":"a.tf"}}],"errors":[]}'
refuses "a report with another schema is an error, never an empty report" "is not tflint's JSON schema" \
	<<<"${INIT}${Y}TFLint in stack/:${R}${NL}"'{"unexpected":"changed report schema"}'
refuses "a report without its errors array is an error" "is not tflint's JSON schema" <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[]}'
refuses "a report whose issues is not an array is an error" "is not tflint's JSON schema" <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":{},"errors":[]}'
refuses "a report with an extra key is an error" "is not tflint's JSON schema" <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[],"errors":[],"version":2}'
refuses "an issue that is not an object is an error" "is not tflint's JSON schema" <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":["x"],"errors":[]}'
converts "an empty report is fine" '.diagnostics == []' <<<"${Y}TFLint in ./:${R}${NL}"'{"issues":[],"errors":[]}'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
