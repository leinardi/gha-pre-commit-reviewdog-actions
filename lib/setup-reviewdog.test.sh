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
# Tests setup-reviewdog.sh with curl, sha256sum, shasum and tar stubs on a PATH that holds only
# the tools the script needs, so no network is used and nothing downloaded is ever run: curl
# writes a placeholder, the checksum stubs record the line they are asked to check and answer
# with $STUB_SHA_RC, and tar "extracts" a fake reviewdog that prints $STUB_VERSION. The real
# download against the pinned digests is exercised by the CI self-tests.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/setup-reviewdog.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A PATH with only the tools the script uses, plus the stubs. A second one has no sha256sum, as
# on macOS.
mkdir -p "${WORK}/bin" "${WORK}/bin-mac"
for tool in bash env mktemp rm mkdir chmod cat; do
	ln -s "$(command -v "${tool}")" "${WORK}/bin/${tool}"
	ln -s "$(command -v "${tool}")" "${WORK}/bin-mac/${tool}"
done
cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS}"
out="" url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift 2 ;;
	--proto | --retry) shift 2 ;;
	-*) shift ;;
	*) url=$1; shift ;;
	esac
done
if [ -n "${STUB_CURL_FAIL:-}" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
echo "placeholder for ${url}" >"${out}"
STUB
cat >"${WORK}/bin/sha256sum" <<'STUB'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >>"${STUB_CALLS}"
cat >>"${STUB_CALLS}"
exit "${STUB_SHA_RC:-0}"
STUB
cat >"${WORK}/bin/shasum" <<'STUB'
#!/usr/bin/env bash
printf 'shasum %s\n' "$*" >>"${STUB_CALLS}"
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
printf '#!/usr/bin/env bash\n[ "$1" = -version ] || exit 9\necho "%s"\n' "${STUB_VERSION}" >"${dir}/reviewdog"
STUB
chmod +x "${WORK}/bin/curl" "${WORK}/bin/sha256sum" "${WORK}/bin/shasum" "${WORK}/bin/tar"
for stub in curl shasum tar; do ln -s "${WORK}/bin/${stub}" "${WORK}/bin-mac/${stub}"; done

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
	LOG="$(env -i PATH="${WORK}/bin" STUB_CALLS="${RUNNER}/calls" STUB_VERSION=0.21.2 RUNNER_OS=Linux RUNNER_ARCH=X64 \
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

URL=https://github.com/reviewdog/reviewdog/releases/download/v0.21.2
install
BIN="${RUNNER}/temp/reviewdog-0.21.2"
if [[ "${STATUS}" -eq 0 && "${GH_PATH}" == "${BIN}" && "${OUTPUT}" == "path=${BIN}" && -x "${BIN}/reviewdog" ]] &&
	grep -q "reviewdog -version: 0.21.2" <<<"${LOG}"; then
	ok "Linux X64 installs reviewdog onto GITHUB_PATH and checks its version"
else
	not_ok "Linux X64 installs reviewdog onto GITHUB_PATH and checks its version" "${LOG}
${CALLS}"
fi
if grep -qE -- "^-fsSL --proto =https --retry 3 -o .*/reviewdog_0\.21\.2_Linux_x86_64\.tar\.gz ${URL//./\\.}/reviewdog_0\.21\.2_Linux_x86_64\.tar\.gz$" <<<"${CALLS}"; then
	ok "the archive is fetched over https only, with retries, from the v0.21.2 release"
else
	not_ok "the archive is fetched over https only, with retries, from the v0.21.2 release" "${CALLS}"
fi
if grep -qx 'sha256sum --check --strict --quiet -' <<<"${CALLS}" &&
	grep -qE '^30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51  .*/reviewdog_0\.21\.2_Linux_x86_64\.tar\.gz$' <<<"${CALLS}"; then
	ok "the Linux x86_64 archive is checked strictly against its pinned sha256"
else
	not_ok "the Linux x86_64 archive is checked strictly against its pinned sha256" "${CALLS}"
fi
if grep -qE '^tar -xzf .*reviewdog_0\.21\.2_Linux_x86_64\.tar\.gz -C .*/reviewdog-0\.21\.2 reviewdog$' <<<"${CALLS}"; then
	ok "only the reviewdog binary is extracted, under RUNNER_TEMP/reviewdog-<version>"
else
	not_ok "only the reviewdog binary is extracted, under RUNNER_TEMP/reviewdog-<version>" "${CALLS}"
fi
if [[ -z "$(find "${RUNNER}/temp" -name '*.tar.gz')" && -z "$(find "${RUNNER}/temp" -maxdepth 1 -name 'setup-reviewdog-download.*')" ]]; then
	ok "the downloaded archive is removed"
else
	not_ok "the downloaded archive is removed" "$(find "${RUNNER}/temp")"
fi

install RUNNER_ARCH=ARM64
if [[ "${STATUS}" -eq 0 ]] && grep -qE '^56854c078853ea53c73e1e4d627e6a90d6b68185c46edd46aad8beb94564b948  .*/reviewdog_0\.21\.2_Linux_arm64\.tar\.gz$' <<<"${CALLS}" &&
	grep -q "${URL}/reviewdog_0.21.2_Linux_arm64.tar.gz$" <<<"${CALLS}"; then
	ok "Linux ARM64 gets the arm64 archive and its sha256"
else
	not_ok "Linux ARM64 gets the arm64 archive and its sha256" "${LOG}${CALLS}"
fi

for arch in X64:x86_64:3002ad37ee7d344de25e3c630a293aa322fc10d7b9c3fc6d4e836b616d084ae5 ARM64:arm64:54497b0f3378936caa22a3a11d796acefe4d5f35d86f5cc84c622f941c3c0c68; do
	IFS=: read -r runner_arch asset digest <<<"${arch}"
	N=$((N + 1))
	RUNNER="${WORK}/runner-${N}"
	mkdir -p "${RUNNER}/temp"
	: >"${RUNNER}/calls"
	: >"${RUNNER}/path"
	STATUS=0
	LOG="$(env -i PATH="${WORK}/bin-mac" STUB_CALLS="${RUNNER}/calls" STUB_VERSION=0.21.2 RUNNER_OS=macOS RUNNER_ARCH="${runner_arch}" \
		RUNNER_TEMP="${RUNNER}/temp" GITHUB_PATH="${RUNNER}/path" bash "${SCRIPT}" 2>&1)" || STATUS=$?
	CALLS="$(cat "${RUNNER}/calls")"
	if [[ "${STATUS}" -eq 0 && "$(cat "${RUNNER}/path")" == "${RUNNER}/temp/reviewdog-0.21.2" ]] &&
		grep -qx 'shasum -a 256 --check --strict --quiet -' <<<"${CALLS}" &&
		grep -qE "^${digest}  .*/reviewdog_0\\.21\\.2_Darwin_${asset}\\.tar\\.gz$" <<<"${CALLS}"; then
		ok "macOS ${runner_arch} gets the Darwin ${asset} archive, checked with shasum"
	else
		not_ok "macOS ${runner_arch} gets the Darwin ${asset} archive, checked with shasum" "${LOG}
${CALLS}"
	fi
done

install STUB_SHA_RC=1
expect_fail "an archive that does not match the sha256 fails" "does not match the SHA-256 30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51"
if ! grep -q '^tar ' <<<"${CALLS}"; then ok "a mismatching archive is never extracted"; else not_ok "a mismatching archive is never extracted" "${CALLS}"; fi

install STUB_CURL_FAIL=1
expect_fail "a failed download fails" "404"

install STUB_VERSION=0.21.1
expect_fail "a binary that reports another version fails" "reports version '0.21.1', not 0.21.2"

install RUNNER_OS=Windows
expect_fail "a Windows runner is refused" "Linux and macOS runners, X64 or ARM64 only"
if [[ -z "${CALLS}" ]]; then ok "an unsupported runner downloads nothing"; else not_ok "an unsupported runner downloads nothing" "${CALLS}"; fi
install RUNNER_ARCH=X86
expect_fail "an unsupported architecture is refused" "X64 or ARM64 only"
install RUNNER_TEMP=
expect_fail "a missing RUNNER_TEMP is refused" "RUNNER_TEMP and GITHUB_PATH must be set"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
