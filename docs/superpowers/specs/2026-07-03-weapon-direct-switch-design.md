# Weapon direct-switch design (instant jump-to-weapon via guest function call)

**Date:** 2026-07-03
**Status:** approved design, pre-implementation
**Prior art:** `docs/HANDOFF-weapon-scrollwheel-select.md` (shipped Y-cycle actuation),
`docs/HANDOFF-weapon-switch-direct-call.md` (deferred RE trail this design resumes)

## Problem

Weapon selection ships today by injecting the native Y button and cycling until the
equipped weapon matches the target (`RequestEquipWeapon` in `ge_gamestate.{h,cpp}`,
driver in `ge_hooks.cpp`). It is correct but visibly slow for multi-step jumps, and
dual-wield entries lengthen the cycle. The game itself proves a better path exists:
the pause-menu inventory switches directly to any selected weapon.

## Goal

`RequestEquipWeapon(id)` switches to the target weapon **instantly and reliably** by
calling the game's own direct-switch guest function. Consumers do not change —
number keys, scrollwheel, and the Thor second-screen taps all sit on the same API
and become instant for free.

## Non-goals

- No quick-select UI (planned as a follow-on design once switching is instant).
- No changes to the DS weapon menu or its live-weapon-data offset work.
- No removal of the Y-cycle path — it remains as the cvar-off escape hatch (`ge_weapon_direct_switch=false`).

## Key facts from prior RE (do not re-litigate)

- Writing the equipped-id guest memory does **not** switch and desyncs an agreement
  gate (`0x447f10b0` and mirrors). Disproven; see the direct-call handoff.
- `sub_820A7508` is the per-hand weapon **applier** (`r3` = hand, `r4` = resolved
  weapon object from `sub_820A0D30(hand)`); it writes player `+0x928` etc. It is the
  known *bottom* of the switch call chain. 7 callers.
- The higher-level "switch to weapon N" entry (the one that runs draw animation /
  viewmodel) is unidentified — finding it is Phase 1 of this design.
- The recompiled sources keep original PPC asm as comments; caller code is readable
  once an address is known.
- Guest functions must be called with a live `PPCContext` on a guest thread. The
  existing driver hook (`ge_inject_keyboard` in `ge_hooks.cpp`) runs in exactly that
  environment via `getcb()`.

## Phase structure

Desktop-first throughout; the Ayn Thor enters only at the end of Phase 3. Phase
boundaries are real: if discovery stalls, Phase 0 ships alone.

### Phase 0 — number keys as the test surface

Re-enable the digit-key block in `ge_hooks.cpp` (temporarily `#if 0`'d for the
v1.3.0-android.3 release): keys **1–9 jump to the Nth held weapon**, edge-triggered,
driving the existing Y-cycle path. Fold in the three queued review cleanups from the
scrollwheel work:

1. Held/valid-id guard in the driver: if the posted target is not in
   `snap.held_mask` (or out of range), clear the request and abort.
2. Fix stale header docs in `ge_gamestate.h` (`RequestEquipWeapon` / `OnFrame`
   comments and the contract block still describe the removed memory-write path;
   `PeekEquipRequest` / `ClearEquipRequest` undocumented).
3. Reset the driver's `steps`/`wait` counters when a new target is posted mid-cycle.

Outcome: pressing a number selects that weapon (slow, by cycling). This is the
harness used to judge "instant" in later phases.

### Phase 1 — discovery (find the direct-switch entry)

Hook `sub_820A7508`, desktop-only, gated behind the existing `ge_gamestate_diag`
cvar. Log per call:

- `lr` (caller return address), `r3` (hand), `r4` (resolved weapon object pointer)
- a few words of the object at `r4` (to locate the raw weapon id inside it)
- the equipped-id block (`0x447f10b0` etc.) before/after

Session script: boot to gameplay → cycle with E 3–4 times → open the pause-menu
inventory and directly select two different weapons. This yields labeled "cycle
path" vs "direct path" call chains; the first `lr` unique to the direct path is the
lead. From there, work statically upward through the generated source (PPC asm
comments) — `sub_820A0D30` (id→object resolver) is likely on the chain; if the entry
takes a resolved object, call the resolver first.

**Definition of done (hard gate):** a documented entry address + argument list where
every argument is one of: an observed constant, a value readable from guest memory,
or the output of the resolver. An opaque argument (e.g., a pointer into pause-menu
context that only exists while paused) means the candidate is too high in the
chain — step one level down and re-check.

### Phase 2 — verification harness

Extend the `memscan` diag channel (`/tmp/ge_scan.cmd`, `ge_gamestate.cpp`, behind
`ge_gamestate_diag`) with an `equip <weapon-id>` command. The poller does **not**
run on a guest thread, so the command only *posts* the request; the actual guest
call executes inside the guest-thread hook (same placement as the Y-cycle driver),
where `getcb()` provides a valid `PPCContext`. This is the identical calling
environment the real integration uses.

**Safety matrix** — each case passes when the switch is clean: draw animation plays,
ammo/clip correct, HUD agrees, no fault-storm in the log:

| # | Case | Expected |
|---|------|----------|
| 1 | idle → different weapon | clean switch |
| 2 | while firing | clean switch or safe deferral |
| 3 | while reloading | clean switch or safe deferral |
| 4 | to and from a dual-wield weapon | clean switch, both hands correct |
| 5 | same weapon as equipped | no-op |
| 6 | rapid-fire requests (two `equip` in quick succession) | last one wins, no corruption |
| 7 | unheld weapon id | rejected by our guard before the call |

Cases 2, 3, 6 are the expected trouble spots. Mitigation if any misbehave: a
"safe to switch" gate that defers the direct call until player state clears
(bounded by the confirm-window timeout below), not abandonment of the approach.

### Phase 3 — integration

Per-frame flow in the guest-thread driver (`ge_hooks.cpp`); the request API stays in
`ge_gamestate.{h,cpp}`:

1. `PeekEquipRequest()` — nothing posted → done.
2. Guard: target in `snap.held_mask` and in range, else clear and abort
   (applies to both mechanisms).
3. If cvar `ge_weapon_direct_switch` (default **on**) and the Phase 1 entry exists:
   resolve target if needed, call the guest function, confirm via the equipped-id
   snapshot.
4. **Retry, then give up (AMENDED during implementation, user-approved):** the
   Phase-2 matrix showed the guest entry silently DROPS requests made while the
   player is mid-action (e.g. firing) — and a native Y press is equally ignored
   then, so downgrading to Y-cycle adds nothing. Shipped behavior: if the
   equipped id is unchanged after a confirm window (~30 frames), RE-ISSUE the
   direct call (the entry dedups, so repeats are safe), up to 10 tries, then
   give up and clear the request with one log line. The Y-cycle driver survives
   intact but is reachable ONLY via `ge_weapon_direct_switch=false`.

The Y-cycle code is kept as-is (no refactor) — the escape hatch stays boring.
`ge_weapon_direct_switch=false` is the A/B lever and per-device escape hatch.

## Error handling summary

| Failure | Handling |
|---------|----------|
| Entry never found (Phase 1 fails) | Phase 0 + cleanups ship alone; Y-cycle remains the mechanism; update the direct-call handoff with the new trail |
| Call lands but dirty in some player state | Shipped: the driver re-issues the direct call every ~30 frames (the entry itself defers/drops while the player is mid-action), up to 10 tries, then gives up and clears with a log line. No automatic Y-cycle fallback; ge_weapon_direct_switch=false is the manual escape hatch. |
| Call crashes | Must be caught in Phase 2 behind the diag harness; nothing ships enabled-by-default until the matrix is green |

## Testing (manual, per phase, desktop)

No unit harness exists for guest-memory behavior and building one is out of scope.

- **Phase 0:** keys 1–9 select the Nth held weapon via cycling; unheld/out-of-range
  ignored; scrollwheel unaffected.
- **Phase 2:** run the 7-case matrix; record results in a verification log appended
  to this spec.
- **Phase 3 desktop:** matrix repeated through real `RequestEquipWeapon` (number
  keys + scrollwheel); flip `ge_weapon_direct_switch=false` and confirm Y-cycle
  fallback still works.
- **Phase 3 Thor:** install, DS tap switches instantly, brief soak watching
  `ge.log` for fault-storms.

## Build/run reference

- Build: `cmake --build --preset linux-amd64-relwithdebinfo --target ge`
- Run binary is `out/build/linux-amd64-relwithdebinfo/GoldenEye` (**not** `ge`):
  `LD_LIBRARY_PATH=../GoldenEye-Recomp-rexglue/out/linux-amd64 ./out/build/linux-amd64-relwithdebinfo/GoldenEye --game_data_root=$PWD/assets --ge_gamestate_diag=true`

## Verification log (Phase 2 safety matrix)
Date: 2026-07-03  Build: commits through `03e4629` (branch `feat/weapon-direct-switch`)
Case results: 1:pass (idle, instant, draw anim correct) 2:pass (request dropped while
firing, retried automatically, lands cleanly on release) 3:pass (mid-reload) 4:pass
(dual grant + dual→single via the pair-call, both hands correct, no revert) 5:pass
(same-id no-op) 6:pass (rapid two ids, last one wins, no corruption) 7:record-only
(unheld id is granted by the raw guest entry, usually at 0 ammo — the driver's
held-mask guard is what protects the integrated `RequestEquipWeapon` path from this).

## Integrated desktop verification log (Phase 3)
Date: 2026-07-03  Build: commits through `03e4629`
All-pass through the real `RequestEquipWeapon` consumers (digit keys, scrollwheel,
DS-menu path): (1) digits — instant both directions, including jumps that land on a
dual-wield entry (accepted as intended UX); (2) scrollwheel — instant both directions
(next/prev), required the SDK GTK discrete-scroll fix (rexglue `fix/gtk-discrete-scroll`
@ `e84b8b7`) to arm at all; (3) fire-blocked switches land cleanly on trigger release
via the retry loop; (4) mid-reload switch OK; (5) dual-wield dwell stable, no revert to
unarmed; (6) `ge_weapon_direct_switch=false` — Y-cycle fallback still functional
(confirmed unreliable-by-cycling as expected, which is why it was replaced).
