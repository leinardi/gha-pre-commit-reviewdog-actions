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
# Installs terraform-docs (github.com/terraform-docs/terraform-docs), which the tofu_docs hook
# runs, from its release archive, checked against a SHA-256 pinned below, into $RUNNER_TEMP and
# onto $GITHUB_PATH. No sudo; Linux X64 and ARM64 runners only.
#
# Environment:
#   TERRAFORM_DOCS_VERSION  vX.Y.Z or X.Y.Z, one of the versions in the table below
#   RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP, GITHUB_PATH  set by the runner
#   GITHUB_OUTPUT           when set, path=<the directory added to PATH> is appended to it
#
# Any failure (an unknown version, an unsupported runner, the download, the checksum, a binary
# that reports another version) exits non-zero before anything is added to $GITHUB_PATH.

set -euo pipefail

# The SHA-256 of each release archive, from the release's terraform-docs-<version>.sha256sum
# (`gh release download v0.24.0 -R terraform-docs/terraform-docs -p '*.sha256sum' -O -`), which
# matches the digests the GitHub API reports for the assets. Dependabot does not track a release
# download: add a version here, with both digests, to support it.
declare -A SHA256=(
	[v0.22.0/linux-amd64]=8ec66616777c66f3e622af4f2853e8ae399f38908ad4b262c9c526dd42501369
	[v0.22.0/linux-arm64]=4feccd471e0595546271bde7aabd275a5c1a5b055d6cd89c2678b38ced1376f6
	[v0.23.0/linux-amd64]=80b8cd1d08b44e1182a39177adafc6901650a22e0a7f52cfeffcdbd44e8b0938
	[v0.23.0/linux-arm64]=f3be6f09fb0913c752b78480fac1eb4916e9ee50da7e3eb0bdaa356d80ed16b5
	[v0.24.0/linux-amd64]=9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3
	[v0.24.0/linux-arm64]=d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd
)
SUPPORTED="v0.22.0, v0.23.0, v0.24.0"

# Workflow-command data must have %, CR and LF escaped, or a value could end the message early
# and start a command of its own.
esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

fail() {
	echo "::error title=setup-terraform-docs::$(esc "$*")" >&2
	exit 1
}

VERSION="${TERRAFORM_DOCS_VERSION:-}"
if [[ ! "${VERSION}" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	fail "terraform-docs-version must be vX.Y.Z or X.Y.Z, got '${VERSION}'. Nothing was installed."
fi
VERSION="v${VERSION#v}"

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
Linux/X64) PLATFORM=linux-amd64 ;;
Linux/ARM64) PLATFORM=linux-arm64 ;;
*) fail "terraform-docs is installed on Linux runners, X64 or ARM64 only (RUNNER_OS is '${RUNNER_OS:-unset}', RUNNER_ARCH is '${RUNNER_ARCH:-unset}'). Nothing was installed." ;;
esac
DIGEST="${SHA256[${VERSION}/${PLATFORM}]:-}"
[[ -n "${DIGEST}" ]] || fail "terraform-docs ${VERSION} has no pinned SHA-256 here; supported: ${SUPPORTED}. Nothing was installed."
if [[ -z "${RUNNER_TEMP:-}" ]] || [[ -z "${GITHUB_PATH:-}" ]]; then
	fail "RUNNER_TEMP and GITHUB_PATH must be set (they are, on a GitHub runner). Nothing was installed."
fi

ARCHIVE="terraform-docs-${VERSION}-${PLATFORM}.tar.gz"
URL="https://github.com/terraform-docs/terraform-docs/releases/download/${VERSION}/${ARCHIVE}"
DOWNLOAD="$(mktemp -d "${RUNNER_TEMP}/setup-terraform-docs-download.XXXXXX")"
trap 'rm -rf "${DOWNLOAD}"' EXIT
BIN_DIR="${RUNNER_TEMP}/terraform-docs-${VERSION}"

echo "Downloading ${URL}"
curl -fsSL --proto '=https' --retry 3 -o "${DOWNLOAD}/${ARCHIVE}" "${URL}"
if ! echo "${DIGEST}  ${DOWNLOAD}/${ARCHIVE}" | sha256sum --check --strict --quiet -; then
	fail "${ARCHIVE} does not match the SHA-256 ${DIGEST}. Nothing was installed."
fi
rm -rf "${BIN_DIR}"
mkdir -p "${BIN_DIR}"
tar -xzf "${DOWNLOAD}/${ARCHIVE}" -C "${BIN_DIR}" terraform-docs
chmod 0755 "${BIN_DIR}/terraform-docs"

# `terraform-docs --version` prints "terraform-docs version v0.24.0 <commit> linux/amd64".
if ! REPORTED="$("${BIN_DIR}/terraform-docs" --version)"; then
	fail "${BIN_DIR}/terraform-docs --version failed. Nothing was added to PATH."
fi
echo "terraform-docs --version: ${REPORTED}"
if [[ "${REPORTED}" != "terraform-docs version ${VERSION}" && "${REPORTED}" != "terraform-docs version ${VERSION} "* ]]; then
	fail "${BIN_DIR}/terraform-docs reports '${REPORTED}', not version ${VERSION}. Nothing was added to PATH."
fi

echo "${BIN_DIR}" >>"${GITHUB_PATH}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "path=${BIN_DIR}" >>"${GITHUB_OUTPUT}"
fi
echo "Installed terraform-docs ${VERSION} (${PLATFORM}) at ${BIN_DIR}."
