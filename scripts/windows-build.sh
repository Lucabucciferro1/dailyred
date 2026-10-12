#!/usr/bin/env bash
# Internal helper for windows.ps1, run by the project-local MSYS2 Bash.
set -euo pipefail

case "${1:-}" in
  update)
    pacman -Syu --noconfirm
    ;;
  packages)
    pacman -Syu --needed --noconfirm make mingw-w64-ucrt-x86_64-gcc \
      mingw-w64-ucrt-x86_64-libpng mingw-w64-ucrt-x86_64-pkgconf
    ;;
  build|clean)
    action="$1"
    root="$(cygpath -u "$DAILYRED_ROOT")"
    # Keep the host compiler's DLLs ahead of the ARM compiler's older copies.
    # TOOLCHAIN is empty below so upstream does not prepend them again.
    export PATH="/ucrt64/bin:$root/.toolchain/arm-none-eabi/bin:$PATH"
    # GCC reports native absolute paths. Quote these explicitly: upstream's
    # unquoted cc1/dirname expressions cannot handle a Windows username with spaces.
    cc1="$(cygpath -m "$(arm-none-eabi-gcc --print-prog-name=cc1)")"
    libgcc="$(cygpath -m "$(arm-none-eabi-gcc -print-file-name=libgcc.a)")"
    libc="$(cygpath -m "$(arm-none-eabi-gcc -print-file-name=libc.a)")"
    # Use Windows executables for the asset tools, and the same ARM GCC as macOS.
    args=(-C "$root/pokefirered" "-j$DAILYRED_JOBS" MODERN=1 \
      TOOLCHAIN= CC=gcc CXX=g++ "CC1=\"$cc1\" -quiet" \
      "LIBPATH=-L \"${libgcc%/*}\" -L \"${libc%/*}\"")
    if [[ "$action" == clean ]]; then args+=(clean); fi
    make "${args[@]}"
    ;;
  *) echo "Use scripts/windows.ps1 to run the Windows build." >&2; exit 1 ;;
esac
