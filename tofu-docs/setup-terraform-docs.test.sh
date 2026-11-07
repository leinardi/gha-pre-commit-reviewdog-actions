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
# Tests setup-terraform-docs.sh with curl, sha256sum and tar stubs on a PATH that holds only the
# tools the script needs, so no network is used and nothing downloaded is ever run: curl writes a
# placeholder, sha256sum records the line it is asked to check and answers with $STUB_SHA_RC, and
# tar "extracts" a fake terraform-docs that prints $STUB_REPORT for --version. The real download
# against the pinned digests is exercised by the CI self-test.
#
# Run: bash tofu-docs/setup-terraform-docs.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/setup-terraform-docs.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
for tool in bash env mktemp rm mkdir chmod cat; do
	ln -s "$(command -v "${tool}")" "${WORK}/bin/${tool}"
done
cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_CALLS}"
out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift 2 ;;
	*) shift ;;
	esac
done
if [ -n "${STUB_CURL_FAIL:-}" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
echo placeholder >"${out}"
STUB
cat >"${WORK}/bin/sha256sum" <<'STUB'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >>"${STUB_CALLS}"
cat >>"${STUB_CALLS}"
exit "${STUB_SHA_RC:-0}"
STUB
cat >"${WORK}/bin/tar" <<'STUB'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >>"${STUB_CALLS}"
dir=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-C) dir=$2; shift 2 ;;
	*) shift ;;
	esac
done
printf '#!/usr/bin/env bash\n[ "$1" = --version ] || exit 9\necho "%s"\n' "${STUB_REPORT}" >"${dir}/terraform-docs"
STUB
chmod +x "${WORK}/bin/curl" "${WORK}/bin/sha256sum" "${WORK}/bin/tar"

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

# install [ENV=VALUE...]: runs the script on a fresh runner. Sets STATUS, LOG, GH_PATH, OUTPUT,
# CALLS and RUNNER.
N=0
install() {
	N=$((N + 1))
	RUNNER="${WORK}/runner-${N}"
	mkdir -p "${RUNNER}/temp"
	: >"${RUNNER}/calls"
	: >"${RUNNER}/path"
	: >"${RUNNER}/output"
	STATUS=0
	LOG="$(env -i PATH="${WORK}/bin" STUB_CALLS="${RUNNER}/calls" STUB_REPORT="terraform-docs version v0.24.0 abc1234 linux/amd64" \
		TERRAFORM_DOCS_VERSION=v0.24.0 RUNNER_OS=Linux RUNNER_ARCH=X64 \
		RUNNER_TEMP="${RUNNER}/temp" GITHUB_PATH="${RUNNER}/path" GITHUB_OUTPUT="${RUNNER}/output" "$@" \
		bash "${SCRIPT}" 2>&1)" || STATUS=$?
	GH_PATH="$(cat "${RUNNER}/path")"
	OUTPUT="$(cat "${RUNNER}/output")"
	CALLS="$(cat "${RUNNER}/calls")"
}
expect_fail() {
	local name="$1" pattern="$2"
	if [[ "${STATUS}" -ne 0 ]] && grep -q -- "${pattern}" <<<"${LOG}" && [[ -z "${GH_PATH}" && -z "${OUTPUT}" ]]; then
		ok "${name}"
	else
		not_ok "${name} (want a failure matching '${pattern}' and nothing on PATH, status ${STATUS})" "${LOG}
PATH: ${GH_PATH}"
	fi
}
expect_ok() { # NAME ARCHIVE DIGEST BIN_VERSION
	local name="$1" archive="$2" digest="$3" version="$4" bin
	bin="${RUNNER}/temp/terraform-docs-${version}"
	if [[ "${STATUS}" -eq 0 && "${GH_PATH}" == "${bin}" && "${OUTPUT}" == "path=${bin}" && -x "${bin}/terraform-docs" ]] &&
		grep -qE -- "^curl -fsSL --proto =https --retry 3 -o .*/${archive//./\\.} https://github\\.com/terraform-docs/terraform-docs/releases/download/${version//./\\.}/${archive//./\\.}$" <<<"${CALLS}"; then
		if grep -qx 'sha256sum --check --strict --quiet -' <<<"${CALLS}" && grep -qE "^${digest}  .*/${archive//./\\.}$" <<<"${CALLS}" &&
			grep -qE "^tar -xzf .*/${archive//./\\.} -C .*/terraform-docs-${version//./\\.} terraform-docs$" <<<"${CALLS}"; then
			ok "${name}"
			return
		fi
	fi
	not_ok "${name}" "status ${STATUS}${LOG:+
${LOG}}
${CALLS}"
}

install
expect_ok "v0.24.0 on Linux X64: https-only download with retries, strict sha256, only the binary, onto GITHUB_PATH" \
	terraform-docs-v0.24.0-linux-amd64.tar.gz 9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3 v0.24.0
if [[ -z "$(find "${RUNNER}/temp" -name '*.tar.gz')" && -z "$(find "${RUNNER}/temp" -maxdepth 1 -name 'setup-terraform-docs-download.*')" ]]; then
	ok "the downloaded archive is removed"
else
	not_ok "the downloaded archive is removed" "$(find "${RUNNER}/temp")"
fi
install RUNNER_ARCH=ARM64 STUB_REPORT="terraform-docs version v0.24.0 abc1234 linux/arm64"
expect_ok "Linux ARM64 gets the arm64 archive and its sha256" \
	terraform-docs-v0.24.0-linux-arm64.tar.gz d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd v0.24.0
install TERRAFORM_DOCS_VERSION=0.22.0 STUB_REPORT="terraform-docs version v0.22.0 abc1234 linux/amd64"
expect_ok "a version without its v (v1's default v0.22.0) is accepted and normalised" \
	terraform-docs-v0.22.0-linux-amd64.tar.gz 8ec66616777c66f3e622af4f2853e8ae399f38908ad4b262c9c526dd42501369 v0.22.0
install TERRAFORM_DOCS_VERSION=v0.23.0 RUNNER_ARCH=ARM64 STUB_REPORT="terraform-docs version v0.23.0"
expect_ok "v0.23.0 ARM64 is pinned too, and a bare version line is accepted" \
	terraform-docs-v0.23.0-linux-arm64.tar.gz f3be6f09fb0913c752b78480fac1eb4916e9ee50da7e3eb0bdaa356d80ed16b5 v0.23.0

install TERRAFORM_DOCS_VERSION=v0.21.0
expect_fail "a version without a pinned sha256 is refused" "has no pinned SHA-256 here; supported: v0.22.0, v0.23.0, v0.24.0"
if [[ -z "${CALLS}" ]]; then ok "an unpinned version downloads nothing"; else not_ok "an unpinned version downloads nothing" "${CALLS}"; fi
for bad in "" latest "v0.24" "v0.24.0;id" "-v0.24.0" "v0.24.0 "; do
	install TERRAFORM_DOCS_VERSION="${bad}"
	expect_fail "terraform-docs-version '${bad}' is refused" "must be vX.Y.Z or X.Y.Z"
done
install TERRAFORM_DOCS_VERSION=$'v0.24.0\n::error::injected 100%'
expect_fail "a version with a line break cannot inject a workflow command: %, CR and LF are escaped" "v0.24.0%0A::error::injected 100%25"
if ! grep -q "^::error::injected" <<<"${LOG}"; then ok "no injected command line"; else not_ok "no injected command line" "${LOG}"; fi
install STUB_SHA_RC=1
expect_fail "an archive that does not match the sha256 fails" "does not match the SHA-256 9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3"
if ! grep -q '^tar ' <<<"${CALLS}"; then ok "a mismatching archive is never extracted"; else not_ok "a mismatching archive is never extracted" "${CALLS}"; fi
install STUB_CURL_FAIL=1
expect_fail "a failed download fails" "404"
install STUB_REPORT="terraform-docs version v0.24.01 abc linux/amd64"
expect_fail "a binary that reports another version fails" "not version v0.24.0"
install RUNNER_OS=macOS
expect_fail "a macOS runner is refused" "Linux runners, X64 or ARM64 only"
install RUNNER_ARCH=X86
expect_fail "an unsupported architecture is refused" "X64 or ARM64 only"
install GITHUB_PATH=
expect_fail "a missing GITHUB_PATH is refused" "RUNNER_TEMP and GITHUB_PATH must be set"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
