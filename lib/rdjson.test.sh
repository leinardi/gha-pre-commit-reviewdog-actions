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
# Tests lib/rdjson.jq's helpers with jq only: json_values and json_documents (the hook output
# splitter every JSON converter uses), and rel_path and strip_ansi. rdjson_normalize is also
# covered through run-passes.test.sh.
#
# Run: bash lib/rdjson.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# gives NAME FILTER EXPECTED < RAW: the filter on the raw input must print EXPECTED (compact).
gives() {
	local name="$1" filter="$2" expected="$3" result
	if result="$(jq -R -s -c -L "${HERE}" "include \"rdjson\"; ${filter}" 2>&1)" && [[ "${result}" == "${expected}" ]]; then
		ok "${name}"
	else
		not_ok "${name}" "want ${expected}${NL}got  ${result}"
	fi
}
# fails NAME FILTER PATTERN < RAW
fails() {
	local name="$1" filter="$2" pattern="$3" result
	if result="$(jq -R -s -c -L "${HERE}" "include \"rdjson\"; ${filter}" 2>&1)"; then
		not_ok "${name} (it succeeded)" "${result}"
	elif grep -q -- "${pattern}" <<<"${result}"; then
		ok "${name}"
	else
		not_ok "${name} (wrong message)" "${result}"
	fi
}

gives "json_documents reads compact lines, pretty documents, and keeps other lines apart" json_documents \
	'{"documents":[[1],{"a":1},{"b":2}],"other":["hello","[INFO] x"]}' \
	<<<"[1]${NL}hello${NL}{${NL}  \"a\": 1${NL}}${NL}"$'\e[0m{"b":2}\r'"${NL}[INFO] x${NL}   ${NL}"
gives "json_documents reads a pretty-printed array and blank output" json_documents \
	'{"documents":[[1,2]],"other":[]}' <<<"${NL}[${NL}  1,${NL}  2${NL}]${NL}${NL}"
gives "json_documents on empty output finds nothing" json_documents '{"documents":[],"other":[]}' </dev/null
gives "json_documents reads values printed one after the other on one line" json_documents \
	'{"documents":[[{"m":"a]["}],[2],{"c":"}{\""}],"other":[]}' <<<'[{"m":"a]["}] [2]{"c":"}{\""}'
gives "a line that only starts like JSON is another line" json_documents \
	'{"documents":[],"other":["[1] x [2]","{not json}"]}' <<<"[1] x [2]${NL}{not json}"
gives "a nested line that is exactly } does not end a pretty document early" 'json_documents | .documents' \
	'[{"a":{"b":1}}]' <<<"{${NL}  \"a\": {${NL}    \"b\": 1${NL}  }${NL}}"
fails "a pretty document that never closes is an error" json_documents "starts at line 2 of the hook output is never closed" \
	<<<"log${NL}{${NL}  \"a\": 1"
fails "a pretty document that does not parse is an error" json_documents "while parsing" <<<"{${NL}  \"a\": x${NL}}"
gives "json_values returns one value as a one-element array" json_values '[{"a":1}]' <<<'{"a":1}'
fails "json_values refuses text after the values" json_values "not one or more JSON values" <<<'[1][2] trailing'

gives "rel_path makes a workspace path relative and leaves others alone" \
	'[("/w/r/a.txt", "/w/rx/b", "./c", "d", "/w/r") | rel_path("/w/r/")]' '["a.txt","/w/rx/b","c","d","/w/r"]' </dev/null
gives "strip_ansi removes colour and OSC sequences" 'strip_ansi' '"red link\n"' <<<$'\e[0m\e[31mred\e[0m \e]8;;http://x\e\\link\e]8;;\e\\'

# A large pretty-printed document (about 18 MB, as a big SARIF report) is read in seconds: the
# splitter must stay linear.
big="$(mktemp)"
trap 'rm -f "${big}"' EXIT
jq -n '{runs: [{results: [range(0; 40000) | {ruleId: "X\(.)", message: {text: ("m" * 50)}, region: {startLine: .}}]}]}' >"${big}"
start=${SECONDS}
if count="$(jq -R -s -L "${HERE}" 'include "rdjson"; json_documents | .documents[0].runs[0].results | length' <"${big}")" &&
	[[ "${count}" == 40000 ]] && ((SECONDS - start < 30)); then
	ok "json_documents reads a large pretty-printed document in linear time"
else
	not_ok "json_documents reads a large pretty-printed document in linear time" "count ${count:-none} after $((SECONDS - start))s"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
