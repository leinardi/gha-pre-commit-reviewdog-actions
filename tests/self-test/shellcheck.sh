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
# Self-test caller for the shellcheck action: a shell script. The bad change expands a parameter
# without quotes (SC2086).
#
# Same repository and rev as this repository's own hooks (shellcheck-py, which pins the
# ShellCheck release), with the same ids and aliases the action runs.
#
# Usage: tests/self-test/shellcheck.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/shellcheck-py/shellcheck-py)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: ${rev}
    hooks:
      - id: shellcheck
        args: ["-x"]
      - id: shellcheck
        alias: shellcheck-diff-output
        name: shellcheck (diff output)
        args: ["-f", "diff", "-x"]
        stages: [manual]
      - id: shellcheck
        alias: shellcheck-json-output
        name: shellcheck (json output)
        args: ["-f", "json", "-x"]
        stages: [manual]
EOF
st_write run.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Running"
EOF
chmod +x "${ST_DIR}/run.sh"
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/run.sh" <<'EOF'
echo Argument: $1
EOF
	st_commit "feat(run): print the argument"
	;;
clean | nested)
	cat >>"${ST_DIR}/run.sh" <<'EOF'
echo "Argument: ${1:-}"
EOF
	st_commit "feat(run): print the argument"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish '2086' shellcheck-json-output manual
