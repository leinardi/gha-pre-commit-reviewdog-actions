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
# Installs reviewdog (github.com/reviewdog/reviewdog) from its release archive, checked against a
# pinned SHA-256, into $RUNNER_TEMP and onto $GITHUB_PATH. Nothing is installed system-wide, so
# no sudo, and reviewdog/action-setup (which downloads without a checksum) is not needed.
#
# Inputs (environment): RUNNER_OS (Linux or macOS), RUNNER_ARCH (X64 or ARM64), RUNNER_TEMP and
# GITHUB_PATH, all set by the runner. The version is pinned here, not an input: every action of
# this repository reports through the same reviewdog.
#
# Outputs (to $GITHUB_OUTPUT when set):
#   path  the directory holding the reviewdog binary, as added to $GITHUB_PATH
#
# Any failure (an unsupported runner, the download, the checksum, a binary that reports another
# version) exits non-zero before anything is added to $GITHUB_PATH.

set -euo pipefail

# Pinned by hand as one unit: the version and the SHA-256 of each archive, from the release's
# checksums.txt (`gh release download v0.21.2 -R reviewdog/reviewdog -p checksums.txt -O -`, which
# matches the digests the GitHub API reports for the assets). Dependabot does not track a release
# download, so bump them together.
VERSION=0.21.2
SHA256_LINUX_X86_64=30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51
SHA256_LINUX_ARM64=56854c078853ea53c73e1e4d627e6a90d6b68185c46edd46aad8beb94564b948
SHA256_DARWIN_X86_64=3002ad37ee7d344de25e3c630a293aa322fc10d7b9c3fc6d4e836b616d084ae5
SHA256_DARWIN_ARM64=54497b0f3378936caa22a3a11d796acefe4d5f35d86f5cc84c622f941c3c0c68

fail() {
	echo "::error title=setup-reviewdog::$*" >&2
	exit 1
}

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
Linux/X64) PLATFORM=Linux_x86_64 SHA256="${SHA256_LINUX_X86_64}" ;;
Linux/ARM64) PLATFORM=Linux_arm64 SHA256="${SHA256_LINUX_ARM64}" ;;
macOS/X64) PLATFORM=Darwin_x86_64 SHA256="${SHA256_DARWIN_X86_64}" ;;
macOS/ARM64) PLATFORM=Darwin_arm64 SHA256="${SHA256_DARWIN_ARM64}" ;;
*) fail "reviewdog is installed on Linux and macOS runners, X64 or ARM64 only (RUNNER_OS is '${RUNNER_OS:-unset}', RUNNER_ARCH is '${RUNNER_ARCH:-unset}'). Nothing was installed." ;;
esac
if [[ -z "${RUNNER_TEMP:-}" ]] || [[ -z "${GITHUB_PATH:-}" ]]; then
	fail "RUNNER_TEMP and GITHUB_PATH must be set (they are, on a GitHub runner). Nothing was installed."
fi

# macOS runners have shasum rather than GNU sha256sum; both take the same check line.
if command -v sha256sum >/dev/null; then
	check_sha256() { sha256sum --check --strict --quiet -; }
elif command -v shasum >/dev/null; then
	check_sha256() { shasum -a 256 --check --strict --quiet -; }
else
	fail "neither sha256sum nor shasum is on PATH, so the download cannot be checked. Nothing was installed."
fi

ARCHIVE="reviewdog_${VERSION}_${PLATFORM}.tar.gz"
URL="https://github.com/reviewdog/reviewdog/releases/download/v${VERSION}/${ARCHIVE}"
# The archive is fetched next to, not into, the directory that goes on PATH: only the binary is
# put there.
DOWNLOAD="$(mktemp -d "${RUNNER_TEMP}/setup-reviewdog-download.XXXXXX")"
trap 'rm -rf "${DOWNLOAD}"' EXIT
BIN_DIR="${RUNNER_TEMP}/reviewdog-${VERSION}"

echo "Downloading ${URL}"
curl -fsSL --proto '=https' --retry 3 -o "${DOWNLOAD}/${ARCHIVE}" "${URL}"
if ! echo "${SHA256}  ${DOWNLOAD}/${ARCHIVE}" | check_sha256; then
	fail "${ARCHIVE} does not match the SHA-256 ${SHA256}. Nothing was installed."
fi
rm -rf "${BIN_DIR}"
mkdir -p "${BIN_DIR}"
tar -xzf "${DOWNLOAD}/${ARCHIVE}" -C "${BIN_DIR}" reviewdog
chmod 0755 "${BIN_DIR}/reviewdog"

# The archive is the one checked, but its binary must also be the version pinned: a wrong pin (the
# checksum of another version's archive) fails here instead of running the wrong reviewdog.
if ! REPORTED="$("${BIN_DIR}/reviewdog" -version)"; then
	fail "${BIN_DIR}/reviewdog -version failed. Nothing was added to PATH."
fi
echo "reviewdog -version: ${REPORTED}"
# reviewdog prints the bare version ("0.21.2"); a leading v is tolerated.
if [[ "${REPORTED#v}" != "${VERSION}" ]]; then
	fail "${BIN_DIR}/reviewdog reports version '${REPORTED}', not ${VERSION}. Nothing was added to PATH."
fi

echo "${BIN_DIR}" >>"${GITHUB_PATH}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "path=${BIN_DIR}" >>"${GITHUB_OUTPUT}"
fi
echo "Installed reviewdog ${VERSION} (${PLATFORM}) at ${BIN_DIR}."
