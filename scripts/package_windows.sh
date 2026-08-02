#!/usr/bin/env bash
#
# package_windows.sh -- bundle the Windows (llvm-mingw) Release build into a
# distributable zip for Windows users, optionally with the game assets.
#
# Contents of the zip:
#   GoldenEye.exe + runtime DLLs (librexruntime.dll, libc++.dll, libunwind.dll,
#   libTracyClient.dll) from the win-amd64 Release build, a default ge.toml, and
#   a README -- laid out so the user just unzips and runs GoldenEye.exe.
#   By default the game data (the exe-adjacent assets/ folder) is included; pass
#   --no-assets to ship a binaries-only zip (the user drops in their own assets/).
#
# Usage:
#   scripts/package_windows.sh [--no-assets] [output.zip]
# Defaults to dist/GoldenEye-win64[-nodata]-<git-describe>.zip
#
set -euo pipefail

# --- args --------------------------------------------------------------------
INCLUDE_ASSETS=1
OUT_ARG=""
for arg in "$@"; do
  case "${arg}" in
    --no-assets) INCLUDE_ASSETS=0 ;;
    --with-assets) INCLUDE_ASSETS=1 ;;
    -h|--help)
      echo "usage: scripts/package_windows.sh [--no-assets] [output.zip]" >&2
      exit 0 ;;
    *) OUT_ARG="${arg}" ;;
  esac
done

# Repo root = parent of this script's dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO}/out/build/win-amd64/Release"
ASSET_DIR="${REPO}/release"
STAGE_ROOT="$(mktemp -d)"
STAGE="${STAGE_ROOT}/GoldenEye"
trap 'rm -rf "${STAGE_ROOT}"' EXIT

# Build binaries we ship (must all exist -- fail loudly if the Release build
# hasn't been made yet).
BINARIES=(
  "GoldenEye.exe"
  "librexruntime.dll"
  "libc++.dll"
  "libunwind.dll"
  "libTracyClient.dll"
)

# Game data to ship alongside the binaries. The game mounts the exe-adjacent
# "assets/" folder as its game_data_root (confirmed in the runtime log: "--game
# _data_root not given; defaulting to .../assets"), so that single directory is
# the entire game payload. The duplicate loose copies at the top level of
# release/ (default.xex, files/, music.*, sfx.*, ...) are NOT used by the game
# and are intentionally excluded to avoid shipping the data twice. Everything
# else in release/ (logs/, the Linux GoldenEye/ge binaries, *.so, debug *d.dll)
# is also excluded.
ASSETS=(
  "assets"
)

# --- Sanity checks -----------------------------------------------------------
if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "error: Windows Release build not found at ${BUILD_DIR}" >&2
  echo "       run: cmake --build --preset win-amd64-release --target ge --parallel \$(nproc)" >&2
  exit 1
fi

missing=0
for b in "${BINARIES[@]}"; do
  if [[ ! -f "${BUILD_DIR}/${b}" ]]; then
    echo "error: missing build binary ${BUILD_DIR}/${b}" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || { echo "       rebuild the win-amd64 Release target." >&2; exit 1; }

# --- Stage -------------------------------------------------------------------
mkdir -p "${STAGE}"

echo "Staging Windows binaries from ${BUILD_DIR}"
for b in "${BINARIES[@]}"; do
  cp -a "${BUILD_DIR}/${b}" "${STAGE}/"
done

if [[ "${INCLUDE_ASSETS}" -eq 1 ]]; then
  echo "Staging game assets from ${ASSET_DIR}"
  for a in "${ASSETS[@]}"; do
    if [[ -e "${ASSET_DIR}/${a}" ]]; then
      cp -a "${ASSET_DIR}/${a}" "${STAGE}/"
    else
      echo "  note: asset '${a}' not present, skipping" >&2
    fi
  done
else
  echo "Skipping game assets (--no-assets): binaries-only package"
fi

# Ship a clean default config (not the developer's local ge.toml). Console
# subsystem build logs to stdout; users can raise log_level if needed.
cat > "${STAGE}/ge.toml" <<'TOML'
# GoldenEye - default configuration
max_fps = 60
window_width = 1920
window_height = 1080
ge_online_enable = true
TOML

# Short player-facing readme. The "game files" paragraph differs depending on
# whether assets were bundled.
{
  cat <<'TXT'
GoldenEye (Windows build)
=========================
TXT
  if [[ "${INCLUDE_ASSETS}" -eq 1 ]]; then
    cat <<'TXT'

Just unzip and run GoldenEye.exe. Everything needed is in this folder.
TXT
  else
    cat <<'TXT'

This package contains only the program (no game data). To play:
  1. Put your GoldenEye game files in a folder named "assets" NEXT TO
     GoldenEye.exe (so you have GoldenEye/assets/default.xex, etc.).
  2. Run GoldenEye.exe.
TXT
  fi
  cat <<'TXT'

Controls
  - Gamepad works out of the box.
  - Keyboard + mouse: mouse-look is on by default; press Esc for the settings
    menu (rebind keys, video/audio options, controller vibration, etc.).

Multiplayer
  - Enable "Online" in the pause menu; it connects to the matchmaker/relay.

Notes
  - A console window opens alongside the game for log output. That is normal.
  - Settings are saved to ge.toml next to the exe.

This is an unofficial fan project and is not affiliated with or endorsed by
the rights holders. See the project page for source and credits.
TXT
} > "${STAGE}/README.txt"

# --- Zip ---------------------------------------------------------------------
VERSION="$(git -C "${REPO}" describe --tags --always --dirty 2>/dev/null || echo unknown)"
if [[ "${INCLUDE_ASSETS}" -eq 1 ]]; then
  DEFAULT_OUT="${REPO}/dist/GoldenEye-win64-${VERSION}.zip"
else
  DEFAULT_OUT="${REPO}/dist/GoldenEye-win64-nodata-${VERSION}.zip"
fi
OUT="${OUT_ARG:-${DEFAULT_OUT}}"
mkdir -p "$(dirname "${OUT}")"
rm -f "${OUT}"

echo "Creating ${OUT}"
if command -v zip >/dev/null 2>&1; then
  ( cd "${STAGE_ROOT}" && zip -r -q "${OUT}" "GoldenEye" )
else
  # Fallback: use Python's zipfile (always available) if the zip CLI is absent.
  echo "  (zip CLI not found; using python3 zipfile)"
  OUT="${OUT}" STAGE_ROOT="${STAGE_ROOT}" python3 - <<'PY'
import os, zipfile
out = os.environ["OUT"]; root = os.environ["STAGE_ROOT"]
base = os.path.join(root, "GoldenEye")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _dirs, files in os.walk(base):
        for f in files:
            full = os.path.join(dirpath, f)
            # arcname keeps the top-level "GoldenEye/" folder in the zip
            z.write(full, os.path.relpath(full, root))
PY
fi

SIZE="$(du -h "${OUT}" | cut -f1)"
echo "Done: ${OUT} (${SIZE})"
echo "Top-level folder in the zip: GoldenEye/"
