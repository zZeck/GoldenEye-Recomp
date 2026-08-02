#!/usr/bin/env bash
#
# package_windows.sh -- bundle the Windows (llvm-mingw) Release build plus the
# game assets into a distributable zip for Windows users.
#
# Contents of the zip:
#   GoldenEye.exe + runtime DLLs (librexruntime.dll, libc++.dll, libunwind.dll,
#   libTracyClient.dll) from the win-amd64 Release build, plus the game data
#   (default.xex, files/, music.*, sfx.*, ArcadeInfo.xml, images) and a default
#   ge.toml, laid out so the user just unzips and runs GoldenEye.exe.
#
# Usage:
#   scripts/package_windows.sh [output.zip]
# Defaults to dist/GoldenEye-win64-<git-describe>.zip
#
set -euo pipefail

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

echo "Staging game assets from ${ASSET_DIR}"
for a in "${ASSETS[@]}"; do
  if [[ -e "${ASSET_DIR}/${a}" ]]; then
    cp -a "${ASSET_DIR}/${a}" "${STAGE}/"
  else
    echo "  note: asset '${a}' not present, skipping" >&2
  fi
done

# Ship a clean default config (not the developer's local ge.toml). Console
# subsystem build logs to stdout; users can raise log_level if needed.
cat > "${STAGE}/ge.toml" <<'TOML'
# GoldenEye - default configuration
max_fps = 60
window_width = 1920
window_height = 1080
ge_online_enable = true
TOML

# Short player-facing readme.
cat > "${STAGE}/README.txt" <<'TXT'
GoldenEye (Windows build)
=========================

Just unzip and run GoldenEye.exe. Everything needed is in this folder.

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

# --- Zip ---------------------------------------------------------------------
VERSION="$(git -C "${REPO}" describe --tags --always --dirty 2>/dev/null || echo unknown)"
OUT="${1:-${REPO}/dist/GoldenEye-win64-${VERSION}.zip}"
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
