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
# Self-test caller for the ansible-lint action: a playbook. The bad change adds a task without a
# name (name[missing]).
#
# ansible-lint's hook never takes file names and always runs (pass_filenames: false,
# always_run: true upstream), so it lints the whole project whenever any file changed: the none
# row is a commit that only deletes a file, which leaves no changed file to run on.
#
# ansible-lint is not in this repository's own .pre-commit-config.yaml: the rev is pinned here by
# hand (the newest release at least two weeks old when it was chosen; Dependabot does not see it).
#
# Usage: tests/self-test/ansible-lint.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

st_write .pre-commit-config.yaml <<'EOF'
repos:
  - repo: https://github.com/ansible/ansible-lint
    rev: v26.10.1
    hooks:
      - id: ansible-lint
        alias: ansible-lint-fix
        name: ansible-lint-fix
        always_run: false
        files: \.(yml|yaml)$
        exclude: ^\.github/.*
        args: [--fix]
      - id: ansible-lint
        name: ansible-lint
        always_run: false
        files: \.(yml|yaml)$
        exclude: ^\.github/.*
      - id: ansible-lint
        alias: ansible-lint-parseable
        name: "ansible-lint (parseable output)"
        args: ["-p"]
        stages: [manual]
EOF
# The caller's pre-commit config is not Ansible content.
st_write .ansible-lint <<'EOF'
---
exclude_paths:
  - .pre-commit-config.yaml
EOF
st_write playbook.yml <<'EOF'
---
- name: Check the hosts
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Ping the hosts
      ansible.builtin.ping:
EOF
st_write obsolete.txt <<<"To be deleted."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/playbook.yml" <<'EOF'
    - ansible.builtin.debug:
        msg: A task without a name
EOF
	st_commit "feat(playbook): add a task"
	;;
clean | nested)
	cat >>"${ST_DIR}/playbook.yml" <<'EOF'
    - name: Say hello
      ansible.builtin.debug:
        msg: Hello
EOF
	st_commit "feat(playbook): say hello"
	;;
none)
	rm -- "${ST_DIR}/obsolete.txt"
	st_commit "chore(caller): delete an obsolete file"
	;;
esac

st_finish 'name[missing]' ansible-lint-parseable manual
