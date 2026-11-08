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
# The tofu-trivy run step: lets git (which OpenTofu and Trivy use to fetch modules) reach private
# GitHub repositories with the gh-module-token, then runs lib/run-passes.sh.
#
# Environment: GH_MODULE_TOKEN (the action's gh-module-token input, may be empty); every other
# variable is run-passes.sh's, passed through unchanged.
#
# With a token, nothing is written to any git config file: the rewrite goes into this process's
# environment as GIT_CONFIG_COUNT, GIT_CONFIG_KEY_<n> and GIT_CONFIG_VALUE_<n>, which git reads
# like `-c` options and which end with the step. Entries already in the environment are kept and
# the new ones appended after them. The token is masked in the log (::add-mask::) and
# GH_MODULE_TOKEN is removed from the environment the hooks see. The SSH forms of github.com URLs
# (ssh://git@github.com/, ssh://git@github.com, git@github.com:, git::ssh://git@github.com/) are
# rewritten to https://x-access-token:<token>@github.com/, the rewrites v1 put in the global git
# config for the rest of the job.
#
# A token with characters a GitHub token never has (it goes into a URL), or a GIT_CONFIG_COUNT
# that is not a number, is an operational error before anything runs: an ::error:: that never
# prints the token, the outputs exitcode=0, ran=false, result=error, findings=0, and exit 2.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_PASSES="${HERE}/../lib/run-passes.sh"

# Workflow-command data must have %, CR and LF escaped, or a value could end the message early
# and start a command of its own.
esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

refuse() {
	echo "::error::tofu-trivy: $(esc "$*"); nothing was run"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s\n' "exitcode=0" "scan-exitcode=" "ran=false" "result=error" "findings=0" >>"${GITHUB_OUTPUT}"
	fi
	exit 2
}

token="${GH_MODULE_TOKEN:-}"
unset GH_MODULE_TOKEN
if [[ -n "${token}" ]]; then
	[[ "${token}" =~ ^[A-Za-z0-9_-]+$ ]] ||
		refuse "gh-module-token has characters a GitHub token does not have (only letters, digits, _ and - are allowed)"
	echo "::add-mask::${token}"
	count="${GIT_CONFIG_COUNT:-0}"
	[[ "${count}" =~ ^(0|[1-9][0-9]*)$ ]] || refuse "GIT_CONFIG_COUNT is '${count}', not a number"
	base="https://x-access-token:${token}@github.com"
	rewrites=(
		"${base}/" "ssh://git@github.com/"
		"${base}" "ssh://git@github.com"
		"${base}/" "git@github.com:"
		"${base}/" "git::ssh://git@github.com/"
	)
	for ((i = 0; i < ${#rewrites[@]}; i += 2)); do
		export "GIT_CONFIG_KEY_${count}=url.${rewrites[i]}.insteadOf"
		export "GIT_CONFIG_VALUE_${count}=${rewrites[i + 1]}"
		count=$((count + 1))
	done
	export GIT_CONFIG_COUNT="${count}"
	unset token base rewrites
	echo "tofu-trivy: git rewrites the SSH forms of github.com URLs to HTTPS with the module token, for this step only"
fi
exec "${RUN_PASSES}"
