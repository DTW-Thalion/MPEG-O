cmake_minimum_required(VERSION 3.16)
project(ttio_rans C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(ttio_rans SHARED
    src/rans_core.c
    src/rans_encode_scalar.c
    src/rans_decode_scalar.c
)
target_include_directories(ttio_rans PUBLIC include)
target_compile_options(ttio_rans PRIVATE -Wall -Wextra -Wpedantic)

# Install
install(TARGETS ttio_rans LIBRARY DESTINATION lib)
install(FILES include/ttio_rans.h DESTINATION include)

# Tests
enable_testing()
add_executable(test_roundtrip tests/test_roundtrip.c)
target_link_libraries(test_roundtrip ttio_rans)
target_compile_options(test_roundtrip PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME roundtrip COMMAND test_roundtrip)
