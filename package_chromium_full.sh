#!/bin/bash
# This script packages a complete, buildable Chromium source environment into a
# tarball: full source, third_party dependencies, the prebuilt Clang/LLVM
# toolchain, the Rust toolchain, Linux sysroot(s), hook dependencies, PGO
# profiles, plus depot_tools and the gclient config.
#
# Unlike the "distribution tarball" tooling this script does NOT strip anything
# needed to build Chromium offline.
#
# Usage:
#   package_chromium_full.sh <version> <arch>
#
# Example:
#   package_chromium_full.sh 140.0.7339.82 arm64
#   package_chromium_full.sh 126.0.6478.126 loong64
#   package_chromium_full.sh 150.0.7871.211 loong64
#
# Environment:
#   ZSTD_LEVEL            zstd compression level (default: 6)
#   SPLIT_PART_SZ         split part size (default: 1900M, below the 2GiB GitHub
#                         Release per-file limit)
#   DOWNLOAD_TIMEOUT_SECS per-attempt curl timeout for downloads (default: 14400)
#   DOWNLOAD_RETRIES      download attempts before giving up (default: 5)

base=$(cd "$(dirname $0)" && pwd)
source "${base}/logging.sh" || exit

set -euo pipefail
umask 022

SPLIT_PART_SZ="${SPLIT_PART_SZ:-1900M}"
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"
DOWNLOAD_TIMEOUT_SECS="${DOWNLOAD_TIMEOUT_SECS:-14400}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-5}"
PGO_GS_URL_BASE="chromium-optimization-profiles/pgo_profiles"

# LoongArch64 (loong64) is not supported by upstream Chromium: there is no
# official sysroot or Clang/LLVM toolchain for it. Both are provided by
# Loongnix (https://github.com/loongson/chromium, loongarch-patches branch),
# only for the Chromium versions listed below. The "new world" (新世界)
# resources share one sysroot, and the toolchain and adaptation patch are
# named per Chromium major version.
LOONG64_SUPPORTED_MAJOR_VERSIONS="126 150"
LOONG64_SYSROOT_URL="http://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loongarch64-sysroot.tar.bz2"

# The LoongArch64 "old world" (旧世界, la64) ABI differs from the new world
# at the ABI level. Loongnix provides separate old-world resources (the
# adaptation patch covers both worlds via the "use_nw" GN argument).
# The old-world LLVM is a gzip tarball installed to /opt (the patch hard-codes
# its clang.gni path), and the old-world Rust toolchain likewise goes to /opt
# (used by build/cross-build.sh via rust_bindgen_root/rust_sysroot_absolute).
LA64_SUPPORTED_MAJOR_VERSIONS="150"
LA64_SYSROOT_URL="http://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2"
LA64_TOOLCHAIN_URL="http://ftp.loongnix.cn/toolchain/llvm/llvm20/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz"
LA64_TOOLCHAIN_DIR="llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10"
LA64_RUST_URL="http://ftp.loongnix.cn/browser/build/toolchain/rust-1.92.0-nightly-cross.tar.bz2"
LA64_RUST_DIR="rust-1.92.0-nightly-cross"

loong64_supported() {
	local major="${1}"
	case " ${LOONG64_SUPPORTED_MAJOR_VERSIONS} " in
		*" ${major} "*) return 0 ;;
		*) return 1 ;;
	esac
}

# Loongnix names the new-world toolchain "Release+Asserts-<major>.tar.bz2"
loong64_toolchain_url() {
	local major="${1}"
	echo "http://ftp.loongnix.cn/browser/build/toolchain/Release+Asserts-${major}.tar.bz2"
}

# Loongnix names the adaptation patch
# "chromium<major>/0001-la64-cross-CH<major>-Add-loongarch-build-support-for-old-new-w.patch"
loong64_patch_url() {
	local major="${1}"
	echo "https://github.com/loongson/chromium/raw/loongarch-patches/chromium${major}/0001-la64-cross-CH${major}-Add-loongarch-build-support-for-old-new-w.patch"
}

loong64_patch_file() {
	local major="${1}"
	echo "0001-la64-cross-CH${major}-Add-loongarch-build-support-for-old-new-w.patch"
}

la64_supported() {
	local major="${1}"
	case " ${LA64_SUPPORTED_MAJOR_VERSIONS} " in
		*" ${major} "*) return 0 ;;
		*) return 1 ;;
	esac
}

log_disk() {
	clog "Disk usage:"
	df -h . | sed 's/^/    /'
}

# This function clones one of Google's Chromium-related tool repositories.
#
# Usage:
#   get_google_repo REPO_BASENAME
#
get_google_repo() {
	local repo="${1}"
	if [[ -d "${repo}" ]]; then
		clog "${repo} repository already exists, pulling latest changes"
		pushd "${repo}" &> /dev/null || die "Failed to enter ${repo} directory"
		if [ "$(git symbolic-ref --short -q HEAD)" == "" ]; then
			clog "Currently in a detached HEAD state, switching to main branch"
			git switch main || die "Failed to switch to main branch in ${repo} repository"
		fi
		git pull || die "Failed to pull latest changes in ${repo} repository"
		popd &> /dev/null || die "Failed to exit ${repo} directory"
	else
		clog "Cloning ${repo} repository"
		git clone -q --depth=1 "https://chromium.googlesource.com/chromium/tools/${repo}.git" ||
			die "Failed to clone ${repo} repository"
	fi
}

# This function configures the gclient for Chromium development.
#
# Usage:
#   configure_gclient(version)
#
configure_gclient() {
	local version="${1}"
	if [ -z "${version}" ]; then
		die "${FUNCNAME}: No version specified"
	fi
	clog "Configuring gclient with version ${version}"
	gclient config --name src "https://chromium.googlesource.com/chromium/src.git@${version}" ||
		die "Failed to configure gclient with version ${version}"
	echo "target_os = [ 'linux' ]" >> .gclient
}

sync_sources() {
	clog "Syncing Chromium sources (no history, no hooks)"
	gclient sync -D --nohooks --no-history ||
		die "gclient sync failed"
}

# LoongArch64 is not supported by upstream Chromium, so the Loongson port
# patch has to be applied on top of the checked out sources. It is applied
# right after the sync so a broken patch fails before the expensive hooks.
# The same patch covers both the old world (la64) and new world (loong64)
# builds; the world is selected at build time via the "use_nw" GN argument.
#
# Usage:
#   apply_target_patches(arch)
#
apply_target_patches() {
	local arch="${1}"
	local major="${2}"
	case "${arch}" in
		loong64 | la64)
			local patch_file
			patch_file=$(loong64_patch_file "${major}")

			clog "Downloading LoongArch64 adaptation patch (chromium${major})"
			download_file "$(loong64_patch_url "${major}")" "${patch_file}"

			clog "Applying ${patch_file} to src"
			pushd src &> /dev/null || die "Failed to enter src directory"
			patch -Np1 -i "../${patch_file}" ||
				die "Failed to apply ${patch_file} (is \"patch\" installed?)"
			popd &> /dev/null || die "Failed to leave src directory"

			rm -f "${patch_file}"
			;;
	esac
}

run_hooks() {
	clog "Running gclient hooks (Clang/LLVM, sysroots, Node.js, ...)"
	gclient runhooks ||
		die "gclient runhooks failed"
}

download_pgo_profiles() {
	clog "Downloading Chromium PGO profiles"
	# Pre-downloading places the profile under src/chrome/build/pgo_profiles/,
	# where "gn gen" (chrome_pgo_phase=2) resolves it without network access.
	src/tools/update_pgo_profiles.py \
		--target=linux \
		update \
		--gs-url-base="${PGO_GS_URL_BASE}" ||
		die "Failed to update PGO profiles"
}

download_v8_pgo_profiles() {
	clog "Downloading V8 PGO profiles"
	# --check-v8-revision was added in later V8 versions (e.g. v8 13.x used by
	# Chromium 140) and is unknown to older ones (e.g. v8 12.6 used by Chromium
	# 126), so fall back to the plain invocation.
	if ! src/v8/tools/builtins-pgo/download_profiles.py \
		--force \
		--check-v8-revision \
		--depot-tools depot_tools \
		download
	then
		cwarn "--check-v8-revision unsupported on this V8 version, retrying without it"
		src/v8/tools/builtins-pgo/download_profiles.py \
			--force \
			--depot-tools depot_tools \
			download ||
			die "Failed to download V8 PGO profiles"
	fi
}

# This function downloads a file with resumable retry logic. Large files
# (e.g. the Loongnix toolchain tarballs) are often cut off mid-transfer by
# the server (curl error 18), which curl's built-in --retry does not retry.
# Failed attempts are resumed with "curl -C -" instead of restarting, so only
# the remaining bytes are re-downloaded.
#
# Usage:
#   download_file URL DEST_PATH
#
download_file() {
	local url="${1}"
	local output="${2}"
	local attempt=1

	until curl --fail --location \
		--retry 3 --retry-delay 5 \
		--connect-timeout 60 \
		--max-time "${DOWNLOAD_TIMEOUT_SECS}" \
		-sS \
		-C - -o "${output}" "${url}"
	do
		local status=$?
		if [ "${attempt}" -ge "${DOWNLOAD_RETRIES}" ]; then
			die "Failed to download ${url} after ${attempt} attempts (last exit code: ${status})"
		fi
		attempt=$((attempt + 1))
		cwarn "Download of ${url} interrupted (curl exit ${status}), resuming (attempt ${attempt}/${DOWNLOAD_RETRIES})"
		sleep 5
	done
}

# This function downloads a tarball and extracts it into a directory.
# Both .tar.bz2 and .tar.gz archives are supported.
#
# Usage:
#   download_and_extract URL DEST_DIR
#
download_and_extract() {
	local url="${1}"
	local dest="${2}"
	local tmp_dir

	tmp_dir=$(mktemp -d) || die "Failed to create a temporary download directory"
	local archive="${tmp_dir}/$(basename "${url}")"

	download_file "${url}" "${archive}"

	clog "Extracting $(basename "${archive}") into ${dest}"
	mkdir -p "${dest}" || die "Failed to create ${dest}"
	case "${archive}" in
		*.tar.gz | *.tgz) tar -xzf "${archive}" -C "${dest}" ;;
		*) tar -xjf "${archive}" -C "${dest}" ;;
	esac ||
		die "Failed to extract ${archive} into ${dest}"

	rm -rf "${tmp_dir}"
}

install_target_sysroot() {
	local arch="${1}"
	case "${arch}" in
		amd64)
			clog "amd64/i386 sysroots are installed by hooks, nothing to do"
			;;
		arm64)
			clog "Installing arm64 Linux sysroot"
			src/build/linux/sysroot_scripts/install-sysroot.py --arch=arm64 ||
				die "Failed to install arm64 sysroot"
			;;
		loong64)
			clog "Installing loong64 (LoongArch64 new world) Linux sysroot from Loongnix"
			download_and_extract "${LOONG64_SYSROOT_URL}" "src/build/linux" ||
				die "Failed to install loong64 sysroot"
			;;
		la64)
			clog "Installing la64 (LoongArch64 old world) Linux sysroot from Loongnix"
			download_and_extract "${LA64_SYSROOT_URL}" "src/build/linux" ||
				die "Failed to install la64 sysroot"
			;;
	esac
}

# The upstream prebuilt Clang/LLVM toolchain has no LoongArch support, so
# loong64 (new world) builds use the Loongnix toolchain instead. It is
# installed after runhooks so the clang hook cannot overwrite it.
#
# The la64 (old world) build uses a separate Loongnix LLVM 20 toolchain and
# a Loongnix Rust cross toolchain. Both are hard-coded to /opt by the patch
# (clang.gni default_clang_base_path) and by build/cross-build.sh
# (rust_bindgen_root/rust_sysroot_absolute), so they are packaged under
# "opt/" inside the tarball; see install_opt_tools below.
install_target_toolchain() {
	local arch="${1}"
	local major="${2}"
	case "${arch}" in
		loong64)
			clog "Installing loong64 (LoongArch64 new world) Clang/LLVM toolchain from Loongnix (Release+Asserts-${major})"
			rm -rf "src/third_party/llvm-build/Release+Asserts"
			download_and_extract "$(loong64_toolchain_url "${major}")" "src/third_party/llvm-build" ||
				die "Failed to install loong64 toolchain"
			;;
		la64)
			clog "Packaging la64 (LoongArch64 old world) LLVM 20 toolchain under opt/"
			download_and_extract "${LA64_TOOLCHAIN_URL}" "opt" ||
				die "Failed to download la64 toolchain"
			;;
	esac
}

# The la64 (old world) cross-build.sh expects the LLVM 20 toolchain and the
# Rust cross toolchain under /opt on the build host (paths hard-coded by the
# patch and the script). Package them under "opt/" so the build host can
# copy them into place before running build/cross-build.sh.
install_opt_tools() {
	local arch="${1}"
	case "${arch}" in
		la64)
			clog "Packaging la64 (LoongArch64 old world) Rust cross toolchain under opt/"
			download_and_extract "${LA64_RUST_URL}" "opt" ||
				die "Failed to download la64 Rust toolchain"
			;;
	esac
}

verify_toolchain() {
	local arch="${1}"
	local summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

	clog "Verifying toolchain and dependencies"

	local rustc_bin
	rustc_bin=$(find src/third_party/rust-toolchain -maxdepth 3 -type f -name rustc 2> /dev/null | head -n 1 || true)
	if [ -n "${rustc_bin}" ] && [ -x "${rustc_bin}" ]; then
		local rust_version
		rust_version=$("${rustc_bin}" --version | head -n 1)
		clog "Rust: ${rust_version}"
		echo "- Rust: \`${rust_version}\`" >> "${summary}" 2> /dev/null || true
	else
		die "Rust toolchain not found under src/third_party/rust-toolchain"
	fi

	if [ "${arch}" = "la64" ]; then
		# The old-world toolchains are packaged under opt/, not inside src/.
		local ow_clang_bin="opt/${LA64_TOOLCHAIN_DIR}/bin/clang"
		if [ -x "${ow_clang_bin}" ]; then
			local clang_version
			clang_version=$("${ow_clang_bin}" --version | head -n 1)
			clog "Clang (old world): ${clang_version}"
			echo "- Clang (old world): \`${clang_version}\`" >> "${summary}" 2> /dev/null || true
		else
			die "Clang toolchain not found at ${ow_clang_bin}"
		fi

		local ow_rust_bin="opt/${LA64_RUST_DIR}/bin/rustc"
		if [ -x "${ow_rust_bin}" ]; then
			clog "Rust cross toolchain (old world): ${LA64_RUST_DIR}"
		else
			die "Rust cross toolchain not found at ${ow_rust_bin}"
		fi

		local sysroot="src/build/linux/debian_bullseye_loong64-sysroot"
		if [ -d "${sysroot}" ]; then
			clog "Sysroot: $(basename "${sysroot}")"
			echo "- Sysroot: \`$(basename "${sysroot}")\`" >> "${summary}" 2> /dev/null || true
		else
			die "No la64 sysroot found at ${sysroot}"
		fi
		return
	fi

	local clang_bin="src/third_party/llvm-build/Release+Asserts/bin/clang"
	if [ -x "${clang_bin}" ]; then
		local clang_version
		clang_version=$("${clang_bin}" --version | head -n 1)
		clog "Clang: ${clang_version}"
		echo "- Clang: \`${clang_version}\`" >> "${summary}" 2> /dev/null || true
	else
		die "Clang toolchain not found at ${clang_bin}"
	fi

	local sysroot_pattern="*${arch}-sysroot"
	case "${arch}" in
		loong64) sysroot_pattern="*loongarch64-sysroot" ;;
	esac

	local sysroot
	sysroot=$(find src/build/linux -maxdepth 1 -type d -name "${sysroot_pattern}" | head -n 1 || true)
	if [ -n "${sysroot}" ]; then
		clog "Sysroot: $(basename "${sysroot}")"
		echo "- Sysroot: \`$(basename "${sysroot}")\`" >> "${summary}" 2> /dev/null || true
	else
		die "No ${arch} sysroot found under src/build/linux"
	fi
}

generate_manifest() {
	local version="${1}"
	local arch="${2}"
	local major="${3}"
	local revision sysroots
	revision=$(git -C src rev-parse HEAD 2> /dev/null || echo "unknown")
	sysroots=$(find src/build/linux -maxdepth 1 -type d -name "*-sysroot" -printf "  - %f\n" 2> /dev/null | sort)

	clog "Generating chromium-build-manifest.txt"
	cat > chromium-build-manifest.txt <<EOF
Project: chromium-full-src-tarballs

Chromium version: ${version}
Chromium revision: ${revision}

Target architecture: ${arch}
Host architecture: $(uname -m)

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Included:
- Chromium source
- Chromium third_party dependencies
- Chromium build tools
- Chromium Clang/LLVM toolchain
- Chromium Rust toolchain
- Linux sysroot
- Chromium hook dependencies
- Chromium PGO profiles (linux)
- V8 PGO profiles
- depot_tools and gclient config

Packaged sysroots:
${sysroots}

Cross compilation:
- Prebuilt toolchains run on x86_64 Linux hosts
- Cross build target: target_os="linux", target_cpu="${arch}"
- Host apt dependencies are NOT included; run
  ./build/install-build-deps.sh on the build host before building

Excluded:
- src/out
- Git metadata
EOF

	if [ "${arch}" = "loong64" ]; then
		cat >> chromium-build-manifest.txt <<EOF

LoongArch64 (loong64, new world):
- Chromium major version: ${major} (Loongnix port)
- Sysroot: ${LOONG64_SYSROOT_URL}
- Toolchain: $(loong64_toolchain_url "${major}")
- Patch: $(loong64_patch_url "${major}")
EOF
	fi

	if [ "${arch}" = "la64" ]; then
		cat >> chromium-build-manifest.txt <<EOF

LoongArch64 (la64, old world):
- Chromium major version: ${major} (Loongnix port)
- Sysroot: ${LA64_SYSROOT_URL}
- LLVM 20 toolchain: ${LA64_TOOLCHAIN_URL}
  (install to /opt before building: the patch hard-codes
   /opt/${LA64_TOOLCHAIN_DIR} in build/config/clang/clang.gni)
- Rust cross toolchain: ${LA64_RUST_URL}
  (install to /opt before building: build/cross-build.sh hard-codes
   /opt/${LA64_RUST_DIR} via rust_bindgen_root/rust_sysroot_absolute)
- Patch: $(loong64_patch_url "${major}")
EOF
	fi
}

# Git metadata must go per README; the package targets offline builds and
# revision info is preserved in the manifest.
cleanup_before_pack() {
	clog "Removing Git metadata"
	find . -name .git -prune -exec rm -rf {} +
	clog "Removing build output directories (if any)"
	rm -rf src/out src/out_*
}

# Stream tar|zstd|split so the (large) uncompressed archive never exists on
# disk; the full-file hash is computed afterwards by reading the parts back.
export_tarball() {
	local version="${1}"
	local arch="${2}"
	local pkg_name="chromium-full-src-${version}-linux-${arch}"

	mkdir -p out
	clog "Exporting ${pkg_name}.tar.zst (parts of ${SPLIT_PART_SZ}, zstd level ${ZSTD_LEVEL})"
	log_disk

	tar \
		--use-compress-program="zstd -T0 -${ZSTD_LEVEL}" \
		-C "${PWD}" \
		-cf - \
		"${pkg_name}" \
		| split -b "${SPLIT_PART_SZ}" -d -a 3 - "out/${pkg_name}.tar.zst.part-"

	clog "Generating hashes"
	local full_hash
	full_hash=$(cat "out/${pkg_name}".tar.zst.part-* | sha256sum | cut -d ' ' -f 1)
	echo "${full_hash}  ${pkg_name}.tar.zst" > out/SHA256SUMS
	(
		cd out &&
			sha256sum "${pkg_name}".tar.zst.part-* > SHA256SUMS.parts
	)

	log_disk
	clog "Hashes:"
	cat out/SHA256SUMS
	cat out/SHA256SUMS.parts

	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## Tarball"
			echo "- \`${pkg_name}.tar.zst\` sha256: \`${full_hash}\`"
			echo "- Parts: $(find out -name "${pkg_name}.tar.zst.part-*" | wc -l) x ${SPLIT_PART_SZ}"
		} >> "${GITHUB_STEP_SUMMARY}"
	fi
}

usage() {
	echo "Usage: $0 <version> <arch>"
	echo "Example: $0 140.0.7339.82 arm64"
	echo "         $0 150.0.7871.211 loong64   (new world)"
	echo "         $0 150.0.7871.211 la64      (old world)"
	exit 1
}

main() {
	local version="${1:-}"
	local arch="${2:-}"

	if [ -z "${version}" ] || [ -z "${arch}" ]; then
		usage
	fi
	shift 2
	if [ "$#" -gt 0 ]; then
		die "Unknown argument: $1"
	fi

	case "${arch}" in
		arm64 | amd64 | loong64 | la64) ;;
		*) die "Unsupported target architecture: ${arch} (expected arm64, amd64, loong64 or la64)" ;;
	esac

	if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		die "Invalid Chromium version: ${version}"
	fi

	# LoongArch64 is only available for the Loongnix port versions listed in
	# LOONG64_SUPPORTED_MAJOR_VERSIONS (new world) / LA64_SUPPORTED_MAJOR_VERSIONS
	# (old world); there is no sysroot or toolchain for any other version.
	local major="${version%%.*}"
	if [ "${arch}" = "loong64" ] && ! loong64_supported "${major}"; then
		die "LoongArch64 new world (loong64) requires Chromium ${LOONG64_SUPPORTED_MAJOR_VERSIONS// / or }.x, got ${version}"
	fi
	if [ "${arch}" = "la64" ] && ! la64_supported "${major}"; then
		die "LoongArch64 old world (la64) requires Chromium ${LA64_SUPPORTED_MAJOR_VERSIONS// / or }.x, got ${version}"
	fi

	# Some Google Python scripts start with "#!/usr/bin/env python"
	if ! python --version 2>&1 | grep -q '^Python 3\.'; then
		cwarn "\"python\" is not Python 3, creating a python3 shim in PATH"
		local shim_dir
		shim_dir=$(mktemp -d)
		ln -s "$(command -v python3)" "${shim_dir}/python"
		export PATH="${shim_dir}:${PATH}"
	fi

	export GIT_CONFIG_GLOBAL="${base}/gitconfig"
	export TZ=PST8PDT

	local pkg_name="chromium-full-src-${version}-linux-${arch}"

	clog "Packaging Chromium ${version} (target: ${arch}) into ${pkg_name}"
	log_disk

	mkdir -p "${pkg_name}"
	pushd "${pkg_name}" &> /dev/null || die "Failed to enter ${pkg_name}"

	get_google_repo depot_tools
	export PATH="${PWD}/depot_tools:${PATH}"

	configure_gclient "${version}"
	sync_sources
	apply_target_patches "${arch}" "${major}"
	run_hooks
	#	download_pgo_profiles
	download_v8_pgo_profiles
	# Note: the Rust toolchain is fetched by the unconditional DEPS hook
	# (src/tools/rust/update_rust.py) during runhooks; verify_toolchain below
	# fails the run if it is missing.
	install_target_sysroot "${arch}"
	install_target_toolchain "${arch}" "${major}"
	install_opt_tools "${arch}"
	verify_toolchain "${arch}"
	generate_manifest "${version}" "${arch}" "${major}"
	cleanup_before_pack

	popd &> /dev/null || die "Failed to leave ${pkg_name}"

	export_tarball "${version}" "${arch}"

	clog "Done: ${pkg_name}.tar.zst (split parts in out/)"
}

if [ "$#" -lt 2 ]; then
	usage
fi

main "$@"
