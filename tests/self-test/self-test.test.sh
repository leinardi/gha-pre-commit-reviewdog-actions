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
# Tests for the CI self-test tooling, with real git in temporary directories and no network:
#
#   - every caller generator (tests/self-test/<action>.sh), in every mode: it builds a clean
#     repository whose from-ref..to-ref is what the mode promises (a bad or clean change the
#     action's hooks look at, nothing they look at for none, an untracked nested checkout for
#     nested), names a check hook its own .pre-commit-config.yaml defines, and refuses a bad mode
#     or a non-empty directory. When pre-commit is on PATH, each generated config is also checked
#     with `pre-commit validate-config` (offline);
#   - check-verdict.sh, on steps contexts shaped as the runner builds them;
#   - check-reports.sh, on reports directories shaped as lib/run-passes.sh writes them.
#
# Run: bash tests/self-test/self-test.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export SELF_TEST_SETTLE_SECONDS=0

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

have_pre_commit=0
if command -v pre-commit >/dev/null; then
	have_pre_commit=1
else
	echo "# pre-commit is not on PATH: the generated configs are not validated"
fi

output() {
	sed -n "s/^$1=//p" "$2" | tail -n 1
}

# ---------------------------------------------------------------------------------------------
# The generators
# ---------------------------------------------------------------------------------------------

mapfile -t generators < <(find "${HERE}" -maxdepth 1 -name '*.sh' ! -name lib.sh ! -name 'check-*.sh' ! -name '*.test.sh' -printf '%f\n' | LC_ALL=C sort)
if ((${#generators[@]} != 14)); then
	not_ok "one generator per action" "found ${#generators[@]}: ${generators[*]}"
fi

for generator in "${generators[@]}"; do
	action="${generator%.sh}"
	for mode in bad clean none nested; do
		name="${action} ${mode}"
		dir="${WORK}/${action}-${mode}"
		out="${WORK}/${action}-${mode}.output"
		log="${WORK}/${action}-${mode}.log"
		if ! GITHUB_OUTPUT="${out}" bash "${HERE}/${generator}" "${mode}" "${dir}" >"${log}" 2>&1; then
			not_ok "${name}: generates" "$(cat "${log}")"
			continue
		fi
		problems=()
		from="$(output from-ref "${out}")"
		to="$(output to-ref "${out}")"
		hook="$(output check-hook "${out}")"
		stage="$(output check-stage "${out}")"
		expected="$(output expected-finding "${out}")"
		[[ "$(output mode "${out}")" == "${mode}" ]] || problems+=("mode output is not ${mode}")
		git -C "${dir}" rev-parse --verify --quiet "${from}^{commit}" >/dev/null || problems+=("from-ref '${from}' is not a commit")
		git -C "${dir}" rev-parse --verify --quiet "${to}^{commit}" >/dev/null || problems+=("to-ref '${to}' is not a commit")
		[[ "${to}" == "$(git -C "${dir}" rev-parse HEAD)" ]] || problems+=("to-ref is not HEAD")
		[[ "${from}" != "${to}" ]] || problems+=("from-ref and to-ref are the same commit")
		[[ "$(git -C "${dir}" branch --show-current)" == main ]] || problems+=("not on main")

		status="$(git -C "${dir}" status --porcelain)"
		if [[ "${mode}" == nested ]]; then
			untracked="$(git -C "${dir}" ls-files --others --exclude-standard)"
			[[ "${untracked}" == "vendor/nested-checkout/" ]] || problems+=("the untracked paths are not only the nested checkout: ${untracked}")
			[[ "$(git -C "${dir}" status --porcelain --untracked-files=no)" == "" ]] || problems+=("the worktree is not clean: ${status}")
			[[ -d "${dir}/vendor/nested-checkout/.git" ]] || problems+=("no nested checkout")
		else
			[[ -z "${status}" ]] || problems+=("the worktree is not clean: ${status}")
		fi

		if [[ "${mode}" == bad ]]; then
			[[ -n "${expected}" ]] || problems+=("no expected-finding")
		else
			[[ -z "${expected}" ]] || problems+=("an expected-finding outside mode bad")
		fi

		# What changed, as the action computes it: changed paths that still exist.
		changed=()
		while IFS= read -r -d '' path; do
			[[ ! -e "${dir}/${path}" ]] || changed+=("${path}")
		done < <(git -C "${dir}" diff --name-only --no-ext-diff -z "${from}...${to}")

		if [[ "${action}" == conventional-commits ]]; then
			[[ -z "${hook}" && -z "${stage}" ]] || problems+=("a check hook for conventional-commits")
			subjects="$(git -C "${dir}" log --no-merges --format=%s "${from}..${to}")"
			case "${mode}" in
			bad) [[ "${subjects}" == "updated some notes" ]] || problems+=("bad range subjects: ${subjects}") ;;
			clean | nested) [[ "${subjects}" == "docs(notes): extend the notes again" ]] || problems+=("clean range subjects: ${subjects}") ;;
			none)
				[[ -z "${subjects}" ]] || problems+=("none range has non-merge commits: ${subjects}")
				[[ "$(git -C "${dir}" rev-list --merges --count "${from}..${to}")" == 1 ]] || problems+=("none range is not one merge commit")
				;;
			esac
		else
			[[ -n "${hook}" && -n "${stage}" ]] || problems+=("no check-hook or check-stage")
			grep -Eq "^[[:space:]]*(- )?(id|alias): ${hook}\$" "${dir}/.pre-commit-config.yaml" ||
				problems+=("check-hook ${hook} is not in the generated .pre-commit-config.yaml")
			case "${mode}" in
			bad | clean | nested)
				((${#changed[@]} > 0)) || problems+=("no changed file")
				for path in "${changed[@]}"; do
					[[ "${path}" != notes.txt ]] || problems+=("the change is in notes.txt, which no hook looks at")
				done
				;;
			none)
				for path in "${changed[@]}"; do
					[[ "${path}" == notes.txt ]] || problems+=("none changed ${path}")
				done
				;;
			esac
		fi

		if ((have_pre_commit)) && ! validation="$(cd "${dir}" && pre-commit validate-config .pre-commit-config.yaml 2>&1)"; then
			problems+=("pre-commit validate-config: ${validation}")
		fi

		if ((${#problems[@]} == 0)); then
			ok "${name}"
		else
			not_ok "${name}" "$(printf '%s\n' "${problems[@]}")"
		fi
	done
done

# The bad and the clean change differ, and a generated tree is the same whatever the run.
for generator in "${generators[@]}"; do
	action="${generator%.sh}"
	bad_tree="$(git -C "${WORK}/${action}-bad" rev-parse 'HEAD^{tree}')"
	clean_tree="$(git -C "${WORK}/${action}-clean" rev-parse 'HEAD^{tree}')"
	# conventional-commits' bad and clean heads differ only in the commit message.
	if [[ "${action}" != conventional-commits && "${bad_tree}" == "${clean_tree}" ]]; then
		not_ok "${action}: the bad and clean heads have the same tree"
	fi
	again="${WORK}/${action}-again"
	bash "${HERE}/${generator}" bad "${again}" >/dev/null 2>&1
	if [[ "$(git -C "${again}" rev-parse 'HEAD^{tree}')" == "${bad_tree}" ]]; then
		ok "${action}: the bad tree is reproducible, and differs from the clean one"
	else
		not_ok "${action}: the bad tree differs between two runs"
	fi
done

# Refusals.
if ! bash "${HERE}/yamllint.sh" worse "${WORK}/refused-mode" >/dev/null 2>&1 && [[ ! -e "${WORK}/refused-mode" ]]; then
	ok "a generator refuses an unknown mode before creating anything"
else
	not_ok "a generator refuses an unknown mode before creating anything"
fi
mkdir -p "${WORK}/not-empty"
: >"${WORK}/not-empty/file"
if ! bash "${HERE}/yamllint.sh" bad "${WORK}/not-empty" >/dev/null 2>&1 && [[ ! -e "${WORK}/not-empty/.git" ]]; then
	ok "a generator refuses a directory that is not empty"
else
	not_ok "a generator refuses a directory that is not empty"
fi
if (cd "${WORK}" && GITHUB_WORKSPACE="${WORK}/ws" bash "${HERE}/yamllint.sh" clean >/dev/null 2>&1) && [[ -d "${WORK}/ws/caller/.git" ]]; then
	ok "a generator defaults to \$GITHUB_WORKSPACE/caller"
else
	not_ok "a generator defaults to \$GITHUB_WORKSPACE/caller"
fi

# ---------------------------------------------------------------------------------------------
# check-verdict.sh
# ---------------------------------------------------------------------------------------------

# A steps context: the row's step with outcome $3 and outputs $4, and every other action's step
# skipped, as the runner reports them.
steps() {
	local action="$1" ran_action="$2" outcome="$3" outputs="$4"
	jq -n --arg ran "run-${ran_action}" --arg outcome "${outcome}" --argjson outputs "${outputs}" '
		{caller: {outcome: "success", conclusion: "success", outputs: {"from-ref": "a"}}}
		+ ([ "actionlint", "conventional-commits", "ruff", "yamllint" ]
		   | map({key: "run-\(.)", value: {outcome: "skipped", conclusion: "skipped", outputs: {}}}) | from_entries)
		+ {($ran): {outcome: $outcome, conclusion: "success", outputs: $outputs}}'
}

verdict() {
	local want="$1" name="$2" action="$3" mode="$4" json="$5" got=0 log
	log="$(ACTION="${action}" MODE="${mode}" STEPS="${json}" bash "${HERE}/check-verdict.sh" 2>&1)" || got=$?
	if [[ "${want}" == pass && "${got}" -eq 0 ]] || [[ "${want}" == fail && "${got}" -ne 0 ]]; then
		ok "check-verdict: ${name}: ${want}"
	else
		not_ok "check-verdict: ${name}: expected ${want}, exit ${got}" "${log}"
	fi
}

verdict pass "bad, failed" ruff bad "$(steps ruff ruff failure '{"result":"failed","ran":"true","exitcode":"1"}')"
verdict fail "bad, but the action errored" ruff bad "$(steps ruff ruff failure '{"result":"error","ran":"true","exitcode":"1"}')"
verdict fail "bad, but it passed" ruff bad "$(steps ruff ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict fail "bad, failed with exitcode 0" ruff bad "$(steps ruff ruff failure '{"result":"failed","ran":"true","exitcode":"0"}')"
verdict pass "clean, passed" ruff clean "$(steps ruff ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict fail "clean, but nothing ran" ruff clean "$(steps ruff ruff success '{"result":"skipped","ran":"false","exitcode":"0"}')"
verdict fail "clean, without outputs" ruff clean "$(steps ruff ruff success '{}')"
verdict pass "nested, passed" ruff nested "$(steps ruff ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict pass "none, skipped" ruff none "$(steps ruff ruff success '{"result":"skipped","ran":"false","exitcode":"0"}')"
verdict fail "none, but a hook ran" ruff none "$(steps ruff ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict fail "none, but the step failed" ruff none "$(steps ruff ruff failure '{"result":"skipped","ran":"false","exitcode":"0"}')"
verdict fail "another action's step ran" ruff clean "$(steps ruff yamllint success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict fail "the row's step is missing" mypy clean "$(steps mypy ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict fail "an unknown mode" ruff worse "$(steps ruff ruff success '{"result":"passed","ran":"true","exitcode":"0"}')"
verdict pass "conventional-commits bad" conventional-commits bad "$(steps conventional-commits conventional-commits failure '{"exitcode":"1"}')"
verdict fail "conventional-commits bad, but it passed" conventional-commits bad "$(steps conventional-commits conventional-commits success '{"exitcode":"0"}')"
verdict pass "conventional-commits none" conventional-commits none "$(steps conventional-commits conventional-commits success '{"exitcode":"0"}')"
verdict fail "conventional-commits clean, but it failed" conventional-commits clean "$(steps conventional-commits conventional-commits failure '{"exitcode":"1"}')"
verdict fail "bad, without a result" ruff bad "$(steps ruff ruff failure '{"ran":"true","exitcode":"1"}')"
verdict fail "none, with an empty result" ruff none "$(steps ruff ruff success '{"result":"","ran":"false","exitcode":"0"}')"
verdict fail "conventional-commits, without an exitcode" conventional-commits none "$(steps conventional-commits conventional-commits success '{}')"

# ---------------------------------------------------------------------------------------------
# check-reports.sh
# ---------------------------------------------------------------------------------------------

# A reports directory: $1 its name; then pairs of file name and content; reports.json from $2.
reports_dir() {
	local dir="${WORK}/reports-$1" index="$2"
	shift 2
	rm -rf -- "${dir}"
	mkdir -p -- "${dir}"
	[[ "${index}" == none ]] || printf '%s\n' "${index}" >"${dir}/reports.json"
	while (($# >= 2)); do
		printf '%s\n' "$2" >"${dir}/$1"
		shift 2
	done
	printf '%s' "${dir}"
}

reports() {
	local want="$1" name="$2" mode="$3" findings="$4" dir="$5" got=0 log json
	if [[ "${findings}" == unset ]]; then
		json="$(steps ruff ruff success '{"result":"passed"}')"
	else
		json="$(steps ruff ruff success "$(jq -n --arg f "${findings}" '{findings: $f}')")"
	fi
	log="$(ACTION=ruff MODE="${mode}" STEPS="${json}" REPORTS_DIR="${dir}" EXPECTED=F821 bash "${HERE}/check-reports.sh" 2>&1)" || got=$?
	if [[ "${want}" == pass && "${got}" -eq 0 ]] || [[ "${want}" == fail && "${got}" -ne 0 ]]; then
		ok "check-reports: ${name}: ${want}"
	else
		not_ok "check-reports: ${name}: expected ${want}, exit ${got}" "${log}"
	fi
}

entry() {
	jq -cn --arg file "$1" --arg format "$2" --argjson count "$3" '{pass: ($file | split("--")[0]), name: "ruff", source: "stdout", format: $format, file: $file, count: $count}'
}
RDJSON_F821='{"source":{"name":"ruff"},"diagnostics":[{"message":"Undefined name undefined_suffix","code":{"value":"F821"},"location":{"path":"src/greet.py"}}]}'
RDJSON_F401='{"source":{"name":"ruff"},"diagnostics":[{"message":"os imported but unused","code":{"value":"F401"},"location":{"path":"src/greet.py"}}]}'
RDJSON_EMPTY='{"source":{"name":"ruff F821"},"diagnostics":[]}'
DIFF='--- a/src/greet.py
+++ b/src/greet.py
@@ -1 +1 @@
-import os'

dir="$(reports_dir rdjson "[$(entry check--0.rdjson rdjson 1),$(entry check--1.diff diff 1)]" check--0.rdjson "${RDJSON_F821}" check--1.diff "${DIFF}")"
reports pass "bad, the finding is an RDJSON diagnostic code" bad 2 "${dir}"
reports fail "bad, but findings does not add up" bad 3 "${dir}"
reports fail "bad, but findings is 0" bad 0 "${dir}"
reports fail "bad, without a findings output" bad unset "${dir}"
dir="$(reports_dir other "[$(entry check--0.rdjson rdjson 1)]" check--0.rdjson "${RDJSON_F401}")"
reports fail "bad, the RDJSON report has only another diagnostic" bad 1 "${dir}"
dir="$(reports_dir dropped "[$(entry check--0.rdjson rdjson 0)]" check--0.rdjson "${RDJSON_EMPTY}")"
reports fail "bad, a converter dropped every diagnostic" bad 0 "${dir}"
dir="$(reports_dir substring "[$(entry check--0.rdjson rdjson 1)]" check--0.rdjson '{"source":{"name":"ruff F821"},"diagnostics":[{"message":"os imported but unused","code":{"value":"F401"}}]}')"
reports fail "bad, the code is in the RDJSON text but in no diagnostic" bad 1 "${dir}"
dir="$(reports_dir efm "[$(entry lint--0.efm efm 1)]" lint--0.efm "src/greet.py:5:31: F821 Undefined name")"
reports pass "bad, the finding is text in an efm report" bad 1 "${dir}"
dir="$(reports_dir missing "[$(entry check--0.rdjson rdjson 1)]")"
reports fail "bad, reports.json lists a file that is not there" bad 1 "${dir}"
dir="$(reports_dir badext "[$(entry check--0.efm rdjson 1)]" check--0.efm "${RDJSON_F821}")"
reports fail "bad, a file name that does not match its format" bad 1 "${dir}"
dir="$(reports_dir noindex none check--0.rdjson "${RDJSON_F821}")"
reports fail "bad, without reports.json" bad 1 "${dir}"
dir="$(reports_dir malformed '{"not": "a list"}')"
reports fail "bad, a malformed reports.json" bad 1 "${dir}"
dir="$(reports_dir clean "[$(entry check--0.rdjson rdjson 0)]" check--0.rdjson "${RDJSON_EMPTY}")"
reports pass "clean, findings 0" clean 0 "${dir}"
reports fail "clean, but findings 1" clean 1 "${dir}"
reports fail "clean, without a findings output" clean unset "${dir}"
dir="$(reports_dir cleancount "[$(entry check--0.rdjson rdjson 1)]" check--0.rdjson "${RDJSON_F821}")"
reports fail "clean, but a report counts a finding" clean 0 "${dir}"
dir="$(reports_dir none none)"
reports pass "none, no report at all" none 0 "${dir}"
dir="$(reports_dir noneempty "[]")"
reports pass "none, an empty reports.json" none 0 "${dir}"
dir="$(reports_dir nonefile "[]" check--0.rdjson "${RDJSON_EMPTY}")"
reports fail "none, but a report file was written" none 0 "${dir}"
dir="$(reports_dir nonelisted "[$(entry check--0.rdjson rdjson 0)]" check--0.rdjson "${RDJSON_EMPTY}")"
reports fail "none, but reports.json lists a report" none 0 "${dir}"

echo "${PASS} passed, ${FAIL} failed"
((FAIL == 0))
