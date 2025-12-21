cmake_minimum_required(VERSION 3.16)
project(llama_napi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Native API
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# Include directories
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/../../../../../../../llama_cpp/include
    ${NATIVERENDER_ROOT_PATH}/../../../../../../../llama_cpp/ggml/include
)

# Prebuilt llama libraries path (ARM64)
set(LLAMA_LIB_PATH ${NATIVERENDER_ROOT_PATH}/../../../../../../../llama_cpp/build_arm64/bin)

# Add prebuilt libraries
add_library(llama SHARED IMPORTED)
set_target_properties(llama PROPERTIES IMPORTED_LOCATION ${LLAMA_LIB_PATH}/libllama.so)

add_library(ggml SHARED IMPORTED)
set_target_properties(ggml PROPERTIES IMPORTED_LOCATION ${LLAMA_LIB_PATH}/libggml.so)

add_library(ggml-base SHARED IMPORTED)
set_target_properties(ggml-base PROPERTIES IMPORTED_LOCATION ${LLAMA_LIB_PATH}/libggml-base.so)

add_library(ggml-cpu SHARED IMPORTED)
set_target_properties(ggml-cpu PROPERTIES IMPORTED_LOCATION ${LLAMA_LIB_PATH}/libggml-cpu.so)

# NAPI module
add_library(llama_napi SHARED
    llama_napi.cpp
)

target_link_libraries(llama_napi PUBLIC
    llama
    ggml
    ggml-base
    ggml-cpu
    libace_napi.z.so
    libhilog_ndk.z.so
)
