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
# Tests tofu-trivy/rdjson.jq on the output of pre-commit-opentofu's tofu_trivy hook with SARIF
# output: Trivy's log lines interleaved with one pretty-printed SARIF document per scanned
# directory. No tools but jq.
#
# Run: bash tofu-trivy/rdjson.test.sh

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

# sarif DIR RESULTS: a SARIF document as Trivy prints it (indented two spaces), for a scan of DIR.
sarif() {
	jq -n --arg base "file://${WS}/$1" --argjson results "$2" '{
	  version: "2.1.0",
	  "$schema": "https://json.schemastore.org/sarif-2.1.0-rtm.5.json",
	  runs: [{
	    tool: {driver: {name: "Trivy", rules: [
	      {id: "AVD-AWS-0086", helpUri: "https://avd.aquasec.com/misconfig/avd-aws-0086", defaultConfiguration: {level: "error"}}]}},
	    results: $results,
	    originalUriBaseIds: {ROOTPATH: {uri: $base}}
	  }]
	}'
}
RESULT='[{"ruleId": "AVD-AWS-0086", "level": "error", "message": {"text": "No public access block so not blocking public acls"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "main.tf", "uriBaseId": "ROOTPATH"}, "region": {"startLine": 3, "startColumn": 1, "endLine": 5, "endColumn": 1}}}]}]'
LOG=$'2026-01-01T00:00:00Z\tINFO\t[misconfig] Misconfiguration scanning is enabled'

converts "a result gets its scanned directory, rule, help link, level and region" '
  .source.name == "trivy" and .diagnostics == [{"code": {"url": "https://avd.aquasec.com/misconfig/avd-aws-0086", "value": "AVD-AWS-0086"},
    "location": {"path": "stacks/a/main.tf", "range": {"end": {"column": 1, "line": 5}, "start": {"column": 1, "line": 3}}},
    "message": "No public access block so not blocking public acls", "severity": "ERROR"}]' <<<"${LOG}${NL}$(sarif stacks/a/ "${RESULT}")${NL}${LOG}"
converts "one document per scanned directory, the log lines between them skipped" '
  [.diagnostics[].location.path] == ["stacks/a/main.tf", "stacks/b c/main.tf"]' <<<"${LOG}${NL}$(sarif stacks/a/ "${RESULT}")${NL}${LOG}${NL}$(sarif 'stacks/b%20c' "${RESULT}")"
converts "a result without a level takes its rule's default; levels map note and none to INFO" '
  [.diagnostics[].severity] == ["ERROR", "INFO", "INFO", "WARNING"]' <<<"$(sarif . '[
  {"ruleId": "AVD-AWS-0086", "message": {"text": "a"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.tf", "uriBaseId": "ROOTPATH"}}}]},
  {"ruleId": "X", "level": "note", "message": {"text": "b"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.tf", "uriBaseId": "ROOTPATH"}}}]},
  {"ruleId": "X", "level": "none", "message": {"text": "c"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.tf", "uriBaseId": "ROOTPATH"}}}]},
  {"ruleId": "Y", "message": {"text": "d"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.tf", "uriBaseId": "ROOTPATH"}}}]}]')"
converts "a file:// result URI is used as it is, made relative" '
  .diagnostics[0].location.path == "x/y.tf"' <<<"$(sarif . '[{"ruleId": "X", "level": "warning", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file://'"${WS}"'/x/y.tf"}}}]}]')"
converts "percent-escaped UTF-8 in a file:// URI is decoded: a 2-byte é, a 3-byte € and a 4-byte 😀" '
  .diagnostics[0].location.path == "caf\u00e9/\u20ac 1/\ud83d\ude00.tf"' <<<"$(sarif . '[{"ruleId": "X", "level": "warning", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file://'"${WS}"'/caf%C3%A9/%E2%82%AC%201/%F0%9F%98%80.tf"}}}]}]')"
converts "a percent-escaped base directory is decoded too" '
  .diagnostics[0].location.path == "stacks/\u00e9t\u00e9/main.tf"' <<<"$(sarif 'stacks/%c3%a9t%C3%A9/' "${RESULT}")"
refuses "a percent-escape that is not UTF-8 is an error" "is not UTF-8" <<<"$(sarif . '[{"ruleId": "X", "level": "warning", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a%FF.tf"}}}]}]')"
refuses "a cut-off UTF-8 percent-escape is an error" "ends inside a UTF-8 sequence" <<<"$(sarif . '[{"ruleId": "X", "level": "warning", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a%C3.tf"}}}]}]')"
refuses "an overlong UTF-8 form is an error" "not valid UTF-8" <<<"$(sarif . '[{"ruleId": "X", "level": "warning", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a%E0%80%AF.tf"}}}]}]')"
converts "a scan without results is an empty report" '.diagnostics == []' <<<"$(sarif . '[]')"
refuses "output without a SARIF document is an error" "has no SARIF document" <<<"${LOG}${NL}${LOG}"
refuses "a FATAL log line is an error" "trivy reported an error" <<<"${LOG}${NL}2026-01-01T00:00:00Z	FATAL	Fatal error"
refuses "a valid SARIF document followed by a FATAL scan is an error, not a partial report" "trivy reported an error" \
	<<<"$(sarif stacks/a/ "${RESULT}")${NL}2026-01-01T00:00:00Z	FATAL	Fatal error: scan error: unable to scan"
refuses "an ERROR log line is an error" "trivy reported an error" <<<"$(sarif . '[]')${NL}2026-01-01T00:00:00.123+02:00	ERROR	[misconfig] failed"
refuses "a valid SARIF document followed by a cut-off compact one is an error" "an unexpected line" \
	<<<"$(sarif stacks/a/ "${RESULT}")${NL}$(sarif stacks/b/ "${RESULT}" | jq -c . | head -c 120)"
refuses "an unknown line is an error" "an unexpected line" <<<"$(sarif . '[]')${NL}something went wrong"
converts "the version notice and a download progress bar are Trivy's own lines" '.diagnostics | length == 1' \
	<<<"${LOG}${NL}  12.34 MiB / 45.67 MiB [------>______] 27.02% 3.2 MiB p/s ETA 10s${NL}$(sarif stacks/a/ "${RESULT}")${NL}${NL}📣 Notices:${NL}  - Version 0.99.0 of Trivy is now available, current version is 0.60.0${NL}${NL}To suppress version checks, run Trivy scans with the --skip-version-check flag"
refuses "a notice item without the notice header is an error" "an unexpected line" <<<"$(sarif . '[]')${NL}  - stray item"
refuses "a result without a location is an error" "has no location" <<<"$(sarif . '[{"ruleId": "X", "level": "error", "message": {"text": "m"}}]')"
refuses "an unknown level is an error" "is not error, warning, note or none" <<<"$(sarif . '[{"ruleId": "X", "level": "fatal", "message": {"text": "m"}, "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.tf"}}}]}]')"
refuses "a JSON document that is not SARIF is an error" "is not SARIF" <<<'{"results": []}'
refuses "a SARIF document cut off is an error" "never closed" <<<"$(sarif . "${RESULT}" | head -5)"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
