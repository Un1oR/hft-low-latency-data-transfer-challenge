cmake_minimum_required(VERSION 4.2)

set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "d0edc3af-4c50-42ea-a356-e2862fe7a444")
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

function(spectral_detect_libcxx_modules_json output_variable)
    execute_process(
        COMMAND "${CMAKE_CXX_COMPILER}" -print-resource-dir
        OUTPUT_VARIABLE _spectral_clang_resource_dir
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    cmake_path(GET _spectral_clang_resource_dir PARENT_PATH _spectral_clang_resource_parent)
    cmake_path(GET _spectral_clang_resource_parent PARENT_PATH _spectral_llvm_lib_dir)
    set("${output_variable}" "${_spectral_llvm_lib_dir}/libc++.modules.json" PARENT_SCOPE)
endfunction()

if(NOT DEFINED CMAKE_CXX_STDLIB_MODULES_JSON)
    spectral_detect_libcxx_modules_json(_spectral_libcxx_modules_json)
    if(EXISTS "${_spectral_libcxx_modules_json}")
        set(CMAKE_CXX_STDLIB_MODULES_JSON "${_spectral_libcxx_modules_json}")
    endif()
endif()

project(spectral_task VERSION 0.1.0 LANGUAGES CXX)

function(spectral_configure_target target)
    target_compile_features("${target}" PUBLIC cxx_std_23)
    set_target_properties(
        "${target}"
        PROPERTIES
            CXX_STANDARD 23
            CXX_STANDARD_REQUIRED ON
            CXX_EXTENSIONS OFF
            CXX_MODULE_STD ON
    )
    target_compile_options(
        "${target}"
        PRIVATE
            $<$<CXX_COMPILER_ID:Clang>:-Wall>
            $<$<CXX_COMPILER_ID:Clang>:-Wextra>
            $<$<CXX_COMPILER_ID:Clang>:-Wpedantic>
            $<$<CXX_COMPILER_ID:Clang>:-Werror=return-type>
    )
endfunction()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

add_library(spectral_transport)
target_sources(
    spectral_transport
    PUBLIC
        FILE_SET CXX_MODULES
        BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/transport"
        FILES transport/spectral.transport.cppm
    PRIVATE
        transport/src/sender.cpp
        transport/src/receiver.cpp
)
target_include_directories(
    spectral_transport
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/harness/include"
)
target_link_libraries(spectral_transport PUBLIC rt pthread)
spectral_configure_target(spectral_transport)

add_executable(sender transport/apps/sender.cpp)
target_link_libraries(sender PRIVATE spectral_transport)
spectral_configure_target(sender)

add_executable(receiver transport/apps/receiver.cpp)
target_link_libraries(receiver PRIVATE spectral_transport)
spectral_configure_target(receiver)
