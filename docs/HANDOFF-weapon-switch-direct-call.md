# Follow-up: switch weapons by calling the guest function directly (RE later)

**Status: RESOLVED, DONE 2026-07-03.** The direct-call optimization this note
was tracking has shipped. `RequestEquipWeapon` now switches instantly by
calling the guest entry `sub_820A6F70` found below (see "Findings 2026-07").
Shipped mechanism: `ge_direct_equip` (`src/ge_hooks.cpp`) issues the native
pair-call `sub_820A6F70(hand0, id, 1)` + `sub_820A6F70(hand1, dual-partner-or-0,
1)`, integrated under `RequestEquipWeapon` behind cvar `ge_weapon_direct_switch`
(default **on**) with a 30-frame/10-try retry loop; the old Y-cycle path is kept
behind the cvar as an escape hatch (`ge_weapon_direct_switch=false`). Verified
end-to-end on desktop: instant digits/wheel/DS-path switching, dual-wield
correct, fire-blocked switches land on release. Design:
`docs/superpowers/specs/2026-07-03-weapon-direct-switch-design.md`.

## Why we deferred it
Injecting Y (cycle-to-target) is guaranteed-correct and shipped today. The
direct-call path would give instant multi-step jumps but needs more RE and
crash-prone runtime trials. Net: not worth blocking the feature.

## What we learned (desktop, confirmed)
- `E` (= 360 **Y** button, `BTN_Y = 0x8000` in the slot-0 pad at `0x830C8B9C`)
  is the game's native weapon switch; one press = one forward cycle.
- The equipped-weapon block is at fixed guest addresses:
  `0x447f10b0` equipped id, `0x447f10c8` a second "agreement" copy,
  `0x447f10f4` clip, `0x447f10c0` weapon-def ptr, `0x447f1104` another id mirror.
  **Writing any of these does NOT switch** — `0x447f10b0` desyncs the agreement
  gate (snapshot goes invalid); `0x447f1104` sticks but nothing happens. The game
  sets these *from* its switch routine; it does not poll them.
- Player struct: `+0x928` (2344) = current weapon (also seen in
  `ge_ce_remote_weapon_sfx`). Weapon-stats array @ `0x82421968` (stride 0x38).

## The function trail (generated recomp)
The recompiled code keeps original PPC asm as comments — grep those.
- `sub_820A7508` (guest `0x820A7508`) writes current-weapon: `stw r27,2344(r11)`
  plus `+0x954` and `+0xB04`. It is a **per-hand weapon applier**.
  - Signature observed at callers: `sub_820A7508(r3 = hand [1 then 0],
    r4 = resolved weapon)`, where `r4` comes from `sub_820A0D30(hand)` and is a
    **resolved weapon object/struct, not a raw id**.
  - 7 callers total; e.g. `sub_820BC030` (ge_recomp.1.cpp:33183/33195) calls it
    in a hand-1 then hand-0 pair as part of a broader refresh.
- **Not yet found:** the higher-level "select weapon N" entry the Y button
  invokes (the one that runs the full switch incl. draw animation / viewmodel).
  That is the function to call. Start by tracing upward from the pad-Y read to
  whatever eventually reaches `sub_820A7508`, and identify how a target weapon
  is resolved (`sub_820A0D30`).

## Tooling added for this (kept)
- `memscan` gained a live `write <ga> <16|32> <val>` command (ge_gamestate.cpp,
  behind `ge_gamestate_diag`, desktop-only) — poke guest fields at runtime.
  Drive via `/tmp/ge_scan.cmd`, output `/tmp/ge_scan.out`.

## Build/run gotcha
The desktop binary is **`out/build/linux-amd64-relwithdebinfo/GoldenEye`**
(CMake `OUTPUT_NAME "GoldenEye"`), NOT `ge`. `CLAUDE.md`'s run recipe says `ge`
and is wrong.

## Findings 2026-07 (runtime trace + static walk-up) — ENTRY IDENTIFIED
- **Correction to the trail above:** `sub_820A7508`'s `r4` is the **raw weapon id**, NOT a
  resolved object (verified live: obj=0x01/0x05/0x11 = the held ids during digit switches).
- All native switches funnel through ONE applier call site `lr=0x820AC1C8` inside
  `sub_820AAE00` (the weapon state machine), which reads the target from a per-hand
  "desired weapon" field — a heap struct, which is why fixed-address scans never found it:
  `hand_struct = *(0x82F1FAAC) + hand*936`; fields: +2344 current id, +2404 desired id,
  +2384 switch-state (5 = start), +2412 aux (0 on request), +0x94C/+0x950 state counters.
- **Direct-switch entry: `sub_820A6F70` (guest 0x820A6F70), args r3 = hand, r4 = weapon id,
  r5 = 1 (direction/mode).** Sole funnel for the Y-cycle input paths (input dispatcher
  `sub_820B99E8` -> 4 cycle helpers -> 8 call sites total). Dedups repeated requests and
  refuses to restart an in-flight switch.
- Forcing alternative one level down: `sub_820A0CF8` (r3=hand, r4=id) = pure 3-store leaf,
  equivalent to `[H+2404]=id; [H+2412]=0; [H+2384]=5` (write 2384 last). Writing +2404
  alone does nothing.
- Confidence: high on formula/protocol (writer enumeration was exhaustive); medium on
  ownership validation (the entry does NOT check the weapon is held — callers do; our
  driver guard covers this). Live confirmation = the Phase-2 `equip` harness.
- Full evidence trail (file:line, guest addresses): `.superpowers/sdd/task-3-analysis.md`
  (git-ignored scratch; regenerate from generated/ if needed).

### Known limitations (2026-07-03)
- The direct-call path derives its hand structs from `GE_BONDVIEW_CUR`
  (0x82F1FAAC), which cycles across all players each frame in a network MP
  session (the same reason mouse-look migrated to a viewport scan — see
  `ge_hooks.cpp` ~1320). Network MP sessions are guarded off of the direct path
  via `GE_NET_FLAG` (byte @0x830CAEA0, !=0 = network MP session) and routed to
  the pad-injection Y-cycle walker instead, which is player-0-safe by
  construction.
- Local splitscreen is **not** detected by `GE_NET_FLAG` and is **untested**
  with the direct path. If wrong-player weapon switches are reported in
  splitscreen, the fix is the same viewport-scan player guard idiom already
  used by mouse-look (`ge_hooks.cpp` ~1320): resolve the acting hand from the
  active-viewport player instead of `GE_BONDVIEW_CUR`.
- Single-player is fully verified.
