cmake_minimum_required(VERSION 3.16)
project(ttio_rans C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(ttio_rans SHARED
    src/rans_core.c
)
target_include_directories(ttio_rans PUBLIC include)

# Install
install(TARGETS ttio_rans LIBRARY DESTINATION lib)
install(FILES include/ttio_rans.h DESTINATION include)
