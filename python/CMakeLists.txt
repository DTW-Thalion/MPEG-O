cmake_minimum_required(VERSION 3.16)
project(ttio_python LANGUAGES C)

# The in-tree build backend (_build_backend.py) copies ../native into ./_native
# before each sdist/wheel build, so a self-contained sdist can rebuild the
# native library at install time. When developing in the full repo checkout,
# fall back to the sibling tree.
set(_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/_native")
if(NOT EXISTS "${_NATIVE_DIR}/CMakeLists.txt")
    set(_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native")
endif()
if(NOT EXISTS "${_NATIVE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "libttio_rans native sources not found at ${_NATIVE_DIR}")
endif()
message(STATUS "ttio: building libttio_rans from ${_NATIVE_DIR}")

# Build libttio_rans only (no native test executables, no JNI) and install it
# into the wheel under ttio/.libs so the runtime loader (_native_loader.py)
# finds it with no environment configuration.
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(TTIO_RANS_BUILD_JNI OFF CACHE BOOL "" FORCE)
# Suppress the native project's own lib/ + include/ install rules; we install
# the library into ttio/.libs ourselves below.
set(TTIO_RANS_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${_NATIVE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/native_build")

install(TARGETS ttio_rans
        LIBRARY DESTINATION ttio/.libs   # Linux .so, macOS .dylib
        RUNTIME DESTINATION ttio/.libs   # Windows .dll
        ARCHIVE DESTINATION ttio/.libs)

# ---------------------------------------------------------------------------
# Optional Cython accelerators. The pure-Python references in ttio.codecs are
# byte-identical, just slower, so these are best-effort: if Cython, the .pyx
# sources, or the Python development headers are unavailable, skip them and
# ship the pure-Python path. (libttio_rans above is the one that MUST build.)
# ---------------------------------------------------------------------------
# Optional Cython linetrace instrumentation (R8 coverage visibility).
# Default OFF: linetrace adds per-line tracing overhead, so production
# wheels must NOT enable it. When ON, the .pyx are cythonized with
# `-X linetrace=True` and the C extensions compiled with
# CYTHON_TRACE_NOGIL=1, which coverage.py's Cython.Coverage plugin reads.
option(TTIO_CYTHON_LINETRACE "Compile .pyx with linetrace for coverage" OFF)

find_package(Python COMPONENTS Interpreter Development.Module)
find_program(CYTHON_EXECUTABLE NAMES cython)

if(Python_Development.Module_FOUND AND CYTHON_EXECUTABLE)
    set(_cython_flags -3)
    if(TTIO_CYTHON_LINETRACE)
        list(APPEND _cython_flags -X linetrace=True)
        message(STATUS "ttio: Cython linetrace coverage ENABLED")
    endif()
    foreach(mod _rans _delta_rans)
        set(_pyx "${CMAKE_CURRENT_SOURCE_DIR}/src/ttio/codecs/${mod}/${mod}.pyx")
        if(EXISTS "${_pyx}")
            set(_c "${CMAKE_CURRENT_BINARY_DIR}/${mod}.c")
            add_custom_command(
                OUTPUT "${_c}"
                COMMAND "${CYTHON_EXECUTABLE}" ${_cython_flags} -o "${_c}" "${_pyx}"
                DEPENDS "${_pyx}"
                VERBATIM)
            Python_add_library(${mod} MODULE "${_c}" WITH_SOABI)
            if(TTIO_CYTHON_LINETRACE)
                # CYTHON_TRACE_NOGIL=1 implies CYTHON_TRACE=1 AND also
                # instruments `nogil` blocks. The codecs run their hot loops
                # under `nogil`, so plain CYTHON_TRACE would silently leave
                # those lines uncovered — NOGIL is required for honest counts.
                target_compile_definitions(${mod} PRIVATE CYTHON_TRACE_NOGIL=1)
            endif()
            install(TARGETS ${mod} LIBRARY DESTINATION "ttio/codecs/${mod}")
            message(STATUS "ttio: Cython accelerator ${mod} enabled")
        else()
            message(STATUS "ttio: ${mod}.pyx absent — using pure-Python fallback")
        endif()
    endforeach()
else()
    message(STATUS "ttio: Cython or Python headers unavailable — pure-Python codecs only")
endif()
