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
# Self-test caller for the tofu-tflint action: an OpenTofu stack under stack/, linted with
# tflint's bundled terraform ruleset (no .tflint.hcl, so no plugin to download). The bad change
# declares a variable without a type (terraform_typed_variables), which tflint cannot fix.
#
# pre-commit-opentofu is not in this repository's own .pre-commit-config.yaml: the rev is pinned
# here by hand (the newest release at least two weeks old when it was chosen; Dependabot does not
# see it).
#
# Usage: tests/self-test/tofu-tflint.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

st_write .pre-commit-config.yaml <<'EOF'
repos:
  - repo: https://github.com/tofuutils/pre-commit-opentofu
    rev: v2.4.2
    hooks:
      - id: tofu_tflint
        alias: tofu_tflint-json-output
        name: tofu_tflint (json output)
        args: ["--args=--format=json", "--args=--fix"]
        stages: [manual]
EOF
st_write stack/main.tf <<'EOF'
terraform {
  required_version = ">= 1.6.0"
}

variable "name" {
  type        = string
  description = "The name."
}

output "name" {
  value       = var.name
  description = "The name."
}
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/stack/main.tf" <<'EOF'

variable "region_name" {
  description = "A variable without a type."
}

output "region_name" {
  value       = var.region_name
  description = "The region."
}
EOF
	st_commit "feat(stack): add the region"
	;;
clean | nested)
	cat >>"${ST_DIR}/stack/main.tf" <<'EOF'

variable "region_name" {
  type        = string
  description = "The region."
}

output "region_name" {
  value       = var.region_name
  description = "The region."
}
EOF
	st_commit "feat(stack): add the region"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'terraform_typed_variables' tofu_tflint-json-output manual
