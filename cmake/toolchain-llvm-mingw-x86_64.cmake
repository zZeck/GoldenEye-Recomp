# toolchain-llvm-mingw-x86_64.cmake
# ---------------------------------
# Cross-compile GoldenEye-Recomp (and the bundled rexglue SDK) from Linux to
# Windows x86-64 using the llvm-mingw toolchain (clang + lld + libc++ + UCRT).
#
# Use via a CMake preset (see CMakePresets.json) or directly:
#   cmake -B out/build/win-amd64 \
#         --toolchain cmake/toolchain-llvm-mingw-x86_64.cmake
#
# Override the toolchain location with -DLLVM_MINGW_ROOT=/path/to/llvm-mingw
# if it is not installed at the default path below.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Root of the llvm-mingw install. Override with -DLLVM_MINGW_ROOT=... .
if(NOT DEFINED LLVM_MINGW_ROOT)
    set(LLVM_MINGW_ROOT "/usr/lib/llvm-mingw64")
endif()

set(_mingw_bin    "${LLVM_MINGW_ROOT}/bin")
set(_mingw_prefix "x86_64-w64-mingw32")
set(TOOLCHAIN_PREFIX "${_mingw_prefix}" CACHE STRING "MinGW target triple prefix")

# Compilers and archiver from the llvm-mingw prefixed wrappers.
set(CMAKE_C_COMPILER   "${_mingw_bin}/${_mingw_prefix}-clang")
set(CMAKE_CXX_COMPILER "${_mingw_bin}/${_mingw_prefix}-clang++")
set(CMAKE_AR           "${_mingw_bin}/${_mingw_prefix}-ar")
set(CMAKE_C_COMPILER_AR   "${_mingw_bin}/${_mingw_prefix}-ar")
set(CMAKE_CXX_COMPILER_AR "${_mingw_bin}/${_mingw_prefix}-ar")

# llvm-mingw's static libs are already indexed; ranlib is a no-op. Using
# /bin/true avoids a spurious ranlib invocation that can choke on thin/LTO
# archives.
set(CMAKE_RANLIB           "/bin/true")
set(CMAKE_C_COMPILER_RANLIB   "/bin/true")
set(CMAKE_CXX_COMPILER_RANLIB "/bin/true")

# Use LLD (the PE/COFF driver) as the linker.
set(CMAKE_LINKER_TYPE LLD)

# Directory holding the toolchain's own runtime DLLs (libc++.dll, libunwind.dll)
# that the produced binaries link against. These are NOT CMake targets, so
# TARGET_RUNTIME_DLLS won't stage them; the SDK's host-target helper copies them
# next to the executable using this hint. Auto-detected from the compiler if not
# provided.
if(NOT DEFINED REX_MINGW_RUNTIME_DLL_DIR)
    foreach(_cand
            "${LLVM_MINGW_ROOT}/${_mingw_prefix}/bin"
            "/usr/lib/llvm/22/${_mingw_prefix}/bin"
            "/usr/lib/llvm/21/${_mingw_prefix}/bin")
        if(EXISTS "${_cand}/libc++.dll")
            set(REX_MINGW_RUNTIME_DLL_DIR "${_cand}"
                CACHE PATH "Directory with llvm-mingw runtime DLLs (libc++, libunwind)")
            break()
        endif()
    endforeach()
endif()

# Sysroot for find_*(): headers/libraries come from the target sysroot, but
# programs (llvm-nm, clang, etc.) come from the host.
set(CMAKE_FIND_ROOT_PATH "${LLVM_MINGW_ROOT}/${_mingw_prefix}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)

# FFmpeg's vendored sources and a couple of third-party headers are not clean
# under clang's stricter C++ defaults; keep the historical relaxations.
set(_rex_relax_flags "-fpermissive -Wno-error")
set(CMAKE_C_FLAGS_INIT   "${_rex_relax_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_rex_relax_flags}")
