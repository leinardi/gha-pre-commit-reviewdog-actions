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
# Checks every <action>/action.yaml of this repository against the conventions the actions share,
# and feeds each action's PASSES to lib/run-passes.sh in VALIDATE_ONLY mode, so a malformed pass
# list, a converter path that does not resolve or a report name that breaks the naming rule fails
# here rather than on a caller's pull request. For pre-commit-hooks and sqlfluff, whose run step
# goes through a wrapper script, the wrapper is run with the action's defaults.
#
# Structure checked per action (conventional-commits only for the shared ones):
#   - the inputs start with from-ref, to-ref, github-token (optional, default ""),
#     working-directory ("."), reporter (github-pr-review), python-version ("3.x"),
#     pre-commit-version ("4.6.2"), cache-key-prefix ("pre-commit");
#   - every `run:` starts with `set -euo pipefail` and has no ${{ }} in its body;
#   - every `uses:` is pinned to a full commit SHA with a `# vX.Y.Z` comment;
#   - the cache key hashes <working-directory>/.pre-commit-config.yaml;
#   - one step with id "run" calls lib/run-passes.sh (directly or through the action's script),
#     with ACTION_NAME set to the directory name;
#   - the outputs are exitcode, result, ran, findings and <pass id>-exitcode
#     for every pass, from that step;
#   - the report names follow the rule: "<action>" for diagnostics, "<action> (<pass> fixes)" for
#     the tree report, "<action> (<pass> suggestions)" for a diff printed on stdout.
#
# Needs: jq, and python3 with PyYAML (preinstalled on GitHub's Ubuntu runners).
#
# Run: bash lib/action-passes.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

if ! python3 -I -c 'import yaml' 2>/dev/null; then
	echo "not ok - python3 with PyYAML is needed to read the action.yaml files" >&2
	exit 1
fi

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

# The structural checks, in Python: one line per action, "<action>", "<problems or empty>" and
# "<the validation command and env as JSON, or null>", separated by the unit separator \x1f (a
# tab would collapse an empty field).
CHECKS="$(
	cat <<'PY'
import json, os, re, sys
import yaml

root = sys.argv[1]
COMMON = [
    ("from-ref", True, None), ("to-ref", True, None), ("github-token", False, ""),
    ("working-directory", False, "."), ("reporter", False, "github-pr-review"),
    ("python-version", False, "3.x"), ("pre-commit-version", False, "4.6.2"),
    ("cache-key-prefix", False, "pre-commit"), ("reports-dir", False, ""),
]
WRAPPERS = {"pre-commit-hooks": "pre-commit-hooks.sh", "sqlfluff": "sqlfluff.sh", "tofu-trivy": "tofu-trivy.sh"}
KEY = "${{ inputs.cache-key-prefix }}|${{ runner.os }}|${{ steps.python.outputs.python-version }}|${{ hashFiles(format('{0}/.pre-commit-config.yaml', inputs.working-directory)) }}"

for action in sorted(os.listdir(root)):
    path = os.path.join(root, action, "action.yaml")
    if not os.path.isfile(path):
        continue
    text = open(path).read()
    doc = yaml.safe_load(text)
    problems = []
    inputs = list((doc.get("inputs") or {}).items())
    common = COMMON if action != "conventional-commits" else [c for c in COMMON if c[0] not in ("github-token", "reporter", "reports-dir")]
    for i, (name, required, default) in enumerate(common):
        if i >= len(inputs) or inputs[i][0] != name:
            problems.append(f"input {i + 1} is not {name}")
            continue
        spec = inputs[i][1]
        if bool(spec.get("required", False)) != required:
            problems.append(f"input {name} required is not {required}")
        if default is not None and spec.get("default") != default:
            problems.append(f"input {name} default is not {default!r}")
    for n, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^\s*(?:- )?uses:\s*(\S+)(.*)$", line)
        if m and not (re.search(r"@[0-9a-f]{40}$", m.group(1)) and re.match(r"^\s+# v\d+\.\d+\.\d+$", m.group(2))):
            problems.append(f"line {n}: uses: is not pinned to a full SHA with a # vX.Y.Z comment")
    steps = doc["runs"]["steps"]
    for step in steps:
        if "run" in step:
            body = step["run"]
            if not body.startswith("set -euo pipefail\n"):
                problems.append(f"step {step.get('name')!r} does not start with set -euo pipefail")
            if "${{" in body:
                problems.append(f"step {step.get('name')!r} has ${{{{ }}}} in its run body")
        if step.get("uses", "").startswith("actions/cache/restore@") and step["with"]["key"] != KEY:
            problems.append("the cache key does not hash <working-directory>/.pre-commit-config.yaml")
    validation = None
    if action != "conventional-commits":
        runs = [s for s in steps if s.get("id") == "run"]
        if len(runs) != 1:
            problems.append("there is not exactly one step with id run")
        else:
            run = runs[0]
            env = run.get("env", {})
            script = WRAPPERS.get(action)
            target = f"\"$GITHUB_ACTION_PATH/{script}\"" if script else "\"$GITHUB_ACTION_PATH/../lib/run-passes.sh\""
            if run["run"] != f"set -euo pipefail\n{target}\n":
                problems.append(f"the run step does not just call {target}")
            if env.get("ACTION_NAME") != action:
                problems.append(f"ACTION_NAME is {env.get('ACTION_NAME')!r}, not {action}")
            for var, value in (("FROM_REF", "from-ref"), ("TO_REF", "to-ref"), ("WORKING_DIRECTORY", "working-directory"),
                               ("REPORTER", "reporter"), ("REVIEWDOG_GITHUB_API_TOKEN", "github-token"),
                               ("REPORTS_DIR", "reports-dir")):
                if env.get(var) != "${{ inputs." + value + " }}":
                    problems.append(f"{var} is not the {value} input")
            if action == "pre-commit-hooks":
                vars = {"HOOKS": doc["inputs"]["hooks"]["default"]}
                passes = [{"id": "hooks", "reports": [{"source": "tree", "format": "diff", "name": "pre-commit-hooks (hooks fixes)"}]}]
            else:
                vars = {"PASSES": env.get("PASSES", "")}
                try:
                    passes = json.loads(vars["PASSES"])
                except ValueError as e:
                    passes = []
                    problems.append(f"PASSES is not JSON: {e}")
            if action == "sqlfluff":
                vars["RUN_FIX"] = doc["inputs"]["run-fix"]["default"]
            validation = {"script": f"{action}/{script}" if script else "lib/run-passes.sh", "env": vars}
            ids = [p.get("id") for p in passes if isinstance(p, dict)]
            # findings is run-passes.sh's count of what was posted.
            want = ["exitcode", "result", "ran", "findings"] + [f"{i}-exitcode" for i in ids]
            outputs = doc.get("outputs") or {}
            if list(outputs) != want:
                problems.append(f"the outputs are {list(outputs)}, not {want}")
            # result and ran fall back to error and false when a setup step failed before the run
            # step could write them.
            fallback = {"result": " || 'error'", "ran": " || 'false'"}
            for name, spec in outputs.items():
                if spec.get("value") != "${{ steps.run.outputs." + name + fallback.get(name, "") + " }}":
                    problems.append(f"output {name} is not steps.run.outputs.{name}")
            for p in passes:
                if not isinstance(p, dict):
                    continue
                for r in p.get("reports", []):
                    if not isinstance(r, dict):
                        continue
                    if r.get("source") == "tree":
                        want_name = f"{action} ({p.get('id')} fixes)"
                    elif r.get("format") == "diff":
                        want_name = f"{action} ({p.get('id')} suggestions)"
                    else:
                        want_name = action
                    if r.get("name") != want_name:
                        problems.append(f"report {r.get('name')!r} of pass {p.get('id')} is not named {want_name!r}")
    print(action + "\x1f" + "; ".join(problems) + "\x1f" + json.dumps(validation))
PY
)"

count=0
while IFS=$'\x1f' read -r action problems validation; do
	count=$((count + 1))
	if [[ -z "${problems}" ]]; then
		ok "${action}/action.yaml follows the shared conventions"
	else
		not_ok "${action}/action.yaml follows the shared conventions" "${problems//; /$'\n'}"
	fi
	[[ "${validation}" != null ]] || continue
	script="$(jq -r '.script' <<<"${validation}")"
	mapfile -d '' -t vars < <(jq -j '.env | to_entries[] | "\(.key)=\(.value)\u0000"' <<<"${validation}")
	status=0
	log="$(env -i PATH="${PATH}" HOME="${HOME:-/tmp}" ACTION_NAME="${action}" VALIDATE_ONLY=true "${vars[@]}" \
		bash "${ROOT}/${script}" 2>&1)" || status=$?
	if [[ ${status} == 0 ]] && grep -q "PASSES is valid" <<<"${log}"; then
		ok "${action}: run-passes.sh accepts its PASSES ($(sed -n 's/.*PASSES is valid: \([0-9]* pass(es) ([^)]*)\).*/\1/p' <<<"${log}"))"
	else
		not_ok "${action}: run-passes.sh accepts its PASSES" "${log}"
	fi
done < <(python3 -I -c "${CHECKS}" "${ROOT}")

# Every pass-based action and conventional-commits: 13 + 1.
if ((count == 14)); then
	ok "all 14 actions were checked"
else
	not_ok "all 14 actions were checked" "found ${count}"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
