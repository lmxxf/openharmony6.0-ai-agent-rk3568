# OpenHarmony ARM64 Cross Compilation Toolchain File
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# OHOS SDK Paths (Env vars must be set by build script)
set(OHOS_SDK_ROOT "$ENV{OHOS_SDK_ROOT}")
set(OHOS_SYSROOT "${OHOS_SDK_ROOT}/native/sysroot")
set(OHOS_CLANG_ROOT "$ENV{OHOS_CLANG_ROOT}")

# Compilers
set(CMAKE_C_COMPILER "${OHOS_CLANG_ROOT}/bin/clang")
set(CMAKE_CXX_COMPILER "${OHOS_CLANG_ROOT}/bin/clang++")
set(CMAKE_AR "${OHOS_CLANG_ROOT}/bin/llvm-ar")
set(CMAKE_RANLIB "${OHOS_CLANG_ROOT}/bin/llvm-ranlib")

# Target Triple
set(OHOS_TARGET "aarch64-linux-ohos")

# Build Flags
set(CMAKE_C_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -march=armv8-a -funwind-tables -fstack-protector-strong -no-canonical-prefixes -fno-addrsig -Wa,--noexecstack")
set(CMAKE_CXX_FLAGS_INIT "-I${CMAKE_SOURCE_DIR}/tools/mtmd --target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -march=armv8-a -funwind-tables -fstack-protector-strong -no-canonical-prefixes -fno-addrsig -Wa,--noexecstack")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings -Wl,--gc-sections")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--fatal-warnings -Wl,--gc-sections")

# Search Paths
set(CMAKE_FIND_ROOT_PATH "${OHOS_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# Library Paths
link_directories("${OHOS_SYSROOT}/usr/lib/${OHOS_TARGET}")
