# GoldenEye 007 — PC Recompilation (zZeck integration fork)

A native PC port of **GoldenEye 007 (Xbox 360 / XBLA)**, built by *statically
recompiling* the original game into C++ with the
[ReXGlue SDK](https://github.com/jeffory/GoldenEye-Recomp-rexglue). No emulator —
the game runs as a real native executable on **Windows** and **Linux**.

> [!IMPORTANT]
> **This repository contains _no_ game code or assets.** It is only the source
> that wraps the game (menus, hooks, online, post-FX, build config). You must
> supply the game files yourself. This game never released publicly.

## About this fork

This is an integration fork that merges the work of several GoldenEye-Recomp
contributors, adds a **Linux → Windows cross-compile**, and fixes a number of
genuine bugs (audio, input, GPU pacing, online multiplayer). It is built and
tested primarily on **Linux** (native x86-64 build, plus an llvm-mingw
cross-compiled Windows build from the same tree).

Full commit history and credits are in git; the summary of who did what is in
[Features & credits](#features--credits) below.

## Features & credits

Upstream lineage — everyone forked from SunJaycy's original GoldenEye fork of
the ReXGlue SDK:

- **[SunJaycy](https://github.com/SunJaycy/GoldenEye-Recomp)** — the original
  GoldenEye recompilation, plus master-volume, live-FXAA and vsync-default
  audio/GPU tweaks.
- **[LucioXerus](https://github.com/LucioXerus/GoldenEye-Recomp)** — the base
  this fork tracks: native Linux support (Wayland/GTK/Vulkan), post-FX filters,
  pause/settings menu, online multiplayer client.
- **[jeffory](https://github.com/jeffory/GoldenEye-Recomp)** — extensive
  additions merged here: 1:1 keyboard & mouse-look, weapon quick-select,
  perf/telemetry tooling, pipeline disk-cache, crash/audio fixes, and the
  (inert on desktop) Android + dual-screen framework.
- **[mrfox-1](https://github.com/mrfox-1/GoldenEye-Recomp)** — reverse-engineered
  **native XACT music-transition restoration** (the watch cue, Mission Select
  cue, and the N64 dynamic X-track states the leaked XBLA build left stubbed).
- **[nexus382](https://github.com/nexus382/007-Goldeneye-Recomp-TnT)** — the
  controller-vibration toggle idea (reworked here to the SDK's cross-platform
  rumble layer).

Player-facing features:

- Runs natively on **Windows** and **Linux** — no emulator, no BIOS.
- Steady **60 FPS** (optimized Release build; the debug build is much slower).
- Controller support, plus **1:1 keyboard & mouse-look** (mouse aim without the
  analog deadzone/accel of stick emulation).
- **Weapon quick-select** — number keys `1`–`9` jump to a carried weapon, scroll
  wheel steps next/previous (see [Weapon quick select](#weapon-quick-select)).
- **Online multiplayer** — host or join over the internet via a matchmaker/relay
  (see [Playing online](#playing-online)). Works cross-platform between the
  Linux and Windows builds.
- Restored **in-game music transitions** (watch/pause cue, Mission Select,
  dynamic level X-tracks).
- In-game **pause / settings menu** (ESC): video, resolution, frame limit,
  fullscreen, controller vibration, post-FX, online setup.
- **Post-FX** filters (brightness, contrast, saturation, vignette, presets).

### Notable fixes in this fork

- **Linux → Windows cross-compile** with llvm-mingw (build a Windows `.exe` from
  a Linux host; see [Building](#building-from-source)).
- **Audio**: fixed a producer-thread wake race (store-visibility TOCTOU) that
  caused intermittent no-sound-at-boot / audio dropouts.
- **Input**: fixed a mouse-look crash (window API called off the UI thread) and a
  mouse-look tracking bug on the warp path; guarded XI2 raw-motion setup so it
  no longer crashes on XWayland (falls back to warp-based look).
- **Multiplayer**: fixed weapon quick-select randomly cycling on online clients
  (the weapon block is now read relative to the local player, not players[0]).
- **Startup**: fixed a false "missing game files" launch veto when started
  without an explicit `--game_data_root`.
- **GPU**: 16-byte-aligned the guest `jmp_buf` (setjmp crash) and other
  cross-compile/runtime fixes.

## Download & play

Grab a prebuilt zip (or build it yourself — see [Building](#building-from-source)).
Two Windows package shapes are produced by the packaging script:

- **With assets** — unzip and run `GoldenEye.exe`; everything is in the folder.
- **Binaries only** (`-nodata`) — put your own game files in a folder named
  `assets/` next to `GoldenEye.exe`, then run it.

On Linux, run `./GoldenEye` from a folder containing `assets/` and the runtime
`.so` files. A console window / terminal shows log output; that is normal.

> [!NOTE]
> You supply your own GoldenEye 007 XBLA game files. They go in an `assets/`
> folder next to the executable (so the game finds `assets/default.xex`, etc.).

## Playing online

1. One person runs a **[server](https://github.com/SunJaycy/GoldenEye-Recomp-Server)**
   and shares its address + port.
2. Everyone opens **ESC → ONLINE**, enters their **username**, the **server
   address** and **port**, ticks *Enable online play*, and hits **Save & Restart**.
3. Host a match; the others find and join it.

Because players connect *out* to the server, joiners need no port-forwarding —
only the host's server port has to be reachable. Linux and Windows builds
interoperate (same wire protocol).

## Weapon quick select

Switching weapons is **instant** — the port drives the game's own weapon-switch
routine instead of cycling the inventory. Enabled by default:

- **Number keys `1`–`9`** — jump straight to the Nth carried weapon.
- **Scroll wheel** — step to the next/previous carried weapon.

Tunable via cvars: `ge_weapon_select_enable` toggles it; `ge_key_wpn_next` /
`ge_key_wpn_prev` rebind the wheel step (defaults `WheelUp` / `WheelDown`).

## Building from source

You need a local checkout of the **ReXGlue SDK submodule** (included here as
`GoldenEye-Recomp-rexglue/`), **CMake 3.25+**, **Ninja**, **Python 3**, and your
own **GoldenEye 007 XBLA game files** in `assets/`.

Both platforms use [CMake presets](CMakePresets.json). Configure presets:
`linux-amd64` and `win-amd64`; build presets add a `-debug` / `-release` /
`-relwithdebinfo` suffix. **Use Release for actual play** — the debug build is
dramatically slower (no inlining / LTO).

### 1. One-time codegen (turns your game copy into recompiled C++)

Run once from the repo root. It reads your `assets/` and emits C++ under
`generated/`:

```sh
GoldenEye-Recomp-rexglue/out/linux-amd64/Debug/rexglue codegen ge_manifest.toml
```

(You need the `rexglue` codegen tool built first — it is produced by configuring
either preset below, which builds the SDK in-tree. On a fresh tree, configure
first, run codegen, then build the `ge` target.)

### Linux (native x86-64)

Clang with libc++ (the SDK uses `std::expected` / `std::jthread`), Vulkan, GTK3,
Wayland, SDL3. On Debian/Ubuntu:

```sh
sudo apt install git cmake ninja-build build-essential pkg-config python3 \
  clang llvm lld libsdl3-dev libvulkan-dev vulkan-tools mesa-vulkan-drivers \
  libgtk-3-dev libx11-dev libxcb1-dev libxi-dev libwayland-dev wayland-protocols \
  libasound2-dev
```

Configure and build (Release):

```sh
cmake --preset linux-amd64
cmake --build --preset linux-amd64-release --target ge --parallel $(nproc)
```

The binary is `out/build/linux-amd64/Release/GoldenEye` and the runtime library
is `GoldenEye-Recomp-rexglue/out/linux-amd64/Release/librexruntime.so`. Stage
both (plus `libTracyClient.so`) next to your `assets/` and run `./GoldenEye`.

### Windows (llvm-mingw cross-compile, from a Linux host)

This fork builds the Windows `.exe` **from Linux** using
[llvm-mingw](https://github.com/mstorsjo/llvm-mingw). Install llvm-mingw and
point the toolchain file at it (see
[`cmake/toolchain-llvm-mingw-x86_64.cmake`](cmake/toolchain-llvm-mingw-x86_64.cmake),
which auto-detects the compiler and runtime-DLL directory). Then:

```sh
cmake --preset win-amd64
cmake --build --preset win-amd64-release --target ge --parallel $(nproc)
```

Output: `out/build/win-amd64/Release/GoldenEye.exe` plus the runtime DLLs
(`librexruntime.dll`, `libc++.dll`, `libunwind.dll`, `libTracyClient.dll`).

Run under Wine for a quick smoke test:

```sh
WINEDEBUG=-all wine GoldenEye.exe   # from a folder containing assets/ + the DLLs
```

### Packaging a Windows zip

[`scripts/package_windows.sh`](scripts/package_windows.sh) bundles the Windows
Release build into `dist/`:

```sh
scripts/package_windows.sh              # binaries + your assets/
scripts/package_windows.sh --no-assets  # binaries only (user supplies assets/)
```

## Source layout

Hand-written engine glue lives in [`src/`](src/): `ge_app` (app + window/menu
glue), `ge_menu` (pause/settings menu), `ge_hooks` (mid-asm fixups, input,
mouse-look, weapon-select, music), `ge_gamestate` (weapon/inventory bridge),
`ge_postfx` (filters), `ge_online` (in the SDK). `ge_manifest.toml` /
`ge_config.toml` drive the recompiler.

## Legal

GoldenEye 007 and all related assets are property of their respective rights
holders. This project ships **none** of that — no ROM, XEX, textures, audio, or
recompiled game code. It only automates turning a copy *you already own* into a
PC build. Don't ask for or share game files.

## License

The original code in this repository is released into the **public domain**
([The Unlicense](LICENSE)). The ReXGlue SDK it builds against has its own
(BSD-3) license. Merged contributions remain credited to their authors above.
