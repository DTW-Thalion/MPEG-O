# The Vulkan engine is a loadable module, not a link-time dependency of
# libttio_rans: it is dlopened only when TTIO_GPU=force. Deployments
# that never ask for a GPU need neither this library nor a Vulkan
# loader on the machine.

find_package(Vulkan QUIET)

if(NOT Vulkan_FOUND)
    message(STATUS "ttio: Vulkan not found, GPU engine will not be built")
    return()
endif()

message(STATUS "ttio: building GPU engine against ${Vulkan_LIBRARIES}")

find_program(GLSLANG_VALIDATOR NAMES glslangValidator)
if(NOT GLSLANG_VALIDATOR)
    message(STATUS "ttio: glslangValidator not found, GPU engine will not be built")
    return()
endif()

# SPIR-V is host independent, so this is generated once and compiled in.
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/v6_spv.h
    COMMAND ${GLSLANG_VALIDATOR} -V ${CMAKE_CURRENT_SOURCE_DIR}/v6_chain.comp
            --vn v6_spv -o ${CMAKE_CURRENT_BINARY_DIR}/v6_spv.h
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/v6_chain.comp
    COMMENT "Compiling v6_chain.comp to SPIR-V")

add_library(ttio_gpu_vk MODULE vk_engine.c
            ${CMAKE_CURRENT_BINARY_DIR}/v6_spv.h)

set_target_properties(ttio_gpu_vk PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "ttio_gpu_vk")

target_include_directories(ttio_gpu_vk PRIVATE
    ${Vulkan_INCLUDE_DIRS}
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(ttio_gpu_vk PRIVATE ${Vulkan_LIBRARIES} Threads::Threads)

target_compile_options(ttio_gpu_vk PRIVATE -Wall -Wextra -Wpedantic -O2)
