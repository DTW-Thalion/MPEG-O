cmake_minimum_required(VERSION 3.16)
project(ttio_rans C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(TTIO_RANS_ENABLE_TSAN
    "Build a separate test_thread_safety_tsan target with -fsanitize=thread" OFF)
option(TTIO_RANS_BUILD_JNI
    "Build the JNI wrapper library (libttio_rans_jni.so) for Java integration" OFF)

find_package(Threads REQUIRED)

add_library(ttio_rans SHARED
    src/rans_core.c
    src/rans_encode_scalar.c
    src/rans_decode_scalar.c
    src/rans_decode_streaming.c
    src/rans_decode_m94z.c
    src/rans_encode_adaptive.c
    src/rans_decode_adaptive.c
    src/rc_cram.c
    src/dispatch.c
    src/threadpool.c
    src/wire_format.c
)
target_include_directories(ttio_rans
    PUBLIC  include
    PRIVATE src
)
target_compile_options(ttio_rans PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(ttio_rans PRIVATE Threads::Threads)

# x86_64: build SSE4.1 / AVX2 kernels with appropriate per-file flags.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
    target_sources(ttio_rans PRIVATE
        src/rans_encode_sse41.c
        src/rans_decode_sse41.c
        src/rans_encode_avx2.c
        src/rans_decode_avx2.c
    )
    set_source_files_properties(
        src/rans_encode_sse41.c src/rans_decode_sse41.c
        PROPERTIES COMPILE_FLAGS "-msse4.1"
    )
    set_source_files_properties(
        src/rans_encode_avx2.c src/rans_decode_avx2.c
        PROPERTIES COMPILE_FLAGS "-mavx2"
    )
endif()

# Install
install(TARGETS ttio_rans LIBRARY DESTINATION lib)
install(FILES include/ttio_rans.h DESTINATION include)

# Optional JNI wrapper.  Enable with `-DTTIO_RANS_BUILD_JNI=ON`.
# Java loads the library by base name "ttio_rans_jni" via System.loadLibrary,
# which expands to libttio_rans_jni.so / libttio_rans_jni.dylib /
# ttio_rans_jni.dll on Linux/macOS/Windows respectively.
if(TTIO_RANS_BUILD_JNI)
    # We only need the jni.h headers — not AWT, which is missing on
    # headless JDK installs. Use Java::JNI from FindJavaInclude when
    # available; otherwise fall back to manual JAVA_HOME probing.
    find_package(JNI COMPONENTS JVM)
    if(NOT JNI_INCLUDE_DIRS)
        # Manual fallback: probe $JAVA_HOME/include and the standard
        # Debian/Ubuntu JDK location.
        if(DEFINED ENV{JAVA_HOME})
            set(_jdk_root "$ENV{JAVA_HOME}")
        else()
            execute_process(
                COMMAND bash -c "readlink -f $(which javac) | sed 's|/bin/javac||'"
                OUTPUT_VARIABLE _jdk_root
                OUTPUT_STRIP_TRAILING_WHITESPACE)
        endif()
        if(_jdk_root AND EXISTS "${_jdk_root}/include/jni.h")
            set(JNI_INCLUDE_DIRS "${_jdk_root}/include" "${_jdk_root}/include/linux")
            message(STATUS "JNI: using ${_jdk_root}/include (manual probe)")
        else()
            message(FATAL_ERROR "JNI headers not found; set JAVA_HOME to a JDK")
        endif()
    endif()
    add_library(ttio_rans_jni SHARED src/ttio_rans_jni.c)
    target_link_libraries(ttio_rans_jni PRIVATE ttio_rans)
    target_include_directories(ttio_rans_jni PRIVATE ${JNI_INCLUDE_DIRS})
    target_compile_options(ttio_rans_jni PRIVATE -Wall -Wextra -Wpedantic)
    set_target_properties(ttio_rans_jni PROPERTIES PREFIX "lib")
    install(TARGETS ttio_rans_jni LIBRARY DESTINATION lib)
endif()

# Tests
enable_testing()
add_executable(test_roundtrip tests/test_roundtrip.c)
target_link_libraries(test_roundtrip ttio_rans)
target_compile_options(test_roundtrip PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME roundtrip COMMAND test_roundtrip)

add_executable(test_thread_safety tests/test_thread_safety.c)
target_link_libraries(test_thread_safety PRIVATE ttio_rans Threads::Threads)
target_compile_options(test_thread_safety PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME thread_safety COMMAND test_thread_safety)

add_executable(test_v2_format tests/test_v2_format.c)
target_link_libraries(test_v2_format PRIVATE ttio_rans Threads::Threads)
target_compile_options(test_v2_format PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME v2_format COMMAND test_v2_format)

add_executable(test_streaming tests/test_streaming.c)
target_link_libraries(test_streaming PRIVATE ttio_rans)
target_compile_options(test_streaming PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME streaming COMMAND test_streaming)

add_executable(test_m94z_decode tests/test_m94z_decode.c)
target_link_libraries(test_m94z_decode PRIVATE ttio_rans)
target_compile_options(test_m94z_decode PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME m94z_decode COMMAND test_m94z_decode)

# L2: adaptive M94.Z (CRAM-mimic) tests.
add_executable(test_adaptive_roundtrip tests/test_adaptive_roundtrip.c)
target_link_libraries(test_adaptive_roundtrip PRIVATE ttio_rans)
target_compile_options(test_adaptive_roundtrip PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME adaptive_roundtrip COMMAND test_adaptive_roundtrip)

add_executable(test_adaptive_byte_pairing tests/test_adaptive_byte_pairing.c)
target_link_libraries(test_adaptive_byte_pairing PRIVATE ttio_rans)
target_compile_options(test_adaptive_byte_pairing PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME adaptive_byte_pairing COMMAND test_adaptive_byte_pairing)

add_executable(test_adaptive_halve_boundary tests/test_adaptive_halve_boundary.c)
target_link_libraries(test_adaptive_halve_boundary PRIVATE ttio_rans)
target_compile_options(test_adaptive_halve_boundary PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME adaptive_halve_boundary COMMAND test_adaptive_halve_boundary)

add_executable(test_adaptive_max_sym_bounds tests/test_adaptive_max_sym_bounds.c)
target_link_libraries(test_adaptive_max_sym_bounds PRIVATE ttio_rans)
target_compile_options(test_adaptive_max_sym_bounds PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME adaptive_max_sym_bounds COMMAND test_adaptive_max_sym_bounds)
# Phase 1 byte-equality gate: rc_cram vs htscodecs reference.
# Run manually: ./test_rc_cram_byte_equal /tmp/rc_cram_ours.bin
# then cmp /tmp/rc_cram_ours.bin /tmp/rc_cram_htscodecs.bin
add_executable(test_rc_cram_byte_equal tests/test_rc_cram_byte_equal.c)
target_include_directories(test_rc_cram_byte_equal PRIVATE src)
target_link_libraries(test_rc_cram_byte_equal ttio_rans)
target_compile_options(test_rc_cram_byte_equal PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME rc_cram_byte_equal COMMAND test_rc_cram_byte_equal)


# Optional ThreadSanitizer build of the same test, gated by an option so
# the default ctest run remains fast and portable.  Enable with:
#   cmake -DTTIO_RANS_ENABLE_TSAN=ON ..
if(TTIO_RANS_ENABLE_TSAN)
    add_library(ttio_rans_tsan SHARED
        src/rans_core.c
        src/rans_encode_scalar.c
        src/rans_decode_scalar.c
        src/rans_decode_streaming.c
        src/dispatch.c
        src/threadpool.c
        src/wire_format.c
    )
    target_include_directories(ttio_rans_tsan
        PUBLIC  include
        PRIVATE src
    )
    target_compile_options(ttio_rans_tsan PRIVATE
        -Wall -Wextra -Wpedantic -g -O1 -fsanitize=thread)
    target_link_options(ttio_rans_tsan PRIVATE -fsanitize=thread)
    target_link_libraries(ttio_rans_tsan PRIVATE Threads::Threads)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
        target_sources(ttio_rans_tsan PRIVATE
            src/rans_encode_sse41.c
            src/rans_decode_sse41.c
            src/rans_encode_avx2.c
            src/rans_decode_avx2.c
        )
        set_source_files_properties(
            src/rans_encode_sse41.c src/rans_decode_sse41.c
            PROPERTIES COMPILE_FLAGS "-msse4.1"
        )
        set_source_files_properties(
            src/rans_encode_avx2.c src/rans_decode_avx2.c
            PROPERTIES COMPILE_FLAGS "-mavx2"
        )
    endif()

    add_executable(test_thread_safety_tsan tests/test_thread_safety.c)
    target_compile_options(test_thread_safety_tsan PRIVATE
        -Wall -Wextra -Wpedantic -g -O1 -fsanitize=thread)
    target_link_options(test_thread_safety_tsan PRIVATE -fsanitize=thread)
    target_link_libraries(test_thread_safety_tsan
        PRIVATE ttio_rans_tsan Threads::Threads)
    add_test(NAME thread_safety_tsan COMMAND test_thread_safety_tsan)
endif()

# Benchmark (not registered as a ctest; run manually)
add_executable(bench_throughput bench/bench_throughput.c)
target_link_libraries(bench_throughput PRIVATE ttio_rans)
target_compile_options(bench_throughput PRIVATE -O3)
