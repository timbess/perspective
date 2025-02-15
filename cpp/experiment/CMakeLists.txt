cmake_minimum_required(VERSION 3.31.0)
project(experiment)


set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O0 -g")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3")

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

include(ExternalProject)
include(ZigTools)
include(Arrow)

add_library(bridge STATIC ffi/bridge.cpp)
add_dependencies(bridge Arrow)

target_include_directories(bridge PRIVATE ${ARROW_SOURCE_DIR}/cpp/src)
target_include_directories(bridge PRIVATE ${ARROW_BINARY_DIR}/src)

add_zig_library(zig_build ${CMAKE_SOURCE_DIR})

add_library(lz4 STATIC IMPORTED)
set_property(TARGET lz4 PROPERTY
             IMPORTED_LOCATION "${BINARY_DIR}/lz4_ep-install/lib/liblz4.a")

add_library(arrow STATIC IMPORTED)
set_property(TARGET arrow PROPERTY
             IMPORTED_LOCATION "${BINARY_DIR}/release/libarrow.a")

add_library(experiment STATIC IMPORTED)
set_property(TARGET experiment PROPERTY
             IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/zig-out/lib/libexperiment.a")
add_dependencies(experiment zig_build)

add_executable(my_wasm wasm.cpp)
target_link_libraries(my_wasm PRIVATE bridge experiment arrow lz4)
target_include_directories(my_wasm PRIVATE "${CMAKE_SOURCE_DIR}/mock_zig_headers")
target_include_directories(my_wasm PRIVATE "${CMAKE_SOURCE_DIR}/.zig-cache")
target_include_directories(my_wasm PRIVATE "/opt/homebrew/Cellar/zig/0.13.0/lib/zig")

set_target_properties(my_wasm PROPERTIES
    OUTPUT_NAME "my_wasm"
    # SUFFIX ".js"
    SUFFIX ".html"
    LINK_FLAGS "-O3 -sEXPORT_ES6=1 -sUSE_OFFSET_CONVERTER -sEXPORT_ALL=1 -lembind --no-entry"
)