cmake_minimum_required(VERSION 3.16)
project(ttio_rans C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(TTIO_RANS_ENABLE_TSAN
    "Build a separate test_thread_safety_tsan target with -fsanitize=thread" OFF)

find_package(Threads REQUIRED)

add_library(ttio_rans SHARED
    src/rans_core.c
    src/rans_encode_scalar.c
    src/rans_decode_scalar.c
    src/dispatch.c
    src/threadpool.c
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

# Optional ThreadSanitizer build of the same test, gated by an option so
# the default ctest run remains fast and portable.  Enable with:
#   cmake -DTTIO_RANS_ENABLE_TSAN=ON ..
if(TTIO_RANS_ENABLE_TSAN)
    add_library(ttio_rans_tsan SHARED
        src/rans_core.c
        src/rans_encode_scalar.c
        src/rans_decode_scalar.c
        src/dispatch.c
        src/threadpool.c
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
