
find_program(ZIG_EXECUTABLE NAMES zig REQUIRED)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(ZIG_OPTIMIZE_FLAG "-Doptimize=Debug")
elseif(CMAKE_BUILD_TYPE STREQUAL "Release")
    set(ZIG_OPTIMIZE_FLAG "-Doptimize=ReleaseSafe")
elseif(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    set(ZIG_OPTIMIZE_FLAG "-Doptimize=ReleaseSafe")
elseif(CMAKE_BUILD_TYPE STREQUAL "MinSizeRel")
    set(ZIG_OPTIMIZE_FLAG "-Doptimize=ReleaseSmall")
else()
    set(ZIG_OPTIMIZE_FLAG "-Doptimize=Debug")
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    set(ZIG_ARCH "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "i[3-6]86")
    set(ZIG_ARCH "i386")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    set(ZIG_ARCH "aarch64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "arm")
    set(ZIG_ARCH "arm")
elseif(EMSCRIPTEN)
    set(ZIG_ARCH "wasm32")
else()
    set(ZIG_ARCH "native")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(ZIG_OS "linux")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(ZIG_OS "macos")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(ZIG_OS "windows")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Emscripten")
    set(ZIG_OS "emscripten")
else()
    set(ZIG_OS "unknown") # Fallback
endif()

set(ZIG_TARGET_FLAG "-Dtarget=${ZIG_ARCH}-${ZIG_OS}")

function(add_zig_library TARGET_NAME working_dir)
  add_custom_target(
      ${TARGET_NAME}
      COMMAND ${ZIG_EXECUTABLE} build ${ZIG_OPTIMIZE_FLAG} ${ZIG_TARGET_FLAG}
      WORKING_DIRECTORY ${working_dir}
      COMMENT "Building with Zig using optimization level: ${ZIG_OPTIMIZE_FLAG} for ${ZIG_TARGET_FLAG}"
      VERBATIM
  )
endfunction()
