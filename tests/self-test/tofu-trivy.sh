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
# Self-test caller for the tofu-trivy action: an OpenTofu stack under stack/, scanned by trivy's
# misconfiguration checks (downloaded by trivy from its public checks bundle; no token). The bad
# change adds a security group rule open to 0.0.0.0/0 (AWS-0107). Nothing is planned or applied:
# the scan is static, so no provider or credentials are needed. The gh-module-token input (private
# modules) is not exercised: it needs a secret.
#
# pre-commit-opentofu is not in this repository's own .pre-commit-config.yaml: the rev is pinned
# here by hand (the newest release at least two weeks old when it was chosen; Dependabot does not
# see it).
#
# Usage: tests/self-test/tofu-trivy.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

st_write .pre-commit-config.yaml <<'EOF'
repos:
  - repo: https://github.com/tofuutils/pre-commit-opentofu
    rev: v2.4.2
    hooks:
      - id: tofu_trivy
      - id: tofu_trivy
        alias: tofu_trivy-sarif-output
        name: tofu_trivy (sarif output)
        args: ["--args=--format sarif"]
        stages: [manual]
EOF
st_write stack/main.tf <<'EOF'
locals {
  name = "caller"
}
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/stack/main.tf" <<'EOF'

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  description       = "SSH from anywhere"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "sg-12345678"
}
EOF
	st_commit "feat(stack): open ssh"
	;;
clean | nested)
	st_write stack/main.tf <<'EOF'
locals {
  name   = "caller"
  region = "eu"
}
EOF
	st_commit "feat(stack): add the region"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'AWS-0107' tofu_trivy-sarif-output manual
