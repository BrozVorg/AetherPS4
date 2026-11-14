#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEX_SOURCE="${PROJECT_ROOT}/runtime/sources/fexcore-darwin"
BUILD_DIR="${PROJECT_ROOT}/runtime/build/fexcore-darwin-macos"
STAGE_DIR="${PROJECT_ROOT}/runtime/build/fexcore-darwin-macos-stage"
PATCH_PATH="${PROJECT_ROOT}/runtime/patches/fex-fexcore-only.patch"
SMOKE_SOURCE="${PROJECT_ROOT}/runtime/probes/fexcore-smoke.cpp"
GUEST_ENGINE_SOURCE="${PROJECT_ROOT}/src/core/fex/fex_guest_engine.cpp"
FEX_GUEST_CPU_SOURCE="${PROJECT_ROOT}/src/core/guest_cpu/fex_guest_cpu.cpp"
HLE_CALL_ADAPTER_SOURCE="${PROJECT_ROOT}/src/core/guest_cpu/hle_call_adapter.cpp"
FEX_HLE_BRIDGE_SOURCE="${PROJECT_ROOT}/src/core/guest_cpu/fex_hle_bridge.cpp"
GUEST_HARNESS_SOURCE="${PROJECT_ROOT}/runtime/probes/fexcore-guest-harness.cpp"

for tool in cmake ninja clang clang++ xcrun file lipo; do
  command -v "${tool}" >/dev/null || {
    echo "${tool} is required" >&2
    exit 1
  }
done

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This build must run on an Apple Silicon macOS runner (arm64)." >&2
  exit 1
fi

test -f "${FEX_SOURCE}/CMakeLists.txt" || {
  echo "Missing Darwin FEXCore source tree: ${FEX_SOURCE}" >&2
  exit 1
}
for source in "${SMOKE_SOURCE}" "${GUEST_ENGINE_SOURCE}" "${FEX_GUEST_CPU_SOURCE}" \
              "${HLE_CALL_ADAPTER_SOURCE}" "${FEX_HLE_BRIDGE_SOURCE}" "${GUEST_HARNESS_SOURCE}"; do
  test -f "${source}" || { echo "Missing build source: ${source}" >&2; exit 1; }
done

# The guest harness compiles AetherPS4 sources which include the project's
# logging wrapper. Fetch only the required spdlog submodule (not every project
# external) and expose its headers to the standalone FEXCore harness target.
SPDLOG_SOURCE="${PROJECT_ROOT}/externals/spdlog"
git -C "${PROJECT_ROOT}" submodule update --init --depth 1 -- externals/spdlog
SPDLOG_INCLUDE_DIR="${SPDLOG_SOURCE}/include"
test -f "${SPDLOG_INCLUDE_DIR}/spdlog/details/fmt_helper.h" || {
  echo "Missing spdlog headers after submodule checkout: ${SPDLOG_INCLUDE_DIR}" >&2
  exit 1
}

# The standalone guest harness also uses Boost ICL headers.
BOOST_SOURCE="${PROJECT_ROOT}/externals/ext-boost"
git -C "${PROJECT_ROOT}" submodule update --init --depth 1 -- externals/ext-boost
BOOST_INCLUDE_DIR="${BOOST_SOURCE}"
test -f "${BOOST_INCLUDE_DIR}/boost/icl/separate_interval_set.hpp" || {
  echo "Missing Boost ICL headers after submodule checkout: ${BOOST_INCLUDE_DIR}" >&2
  exit 1
}
# The FEXCore-only/smoke targets are added by the repository patch. The Darwin
# snapshot may already contain that patch; apply it only if the target hook is absent.
if ! grep -Fq "FEXCORE_GUEST_HARNESS_SOURCES" "${FEX_SOURCE}/CMakeLists.txt"; then
  test -f "${PATCH_PATH}" || {
    echo "Missing FEXCore-only patch: ${PATCH_PATH}" >&2
    exit 1
  }
  if git -C "${FEX_SOURCE}" apply --reverse --check "${PATCH_PATH}" >/dev/null 2>&1; then
    echo "FEXCore-only patch is already applied."
  elif git -C "${FEX_SOURCE}" apply --check "${PATCH_PATH}" >/dev/null 2>&1; then
    git -C "${FEX_SOURCE}" apply "${PATCH_PATH}"
  else
    echo "FEXCore-only patch does not apply to the Darwin snapshot; stopping without changing sources." >&2
    exit 1
  fi
fi

LLVM_PREFIX="$(dirname "$(dirname "$(command -v clang)")")"
# Keep the SDK from the installed Xcode while using the selected LLVM compiler.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

cmake -S "${FEX_SOURCE}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_C_COMPILER="$(command -v clang)" \
  -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
  -DCMAKE_OSX_SYSROOT="${SDKROOT}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DFEX_MAC_PHONE_PATH=1" \
  -DCMAKE_CXX_FLAGS="-DFEX_MAC_PHONE_PATH=1 -I${SPDLOG_INCLUDE_DIR} -I${BOOST_INCLUDE_DIR} -I${FEX_SOURCE}/FEXCore/Source" \
  -DCMAKE_DISABLE_FIND_PACKAGE_xxhash=ON \
  -DTUNE_CPU=none \
  -DBUILD_FEXCORE_ONLY=ON \
  -DFEXCORE_PROJECT_SOURCE_DIR="${PROJECT_ROOT}/src" \
  -DFEXCORE_SMOKE_SOURCE="${SMOKE_SOURCE}" \
  -DFEXCORE_GUEST_HARNESS_SOURCES="${GUEST_ENGINE_SOURCE};${FEX_GUEST_CPU_SOURCE};${HLE_CALL_ADAPTER_SOURCE};${FEX_HLE_BRIDGE_SOURCE};${GUEST_HARNESS_SOURCE}" \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DENABLE_GDB_SYMBOLS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_OFFLINE_TELEMETRY=OFF \
  -DENABLE_VIXL_DISASSEMBLER=OFF \
  -DENABLE_VIXL_SIMULATOR=OFF \
  -DENABLE_ZYDIS=OFF \
  -DENABLE_FEXCORE_PROFILER=OFF

cmake --build "${BUILD_DIR}" --target fexcore-smoke fexcore-guest-harness --parallel 2

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cmake --install "${BUILD_DIR}" --prefix "${STAGE_DIR}"

SMOKE_BIN="${STAGE_DIR}/bin/fexcore-smoke"
GUEST_BIN="${STAGE_DIR}/bin/fexcore-guest-harness"
test -x "${SMOKE_BIN}" || { echo "Missing installed fexcore-smoke" >&2; exit 1; }
test -x "${GUEST_BIN}" || { echo "Missing installed fexcore-guest-harness" >&2; exit 1; }

"${SMOKE_BIN}"
"${GUEST_BIN}"

for binary in "${SMOKE_BIN}" "${GUEST_BIN}"; do
  file "${binary}"
  ARCHS="$(lipo -archs "${binary}")"
  [[ "${ARCHS}" == "arm64" ]] || {
    echo "Expected arm64-only binary, got: ${ARCHS}" >&2
    exit 1
  }
done

printf '\nFEXCORE_DARWIN_ARM64_SMOKE_OK\n'
printf 'build_dir=%s\nstage_dir=%s\n' "${BUILD_DIR}" "${STAGE_DIR}"
