#!/usr/bin/env bash
# scripts/native-coverage.sh -- Build native/_covbuild with gcov
# instrumentation, run the native ctest suite, and emit a gcovr coverage
# report (console + Cobertura XML + HTML) scoped to native/src.
#
# REPORT-ONLY: this script never fails on a coverage threshold. It exits
# nonzero only if cmake configure, the build, or ctest fails. The C rANS
# kernels are SIMD-dispatched (scalar/SSE4.1/AVX2 chosen at runtime by CPU),
# so per-file line counts depend on the runner CPU and a floor would
# false-fail.
#
# Uses a dedicated build dir (native/_covbuild) so the uninstrumented
# native/_build reused by other jobs / local dev is never contaminated.
#
# Deps: cmake, ninja, a C compiler with matching gcov, zlib1g-dev, and
# gcovr >= 6.0 (the --gcov-ignore-parse-errors value below needs 6.0+;
# older gcovr fails with an unrelated-looking "unrecognized arguments").
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
BUILD_DIR="${NATIVE_DIR}/_covbuild"

# Optional ctest exclusion hook. As of R8 ALL 22 registered ctests pass
# clean (none need external fixtures), so the default is empty. The hook
# exists for the future: if a registered test ever requires an external
# on-disk fixture it cannot self-generate, set the env var to a ctest -E
# regex, e.g. TTIO_CTEST_EXCLUDE="some_fixture_test|another", and document
# the reason here.
CTEST_EXCLUDE="${TTIO_CTEST_EXCLUDE:-}"

echo "==> Configuring instrumented build at ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
cmake -S "${NATIVE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DTTIO_COVERAGE=ON -DBUILD_TESTING=ON

echo "==> Building"
cmake --build "${BUILD_DIR}"

echo "==> Running ctest"
if [ -n "${CTEST_EXCLUDE}" ]; then
    echo "    (excluding fixture-dependent tests: ${CTEST_EXCLUDE})"
    ( cd "${BUILD_DIR}" && ctest --output-on-failure -E "${CTEST_EXCLUDE}" )
else
    ( cd "${BUILD_DIR}" && ctest --output-on-failure )
fi

echo "==> Generating gcovr report (scoped to native/src)"
mkdir -p "${BUILD_DIR}/coverage-html"
gcovr \
    --root "${NATIVE_DIR}" \
    --filter "${NATIVE_DIR}/src/" \
    --print-summary \
    --xml-pretty -o "${BUILD_DIR}/coverage.xml" \
    --html-details "${BUILD_DIR}/coverage-html/index.html" \
    --gcov-ignore-parse-errors=negative_hits.warn_once_per_file \
    "${BUILD_DIR}"

echo "==> All ctests passed; native C coverage report written to ${BUILD_DIR}/coverage.xml"
