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
# Checks what one CI self-test row's action actually handed reviewdog: its findings output and
# the copies of every report it posted, which the action writes to its reports-dir input
# (REPORTS_DIR of lib/run-passes.sh) as <pass-id>--<report-index>.<rdjson|efm|diff>, listed in
# reports.json as [{pass, name, source, format, file, count}].
#
#   bad    findings > 0; reports.json lists only files that exist there, with the right
#          extension, and its counts add up to findings; and the planted finding (the
#          generator's expected-finding) is in one of the reports: for an rdjson report, as a
#          diagnostic's message or rule code (checked with jq), for an efm or diff report, as
#          text in the file. So a converter that drops every diagnostic, or a report that never
#          reaches reviewdog, fails the row even though the hook failed.
#   clean  findings == 0 (and, when reports.json is there, its counts add up to 0)
#   nested as clean
#   none   findings == 0 and no report file at all (reports.json, if any, is an empty list)
#
# Environment: ACTION, MODE, STEPS (the JSON of the steps context; findings is read from step
# run-<action>), REPORTS_DIR, EXPECTED (mode bad).

set -euo pipefail

: "${ACTION:?}" "${MODE:?}" "${STEPS:?}" "${REPORTS_DIR:?}"

problems=()
problem() {
	problems+=("$*")
}

findings="$(jq -r --arg id "run-${ACTION}" '.[$id].outputs.findings // ""' <<<"${STEPS}")"
if [[ ! "${findings}" =~ ^(0|[1-9][0-9]*)$ ]]; then
	problem "the findings output is '${findings}', not a whole number"
	findings=""
fi

index="${REPORTS_DIR}/reports.json"
entries="[]"
if [[ -e "${index}" ]]; then
	if ! entries="$(jq -c '
		if type == "array" and all(.[]; type == "object"
			and (.pass | type) == "string" and (.name | type) == "string"
			and (.source | type) == "string" and (.format | IN("rdjson", "efm", "diff"))
			and (.file | type) == "string" and (.count | type) == "number" and .count >= 0)
		then . else error("not a list of {pass, name, source, format, file, count}") end
	' "${index}" 2>&1)"; then
		problem "reports.json is malformed: ${entries}"
		entries="[]"
	fi
fi

# Every listed file: a plain name of the documented shape, present in REPORTS_DIR.
while IFS=$'\t' read -r file format; do
	[[ -n "${file}" ]] || continue
	if [[ ! "${file}" =~ ^[a-z0-9-]+--[0-9]+\.(rdjson|efm|diff)$ || "${file##*.}" != "${format}" ]]; then
		problem "reports.json lists '${file}' (format ${format}), not <pass-id>--<index>.${format}"
	elif [[ ! -f "${REPORTS_DIR}/${file}" ]]; then
		problem "reports.json lists ${file}, which is not in ${REPORTS_DIR}"
	elif [[ "${format}" == rdjson ]] && ! jq -e '.diagnostics | type == "array"' "${REPORTS_DIR}/${file}" >/dev/null 2>&1; then
		problem "${file} is not an RDJSON object with a diagnostics list"
	fi
done < <(jq -r '.[] | [.file, .format] | @tsv' <<<"${entries}")

total="$(jq '[.[].count] | add // 0' <<<"${entries}")"
mapfile -t report_files < <(find "${REPORTS_DIR}" -mindepth 1 -maxdepth 1 ! -name reports.json -printf '%f\n' 2>/dev/null | LC_ALL=C sort)

case "${MODE}" in
bad)
	: "${EXPECTED:?}"
	[[ -e "${index}" ]] || problem "there is no reports.json in ${REPORTS_DIR}"
	if [[ -n "${findings}" ]]; then
		((findings > 0)) || problem "findings is 0: nothing was posted for the bad change"
		[[ "${total}" == "${findings}" ]] || problem "the reports.json counts add up to ${total}, but findings is ${findings}"
	fi
	found=""
	while IFS=$'\t' read -r file format; do
		path="${REPORTS_DIR}/${file}"
		[[ -f "${path}" ]] || continue
		if [[ "${format}" == rdjson ]]; then
			if jq -e --arg e "${EXPECTED}" 'any(.diagnostics[]?;
				((.message // "") | tostring | contains($e))
				or ((.code.value // "") | tostring | contains($e)))' "${path}" >/dev/null 2>&1; then
				found="${file} (an RDJSON diagnostic)"
				break
			fi
		elif grep -qF -- "${EXPECTED}" "${path}"; then
			found="${file}"
			break
		fi
	done < <(jq -r '.[] | [.file, .format] | @tsv' <<<"${entries}")
	if [[ -z "${found}" ]]; then
		problem "no report carries the planted finding '${EXPECTED}' (for RDJSON: as a diagnostic's message or code)"
	else
		echo "The planted finding '${EXPECTED}' is in ${found}."
	fi
	;;
clean | nested)
	[[ -z "${findings}" || "${findings}" == 0 ]] || problem "findings is ${findings} on a clean change"
	[[ "${total}" == 0 ]] || problem "the reports.json counts add up to ${total} on a clean change"
	;;
none)
	[[ -z "${findings}" || "${findings}" == 0 ]] || problem "findings is ${findings} with nothing to check"
	[[ "${entries}" == "[]" ]] || problem "reports.json lists reports with nothing to check: ${entries}"
	((${#report_files[@]} == 0)) || problem "report files were written with nothing to check: ${report_files[*]}"
	;;
*) problem "unknown mode ${MODE}" ;;
esac

echo "${ACTION} (${MODE}): findings=${findings:-none} reports=$(jq -c 'map({file, count})' <<<"${entries}")"
if [[ -d "${REPORTS_DIR}" ]] && ((${#report_files[@]} > 0)); then
	for file in "${report_files[@]}"; do
		echo "::group::${file}"
		cat -- "${REPORTS_DIR}/${file}"
		echo
		echo "::endgroup::"
	done
fi
if ((${#problems[@]} > 0)); then
	for p in "${problems[@]}"; do
		echo "::error::${ACTION} (${MODE}) reports: ${p}"
	done
	exit 1
fi
echo "The reports are the ones mode ${MODE} requires."
