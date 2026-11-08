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
# Tests ruff/rdjson.jq on ruff's RDJSON output, recorded from ruff 0.17 through pre-commit 4.6.2
# (paths changed to the test workspace). No tools but jq.
#
# Run: bash ruff/rdjson.test.sh

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

RECORDED="$(cat <<EOF2
{
  "diagnostics": [
    {
      "code": {
        "url": "https://docs.astral.sh/ruff/rules/undefined-name",
        "value": "F821"
      },
      "location": {
        "path": "${WS}/bad.py",
        "range": {
          "end": {
            "column": 18,
            "line": 8
          },
          "start": {
            "column": 17,
            "line": 8
          }
        }
      },
      "message": "Undefined name \`l\`",
      "suggestions": [{"range": {"start": {"line": 8, "column": 17}}, "text": "x"}]
    }
  ],
  "severity": "WARNING",
  "source": {
    "name": "ruff",
    "url": "https://docs.astral.sh/ruff"
  }
}
EOF2
)"
converts "ruff's pretty-printed RDJSON keeps its source and severity, with relative paths and no suggestions" '
  .source.name == "ruff" and .severity == "WARNING" and (.diagnostics | length) == 1
  and .diagnostics[0].location.path == "bad.py" and .diagnostics[0].code.value == "F821"
  and (.diagnostics[0] | has("suggestions") | not)' <<<"${RECORDED}"
converts "two documents (pre-commit ran ruff twice) are merged into one report" '(.diagnostics | length) == 2' <<<"${RECORDED}${NL}${RECORDED}"
converts "a document with no diagnostics is an empty report" '.diagnostics == [] and .source.name == "ruff"' <<'EOF2'
{"diagnostics": [], "source": {"name": "ruff"}}
EOF2
refuses "a line outside the RDJSON is an error" "outside its RDJSON output" <<<"warning: something${NL}${RECORDED}"
refuses "output with no document is an error" "no RDJSON document" </dev/null
refuses "a document that is not RDJSON is an error" "no diagnostics array" <<<'{"results": []}'
refuses "a pretty-printed document that is never closed is an error" "never closed" <<<"$(head -5 <<<"${RECORDED}")"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
