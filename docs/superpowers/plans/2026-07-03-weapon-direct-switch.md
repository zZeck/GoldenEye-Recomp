# Weapon Direct-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `RequestEquipWeapon(id)` switch weapons instantly by calling the game's own direct-switch guest function (discovered by tracing the pause-menu inventory path), with the shipped Y-cycle mechanism kept as automatic fallback — and hook up number keys 1–9 + scrollwheel on desktop as the test surface.

**Architecture:** All actuation lives in the guest-thread driver inside `ge_inject_keyboard` (`src/ge_hooks.cpp`); the thread-safe request API stays in `src/ge_gamestate.{h,cpp}`. Discovery instruments the known per-hand weapon applier `sub_820A7508` via a midasm hook and uses the pause-menu inventory as the oracle. A diag `equip` command in the memscan channel exercises the direct call in isolation before integration.

**Tech Stack:** C++23, ReXGlue recomp SDK (midasm hooks via `ge_config.toml` + `rexglue codegen`), guest PPC functions callable as host C++ (`sub_XXXXXXXX(*ctx, base)`), REXCVAR cvars, manual desktop verification (no unit-test harness exists for guest-memory behavior — spec explicitly scopes testing as manual per phase).

**Spec:** `docs/superpowers/specs/2026-07-03-weapon-direct-switch-design.md`
**Prior RE trail:** `docs/HANDOFF-weapon-switch-direct-call.md`

## Global Constraints

- Build: `cmake --build --preset linux-amd64-relwithdebinfo --target ge` (run from repo root `/home/keith/Projects/GoldenEye-Recomp`).
- Run binary is `out/build/linux-amd64-relwithdebinfo/GoldenEye` — **not** `ge`:
  `LD_LIBRARY_PATH=../GoldenEye-Recomp-rexglue/out/linux-amd64 ./out/build/linux-amd64-relwithdebinfo/GoldenEye --game_data_root=$PWD/assets`
- After ANY edit to `ge_config.toml`, codegen MUST be rerun before building:
  `../GoldenEye-Recomp-rexglue/out/linux-amd64/rexglue codegen --max_jump_table_entries 2048 ge_config.toml`
  (RECIPE STALE — discovered during execution: the working invocation is
  `REX_MAX_JUMP_TABLE_ENTRIES=2048 .../rexglue codegen ge_manifest.toml`; see
  docs/HANDOFF-weapon-scrollwheel-select.md.)
- `generated/` is gitignored (game-derived). Commits include only `ge_config.toml`, `src/`, and `docs/`.
- New cvar defaults: `ge_weapon_select_enable=true`, `ge_weapon_direct_switch=true`, keybind cvars `ge_key_wpn_next="WheelUp"`, `ge_key_wpn_prev="WheelDown"`.
- Writing the equipped-id guest memory (`0x447f10b0` and mirrors) does NOT switch weapons and corrupts an agreement gate — confirmed dead end, do not retry.
- Guest functions may only be called on a guest thread with the live `PPCContext` (inside a midasm hook, via `getcb`).
- The Y-cycle driver code path must survive intact — it is the fallback (`ge_weapon_direct_switch=false` must always work).
- Verification is manual (build → run → observe). Each task ends with a desktop check; Android/Thor only in the final task.

## Reference: key existing code

- Actuation driver: `src/ge_hooks.cpp:1533-1558` (block inside `ge_inject_keyboard`, ABOVE the `ge_keyboard_enable`/`ge_input_active` early-return at line 1560 — it must run regardless of keyboard toggle).
- Disabled temp N-key block: `src/ge_hooks.cpp:1590-1609` (`#if 0`).
- Request API: `src/ge_gamestate.h:91-98` (`RequestEquipWeapon`, `PeekEquipRequest`, `ClearEquipRequest`), snapshot struct at 49–78.
- memscan command dispatch: `src/ge_gamestate.cpp:476-533` (`dispatch()`), poll at 536, called from `OnFrame` at line 702 behind `ge_gamestate_diag`.
- Midasm hook registration: `ge_config.toml` `[[midasm_hook]]` blocks (address/name/registers/after_instruction), e.g. lines 120–124.
- Hook implementation pattern: `src/ge_hooks.cpp` — `void ge_name(PPCRegister& rX...)` + `PPCContext* ctx; uint8_t* base; getcb(ctx, base);`. `ctx->lr` is a plain `uint64_t` holding the guest return address.
- Direct guest calls from hooks (existing examples): `ge_hooks.cpp:1682` `if (...) sub_820B3E90(*ctx, base);`, `:1768` `ctx->r3.u32 = buf; sub_82144970(*ctx, base);`. Declarations come from `generated/ge_init.h` (already included via `ge_init.h`).
- Cross-file cvar read: `REXCVAR_DECLARE(bool, name);` then `REXCVAR_GET(name)` (`rex/cvar.h:301`).
- Key names → `rex::ui::VirtualKey`: `rex::ui::ParseVirtualKey("1")` … `"9"`, `"WheelUp"`, `"WheelDown"` all exist in the SDK keybind table (`GoldenEye-Recomp-rexglue/src/ui/keybinds.cpp:77-148`).

---

### Task 1: Y-cycle driver cleanups (guard, mid-cycle reset, stale docs)

The three review items queued from the scrollwheel work. Behavior change: the driver refuses targets the player isn't carrying, and restarts cleanly when a new target is posted mid-cycle.

**Files:**
- Modify: `src/ge_hooks.cpp:1526-1558` (actuation driver block)
- Modify: `src/ge_gamestate.h:5-27` (PURPOSE + contract block), `:85-91` (`RequestEquipWeapon` doc), `:100-105` (`OnFrame` doc)

**Interfaces:**
- Consumes: `ge::gamestate::{PeekEquipRequest, ClearEquipRequest, GetWeaponSnapshot, kNoWeapon, kMaxWeaponSlots}` (existing).
- Produces: no API change. Driver invariant later tasks rely on: an unheld/out-of-range/invalid-snapshot target is cleared without actuation; posting a new target mid-cycle restarts counters.

- [ ] **Step 1: Replace the driver block** at `src/ge_hooks.cpp:1533-1558` (keep the explanatory comment above it, lines 1526–1532) with:

```cpp
  {
    constexpr int kMaxSteps = 16;     // total Y presses before giving up
    constexpr int kStepTimeout = 90;  // frames to wait for one switch to land
    static int steps = 0, wait = 0;
    static bool pressed = false;
    static int32_t equipped_at_press = 0;
    static int32_t last_target = ge::gamestate::kNoWeapon;
    const int32_t target = ge::gamestate::PeekEquipRequest();
    if (target == ge::gamestate::kNoWeapon) {
      steps = 0; wait = 0; pressed = false;
      last_target = ge::gamestate::kNoWeapon;
    } else {
      if (target != last_target) {
        // New target posted mid-cycle: restart the walk toward it.
        steps = 0; wait = 0; pressed = false;
        last_target = target;
      }
      const auto snap = ge::gamestate::GetWeaponSnapshot();
      const bool held = target >= 0 && target < ge::gamestate::kMaxWeaponSlots &&
                        (snap.held_mask & (1u << target)) != 0;
      if (!snap.valid || !held) {
        // Guard: no live inventory, or a weapon the player isn't carrying --
        // never cycle toward it; drop the request.
        ge::gamestate::ClearEquipRequest();
        steps = 0; wait = 0; pressed = false;
        last_target = ge::gamestate::kNoWeapon;
      } else if (snap.equipped_id == target || steps >= kMaxSteps) {
        ge::gamestate::ClearEquipRequest();
        steps = 0; wait = 0; pressed = false;
        last_target = ge::gamestate::kNoWeapon;
      } else if (pressed && snap.equipped_id == equipped_at_press && wait < kStepTimeout) {
        ++wait;  // previous switch still in flight; keep Y released
      } else {
        // First step, or the previous switch landed / timed out: press Y once.
        ST16(base, GE_PAD0 + 0, LD16(base, GE_PAD0 + 0) | BTN_Y);
        equipped_at_press = snap.equipped_id;
        pressed = true; ++steps; wait = 0;
      }
    }
  }
```

Note the behavioral equivalences with the old code: old `done = !snap.valid || equipped == target` cleared on invalid snapshots — the new guard branch preserves that (clears on `!snap.valid`) while also rejecting unheld ids.

- [ ] **Step 2: Fix the stale docs in `src/ge_gamestate.h`.** Three edits:

(a) Replace lines 12–17 (the paragraph beginning "This bridge owns that boundary.") with:

```
//   This bridge owns that boundary. The game thread publishes a thread-safe
//   `WeaponSnapshot` once per frame from a guest hook (see ge_gamestate.cpp,
//   pumped from ge_hooks.cpp); any other thread reads a consistent copy via
//   GetWeaponSnapshot(). Equip requests flow the other way: any thread posts
//   one with RequestEquipWeapon() and the actuation driver in ge_hooks.cpp
//   (game thread) walks the game to the target over the following frames.
```

(b) Replace the `RequestEquipWeapon` doc comment (lines 85–90) with:

```cpp
// Requests that the game switch the active weapon to `weapon_id` (an id from
// the snapshot's held set). Non-blocking: the request is recorded here and
// actuated by the game-thread driver in ge_hooks.cpp over the following frames.
// Targets not held per the current snapshot (or with no valid snapshot) are
// cleared by the driver without switching. Calling again before actuation
// completes replaces the pending request (last-writer-wins).
```

(c) In the `OnFrame` doc comment (lines 100–105), replace the first sentence
"Game-thread per-frame pump. Reads guest memory, publishes a fresh snapshot,
and applies any pending equip request." with:

```
// Game-thread per-frame pump. Reads guest memory and publishes a fresh
// snapshot. (Equip actuation does NOT happen here -- see the driver in
// ge_hooks.cpp.)
```

- [ ] **Step 3: Build**

Run: `cmake --build --preset linux-amd64-relwithdebinfo --target ge`
Expected: clean build, no warnings in `ge_hooks.cpp`.

- [ ] **Step 4: Manual verification (desktop)**

Run: `LD_LIBRARY_PATH=../GoldenEye-Recomp-rexglue/out/linux-amd64 ./out/build/linux-amd64-relwithdebinfo/GoldenEye --game_data_root=$PWD/assets --ge_gamestate_diag=true`

Start a mission, pick up a second weapon. Then drive the request path via memscan (proves the driver still works end-to-end):
- `echo 'snap' > /tmp/ge_scan.cmd` → `/tmp/ge_scan.out` shows `valid=1`, an `equipped_id`, `held_count >= 2`.
- Weapon switching with E still works normally (driver idle path untouched).

Expected: no behavior change in normal play.

- [ ] **Step 5: Commit**

```bash
git add src/ge_hooks.cpp src/ge_gamestate.h
git commit -m "fix(weapons): guard equip driver against unheld targets, reset cleanly on retarget, fix stale bridge docs"
```

---

### Task 2: Number keys 1–9 and scrollwheel weapon selection (desktop)

The Phase-0 test surface: digits jump to the Nth carried weapon, wheel steps next/prev. Drives the existing (Y-cycle) path — instant-ness arrives in Task 6 with zero changes here.

**Files:**
- Modify: `src/ge_hooks.cpp` — cvar definitions near the other `ge_key_*` cvars (after line 1489), input handler replacing the `#if 0` block at lines 1590–1609.

**Interfaces:**
- Consumes: `ge::gamestate::{GetWeaponSnapshot, RequestEquipWeapon}`; `g_listener.key_down(VirtualKey)`; `ge_key_down(cvar_name)` helper (`ge_hooks.cpp:1459`); `rex::ui::ParseVirtualKey`.
- Produces: cvars `ge_weapon_select_enable` (bool), `ge_key_wpn_next` / `ge_key_wpn_prev` (string keybinds). Task 6's verification uses these inputs.

- [ ] **Step 1: Define the cvars.** After the existing keybind cvar block (line 1489, after `ge_key_back`), add:

```cpp
REXCVAR_DEFINE_BOOL(ge_weapon_select_enable, true, "Input",
                    "Number keys 1-9 / scrollwheel select carried weapons");
REXCVAR_DEFINE_STRING(ge_key_wpn_next, "WheelUp", "Input/Keybinds", "Next carried weapon");
REXCVAR_DEFINE_STRING(ge_key_wpn_prev, "WheelDown", "Input/Keybinds", "Previous carried weapon");
```

- [ ] **Step 2: Replace the `#if 0` temp block** (`src/ge_hooks.cpp:1590-1609`, including the `// TEMP (Task 1 verification...)` comment above it) with:

```cpp
  // Weapon selection: digits 1-9 jump straight to the Nth carried weapon, and
  // the scrollwheel steps next/prev through the carried list. Edge-triggered so
  // a held key posts exactly one request. Actuation happens in the driver
  // above (which walks or direct-calls the game to the target), so this block
  // only ever posts RequestEquipWeapon.
  if (REXCVAR_GET(ge_weapon_select_enable)) {
    static rex::ui::VirtualKey digit_vk[9] = {};
    static bool vk_init = false;
    if (!vk_init) {
      vk_init = true;
      const char* names[9] = {"1", "2", "3", "4", "5", "6", "7", "8", "9"};
      for (int i = 0; i < 9; ++i) digit_vk[i] = rex::ui::ParseVirtualKey(names[i]);
    }
    static uint16_t prev_digits = 0;
    static bool prev_next = false, prev_prev = false;
    const auto snap = ge::gamestate::GetWeaponSnapshot();
    if (snap.valid && snap.held_count > 0) {
      uint16_t digits = 0;
      for (int i = 0; i < 9; ++i)
        if (g_listener.key_down(digit_vk[i])) digits |= (uint16_t)(1u << i);
      for (int i = 0; i < 9 && i < snap.held_count; ++i)
        if ((digits & (1u << i)) && !(prev_digits & (1u << i)))
          ge::gamestate::RequestEquipWeapon(snap.held_ids[i]);
      prev_digits = digits;

      const bool next = ge_key_down("ge_key_wpn_next");
      const bool prev = ge_key_down("ge_key_wpn_prev");
      if ((next && !prev_next) || (prev && !prev_prev)) {
        int idx = 0;
        for (int i = 0; i < snap.held_count; ++i)
          if (snap.held_ids[i] == snap.equipped_id) { idx = i; break; }
        const int step = (next && !prev_next) ? 1 : -1;
        const int n = (idx + step + snap.held_count) % snap.held_count;
        ge::gamestate::RequestEquipWeapon(snap.held_ids[n]);
      }
      prev_next = next; prev_prev = prev;
    } else {
      prev_digits = 0; prev_next = false; prev_prev = false;
    }
  }
```

Placement: this stays at the END of `ge_inject_keyboard`, BELOW the
`ge_keyboard_enable`/`ge_input_active` early-return — selection input should
respect focus and the keyboard toggle (unlike the actuation driver above it).

- [ ] **Step 3: Build**

Run: `cmake --build --preset linux-amd64-relwithdebinfo --target ge`
Expected: clean build.

- [ ] **Step 4: Manual verification (desktop)**

Run the game (Global Constraints run command). In a mission with 3+ weapons
(pick up a KF7 — slappers + PP7 + KF7 minimum):
- Press `3` → game cycles to the 3rd carried weapon (visible Y-cycling is expected at this stage).
- Press `1` → cycles to slappers. Holding a digit posts only one request.
- Wheel up / wheel down → next / previous carried weapon.
- Press a digit higher than `held_count` → nothing happens.
- Known risk to check: if wheel events don't register (the synthetic
  `WheelUp`/`WheelDown` key may be too momentary for the per-frame poll), note
  it in the commit message and continue — digits are the required surface;
  fix wheel later against SDK behavior.

- [ ] **Step 5: Commit**

```bash
git add src/ge_hooks.cpp
git commit -m "feat(weapons): number keys 1-9 + scrollwheel select carried weapons (desktop)"
```

---

### Task 3: Discovery — trace the pause-menu switch to its entry function

Research task. Deliverable is **knowledge, captured in the handoff doc**: the guest address + argument semantics of the direct "switch to weapon" entry, meeting the spec's definition of done. The instrumentation code is a keeper (diag-gated).

**Files:**
- Modify: `ge_config.toml` (new midasm hook)
- Modify: `src/ge_hooks.cpp` (hook implementation)
- Modify: `docs/HANDOFF-weapon-switch-direct-call.md` (findings)

**Interfaces:**
- Consumes: `sub_820A7508` = per-hand applier, args `r3`=hand (1 then 0), `r4`=resolved weapon object from `sub_820A0D30` (prior RE, trusted).
- Produces: a "## Findings 2026-07 (pause-menu trace)" section in the handoff doc that Task 4 codes against: entry guest address, generated symbol name (`sub_XXXXXXXX`), per-register argument list, and how the target weapon is expressed (raw id / object / slot).

- [ ] **Step 1: Register the discovery hook.** In `ge_config.toml`, after the `ge_inject_keyboard` hook block (line 124), add:

```toml
# Phase-1 discovery (weapon direct-switch RE): entry of sub_820A7508, the
# per-hand weapon applier. Logs caller lr + args; diag-gated in ge_hooks.cpp.
[[midasm_hook]]
address = 0x820A7508
name = "ge_dbg_weapon_apply"
registers = ["r3", "r4"]
after_instruction = false
```

- [ ] **Step 2: Implement the hook.** In `src/ge_hooks.cpp`, next to the other diag hooks (e.g. before the CE section at line 1612). Also add `REXCVAR_DECLARE(bool, ge_gamestate_diag);` near the top of the file with the other declarations (the cvar is defined in `ge_gamestate.cpp:87`).

```cpp
// ===========================================================================
// Phase-1 discovery hook (weapon direct-switch RE; spec:
// docs/superpowers/specs/2026-07-03-weapon-direct-switch-design.md). Entry of
// sub_820A7508, the per-hand weapon applier -- the known bottom of the switch
// call chain. Logs the guest caller (lr) and args so a pause-menu inventory
// selection can be diffed against a Y-cycle switch: the first lr unique to
// the pause-menu path identifies the direct-switch caller. Inert unless
// ge_gamestate_diag is set (desktop RE sessions only).
// ===========================================================================
void ge_dbg_weapon_apply(PPCRegister& r3, PPCRegister& r4) {
  if (!REXCVAR_GET(ge_gamestate_diag)) return;
  PPCContext* ctx; uint8_t* base; getcb(ctx, base);
  const uint32_t obj = r4.u32;
  uint32_t w[4] = {0, 0, 0, 0};
  if (obj) for (int i = 0; i < 4; ++i) w[i] = LD32(base, obj + 4u * i);
  // 0x447f10b0 = equipped-id block (kEquipIdAddr in ge_gamestate.cpp); only
  // read here, inside the applier, when it is guaranteed live.
  REXKRNL_INFO("GEWPNAPPLY lr={:#010x} hand={} obj={:#010x} "
               "obj[0..3]={:#010x},{:#010x},{:#010x},{:#010x} equip={}",
               (uint32_t)ctx->lr, r3.u32, obj, w[0], w[1], w[2], w[3],
               (int32_t)LD32(base, 0x447f10b0u));
}
```

- [ ] **Step 3: Regenerate + build**

```bash
../GoldenEye-Recomp-rexglue/out/linux-amd64/rexglue codegen --max_jump_table_entries 2048 ge_config.toml
cmake --build --preset linux-amd64-relwithdebinfo --target ge
```

Expected: codegen completes; build links (`ge_dbg_weapon_apply` resolved).

- [ ] **Step 4: Capture the two call chains.** Run:

```bash
LD_LIBRARY_PATH=../GoldenEye-Recomp-rexglue/out/linux-amd64 \
  ./out/build/linux-amd64-relwithdebinfo/GoldenEye \
  --game_data_root=$PWD/assets --ge_gamestate_diag=true 2>&1 | tee /tmp/ge_wpn_re.log
```

In-game script (mission with 3+ carried weapons):
1. Press E 3–4 times, pausing ~2s between presses (cycle-path samples).
2. Drop a log separator: `echo 'snap' > /tmp/ge_scan.cmd` (emits a GEMSCAN line).
3. Open the pause menu (watch), directly select a NON-adjacent weapon. Resume.
4. Separator again, then pause-menu-select a second weapon. Quit.

Expected: `grep -c GEWPNAPPLY /tmp/ge_wpn_re.log` > 0, with the GEMSCAN separators splitting E-presses from menu selections.

- [ ] **Step 5: Identify the direct-path caller(s).**

```bash
grep GEWPNAPPLY /tmp/ge_wpn_re.log | sed 's/.*lr=/lr=/;s/ hand.*//' | sort | uniq -c
```

Compare lr values before vs after the separators. For each lr `0xL` unique to the pause-menu segments, locate the exact generated call site — the recomp materializes return addresses, so this is a literal grep:

```bash
grep -rn "lr = 0xL;" generated/           # exact call site (file:line)
```

Open the hit; scroll up to the enclosing `DEFINE_REX_FUNC(sub_XXXXXXXX) {` — that's the calling function. Read the PPC asm comments around the site to see how `r3`/`r4` were computed.

- [ ] **Step 6: Walk up to the callable entry.** For the calling function `sub_C` found above, decide: is it the direct-switch entry (takes an identifiable target-weapon argument and performs the full switch), or plumbing? To find *its* callers, grep for its call sites and their materialized lr values:

```bash
grep -rn "sub_C(ctx, base);" generated/   # every call site of sub_C
```

For each site, the preceding `ctx.lr = 0x...;` line gives the return address; the enclosing `DEFINE_REX_FUNC` gives the next caller up. Iterate until reaching a function whose target-weapon argument is synthesizable per the spec's definition of done:

> every argument is one of: an observed constant, a value readable from guest
> memory, or the output of the resolver (`sub_820A0D30`). An opaque argument
> (e.g. a pointer into pause-menu context that only exists while paused) means
> the candidate is too high — step one level down and re-check.

If a step is ambiguous from static reading, add a temporary `lr`-logging midasm hook at that function's entry (clone of Step 1/2 with the new address, e.g. name `ge_dbg_weapon_entry`) and re-run the Step-4 session to observe its args live. Remove temporary extra hooks when done; keep only `ge_dbg_weapon_apply`.

- [ ] **Step 7: Document findings.** Append to `docs/HANDOFF-weapon-switch-direct-call.md` a section:

```markdown
## Findings 2026-07 (pause-menu trace)
- Direct-switch entry: `sub_XXXXXXXX` (guest 0xXXXXXXXX)
- Arguments: r3 = <...>, r4 = <...> (each: constant / guest-mem read / resolver output)
- Target-weapon representation: <raw id | resolved object via sub_820A0D30 | slot index>
- Call chain observed: pause-menu ... -> sub_XXXXXXXX -> ... -> sub_820A7508
- Session log: key GEWPNAPPLY lines pasted here
```

Fill every `<...>` with observed values — this section is Task 4's coding contract.

- [ ] **Step 8: Commit**

```bash
git add ge_config.toml src/ge_hooks.cpp docs/HANDOFF-weapon-switch-direct-call.md
git commit -m "feat(weapons): discovery hook on the per-hand applier; document direct-switch entry RE findings"
```

**Failure exit:** if after ~3 focused sessions no entry meets the definition of done, STOP the plan here: document the dead ends in the handoff doc, commit, and report — Tasks 1–2 stand alone (spec's "entry never found" contingency). Tasks 4–6 are blocked without this task's findings.

---

### Task 4: `ge_direct_equip` + memscan `equip` verification harness

Codes the guest call per Task 3's findings, and a diag command to fire it in isolation.

**Files:**
- Modify: `src/ge_gamestate.h` (post/take API), `src/ge_gamestate.cpp` (atomic + `equip` verb)
- Modify: `src/ge_hooks.cpp` (`ge_direct_equip` + harness drive)

**Interfaces:**
- Consumes: Task 3's Findings section (entry symbol + argument recipe); `getcb`; `sub_820A0D30` (resolver, if the findings call for it).
- Produces: `bool ge_direct_equip(PPCContext* ctx, uint8_t* base, int32_t weapon_id)` in `ge_hooks.cpp` (file-local; returns false if the entry is unavailable) — Task 6 calls exactly this. `ge::gamestate::PostDirectEquip(int32_t)` / `int32_t ge::gamestate::TakeDirectEquip()` — harness-only API.

- [ ] **Step 1: Post/take API.** In `src/ge_gamestate.h`, after `ClearEquipRequest()` (line 98):

```cpp
// Diag-only (Phase-2 verification harness): post a weapon id for the driver to
// switch to via ONE direct guest call, bypassing the RequestEquipWeapon walk.
// TakeDirectEquip returns-and-clears the pending id (kNoWeapon if none).
// Callable from any thread. No-ops in normal play (only the memscan `equip`
// command posts).
void PostDirectEquip(int32_t weapon_id);
int32_t TakeDirectEquip();
```

In `src/ge_gamestate.cpp`, next to the other equip-request state (near the `RequestEquipWeapon` implementation):

```cpp
std::atomic<int32_t> g_direct_equip{kNoWeapon};
void PostDirectEquip(int32_t weapon_id) {
  g_direct_equip.store(weapon_id, std::memory_order_relaxed);
}
int32_t TakeDirectEquip() {
  return g_direct_equip.exchange(kNoWeapon, std::memory_order_relaxed);
}
```

- [ ] **Step 2: memscan `equip` verb.** In `dispatch()` (`src/ge_gamestate.cpp`), after the `"write"` branch (line 515), add:

```cpp
  } else if (nf >= 2 && std::strcmp(verb, "equip") == 0) {
    // Phase-2 harness: one direct-call switch, executed by the guest-thread
    // driver (ge_hooks.cpp) on its next poll. Watch the log for GEWPN lines.
    PostDirectEquip((int32_t)num(a));
    emit(out, "equip id=%d posted (direct-call; grep log for GEWPN)", (int32_t)num(a));
```

Also add ` | equip id` to the `??` usage string (line 530).

- [ ] **Step 3: Implement `ge_direct_equip`.** In `src/ge_hooks.cpp`, above `ge_inject_keyboard`. The body binds Task 3's Findings section; the two anticipated shapes are below — implement the one the findings match, keep the logging and save/restore exactly as shown. If the findings match neither shape (extra args), follow the same pattern: set each `ctx->rN` per the documented recipe.

```cpp
// Direct weapon switch: one call into the game's own switch routine (the
// pause-menu inventory path, discovered in the Phase-1 RE -- see
// docs/HANDOFF-weapon-switch-direct-call.md "Findings 2026-07"). MUST run on a
// guest thread inside a midasm hook. Returns false if the entry is not wired
// (integration then falls back to the Y-cycle walker). The full-context
// save/restore is required: we are mid-way through ge_inject_keyboard's host
// hook, and the generated caller resumes from ctx after we return -- a guest
// call here clobbers volatile registers/lr otherwise.
bool ge_direct_equip(PPCContext* ctx, uint8_t* base, int32_t weapon_id) {
  const int32_t before = (int32_t)LD32(base, 0x447f10b0u);  // equipped-id block
  const PPCContext saved = *ctx;

  // --- Shape A: entry takes the raw weapon id ---------------------------
  // ctx->r3.u32 = (uint32_t)weapon_id;      // per Findings: r3 = weapon id
  // sub_XXXXXXXX(*ctx, base);               // per Findings: the entry symbol
  // -----------------------------------------------------------------------

  // --- Shape B: entry takes a resolved weapon object --------------------
  // ctx->r3.u32 = (uint32_t)weapon_id;      // per Findings: resolver input
  // sub_820A0D30(*ctx, base);               // resolver (prior RE)
  // ctx->r4.u32 = ctx->r3.u32;              // per Findings: object -> arg reg
  // ctx->r3.u32 = <hand/other per Findings>;
  // sub_XXXXXXXX(*ctx, base);
  // -----------------------------------------------------------------------

  *ctx = saved;
  REXKRNL_INFO("GEWPN direct equip id={} equip_before={} equip_after={}",
               weapon_id, before, (int32_t)LD32(base, 0x447f10b0u));
  return true;  // wired; return false above if left unimplemented
}
```

(Until the chosen shape's lines are uncommented and the symbol filled in from
the Findings, the function must `return false;` before the call block —
never commit a state where it claims `true` without calling anything.)

- [ ] **Step 4: Harness drive.** In `ge_inject_keyboard`, immediately BEFORE the actuation driver block (before the comment at line ~1526):

```cpp
  // Phase-2 verification harness: an `equip <id>` posted from the memscan
  // command channel fires ONE direct switch, bypassing RequestEquipWeapon, so
  // the guest call can be exercised and observed in isolation. Diag-only.
  if (REXCVAR_GET(ge_gamestate_diag)) {
    const int32_t direct = ge::gamestate::TakeDirectEquip();
    if (direct != ge::gamestate::kNoWeapon) ge_direct_equip(ctx, base, direct);
  }
```

(`ctx`/`base` are already in scope from the `getcb` at the top of the function; `REXCVAR_DECLARE(bool, ge_gamestate_diag)` was added in Task 3.)

- [ ] **Step 5: Build**

Run: `cmake --build --preset linux-amd64-relwithdebinfo --target ge`
Expected: clean build.

- [ ] **Step 6: First live fire (desktop).** Run with `--ge_gamestate_diag=true` (Global Constraints command). In a mission, carrying 3+ weapons and NOT touching E:

```bash
echo 'snap' > /tmp/ge_scan.cmd        # note equipped_id and held ids
echo 'equip <held-id-not-equipped>' > /tmp/ge_scan.cmd
```

Expected: the weapon switches on screen — with draw animation — within a frame or two of the command; log shows the `GEWPN direct equip` line; a follow-up `snap` shows the new `equipped_id`. If the switch is instant-but-wrong (no animation, wrong hand, HUD desync) or nothing happens, iterate on the shape/args against the Findings — that iteration is this step, not a later fix.

- [ ] **Step 7: Commit**

```bash
git add src/ge_gamestate.h src/ge_gamestate.cpp src/ge_hooks.cpp
git commit -m "feat(weapons): direct-call equip (ge_direct_equip) + memscan equip verification harness"
```

---

### Task 5: Safety matrix (Phase-2 gate)

Pure verification session; the gate before integration. No code changes expected — if a case fails, the fix loops back into `ge_direct_equip` (Task 4) before this task can complete.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-03-weapon-direct-switch-design.md` (append verification log)

**Interfaces:**
- Consumes: `equip` harness (Task 4).
- Produces: a green matrix — Task 6's precondition.

- [ ] **Step 1: Run the matrix.** Desktop, `--ge_gamestate_diag=true`, mission with a dual-wield-capable loadout (e.g. grab a second D5K where available, or any mission where the game grants dualies). For each case, the pass bar is: draw animation plays, ammo/clip correct, HUD agrees, no fault-storm/`GEWATCHDOG` in the log.

| # | Case | How to drive |
|---|------|--------------|
| 1 | idle → different weapon | `echo 'equip N' > /tmp/ge_scan.cmd` while standing idle |
| 2 | while firing | hold fire, then post `equip N` |
| 3 | while reloading | fire a clip dry, post `equip N` during the reload |
| 4 | to and from dual-wield | `equip <dual-id>`, verify both hands; then `equip <single-id>` |
| 5 | same weapon as equipped | `equip <current-id>` → expect no-op or clean re-select, no state damage |
| 6 | rapid-fire requests | two `equip` posts ~1s apart (file mtime granularity limits faster) |
| 7 | unheld weapon id | `equip <unheld-id>` — NOTE: the harness bypasses the driver guard, so this tests the GUEST function's behavior; record what happens, do not rely on it. Recover with a normal switch after. |

- [ ] **Step 2: Record results.** Append to the spec file:

```markdown
## Verification log (Phase 2 safety matrix)
Date: <date>  Build: <git rev>  Case results: 1:<pass/fail+note> 2:... 7:...
```

Every case 1–6 must pass (case 7 is record-only). If 2/3/6 misbehave: add the "safe to switch" deferral gate to `ge_direct_equip`'s caller per the spec (defer while that state persists), re-run, and note the gate in the log.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-03-weapon-direct-switch-design.md
git commit -m "docs(weapons): Phase-2 safety-matrix verification log"
```

---

### Task 6: Integration — direct call under `RequestEquipWeapon` with Y-cycle fallback

**Files:**
- Modify: `src/ge_hooks.cpp` (cvar + driver block rework; forward-declare `ge_direct_equip` above the driver if it is defined below it)

**Interfaces:**
- Consumes: `ge_direct_equip` (Task 4, matrix-green per Task 5); driver invariants from Task 1.
- Produces: cvar `ge_weapon_direct_switch` (bool, default true). Public behavior: `RequestEquipWeapon` = instant switch; automatic downgrade to Y-cycle logged as `GEWPN direct switch did not land`.

- [ ] **Step 1: Define the cvar** next to `ge_weapon_select_enable` (Task 2):

```cpp
REXCVAR_DEFINE_BOOL(ge_weapon_direct_switch, true, "Input",
                    "Switch weapons via a direct game call (off = Y-cycle walk)");
```

- [ ] **Step 2: Rework the actuation driver.** Replace the Task-1 driver block in `ge_inject_keyboard` with (comment above the block updated to match):

```cpp
  // Weapon actuation: move the game to the pending target posted via
  // RequestEquipWeapon. Preferred mechanism: ONE direct call into the game's
  // own switch routine (instant; see ge_direct_equip). Fallback: pulse the
  // native Y (weapon-switch) button and wait for each switch to land -- kept
  // intact behind ge_weapon_direct_switch=false and as the automatic
  // downgrade when a direct call doesn't land within kDirectConfirm frames.
  {
    constexpr int kMaxSteps = 16;       // Y-cycle: total presses before giving up
    constexpr int kStepTimeout = 90;    // Y-cycle: frames for one switch to land
    constexpr int kDirectConfirm = 30;  // direct: frames to confirm before fallback
    static int steps = 0, wait = 0;
    static bool pressed = false;
    static int32_t equipped_at_press = 0;
    static int32_t last_target = ge::gamestate::kNoWeapon;
    static bool direct_tried = false;
    static int direct_wait = 0;
    const int32_t target = ge::gamestate::PeekEquipRequest();
    if (target == ge::gamestate::kNoWeapon) {
      steps = 0; wait = 0; pressed = false; direct_tried = false; direct_wait = 0;
      last_target = ge::gamestate::kNoWeapon;
    } else {
      if (target != last_target) {
        // New target posted mid-flight: restart both mechanisms toward it.
        steps = 0; wait = 0; pressed = false; direct_tried = false; direct_wait = 0;
        last_target = target;
      }
      const auto snap = ge::gamestate::GetWeaponSnapshot();
      const bool held = target >= 0 && target < ge::gamestate::kMaxWeaponSlots &&
                        (snap.held_mask & (1u << target)) != 0;
      if (!snap.valid || !held || snap.equipped_id == target || steps >= kMaxSteps) {
        // Done, unreachable, or guarded out -- drop the request.
        ge::gamestate::ClearEquipRequest();
        steps = 0; wait = 0; pressed = false; direct_tried = false; direct_wait = 0;
        last_target = ge::gamestate::kNoWeapon;
      } else if (REXCVAR_GET(ge_weapon_direct_switch) && !direct_tried) {
        direct_tried = true; direct_wait = 0;
        if (!ge_direct_equip(ctx, base, target))
          direct_wait = kDirectConfirm;  // entry unavailable: Y-cycle next poll
      } else if (direct_tried && steps == 0 && direct_wait < kDirectConfirm) {
        ++direct_wait;  // direct call issued; waiting for it to land
        if (direct_wait == kDirectConfirm)
          REXKRNL_INFO("GEWPN direct switch did not land; falling back to Y-cycle (target={})",
                       target);
      } else if (pressed && snap.equipped_id == equipped_at_press && wait < kStepTimeout) {
        ++wait;  // Y-cycle: previous switch still in flight
      } else {
        // Y-cycle: first press, or the previous switch landed / timed out.
        ST16(base, GE_PAD0 + 0, LD16(base, GE_PAD0 + 0) | BTN_Y);
        equipped_at_press = snap.equipped_id;
        pressed = true; ++steps; wait = 0;
      }
    }
  }
```

Control-flow notes (verify these when reading the diff): with the cvar OFF, the direct branch never runs and the block degenerates to exactly the Task-1 Y-cycle. With the entry unavailable (`ge_direct_equip` returns false), fallback begins on the next poll with no 30-frame stall. A landed direct switch hits the `snap.equipped_id == target` clear on the next poll.

- [ ] **Step 3: Build**

Run: `cmake --build --preset linux-amd64-relwithdebinfo --target ge`
Expected: clean build.

- [ ] **Step 4: Manual verification (desktop).** Run WITHOUT diag flags (defaults path):
- Digits 1–9: switch is **instant** (one draw animation, no visible cycling), including multi-step jumps and dual-wield targets.
- Scrollwheel: instant next/prev.
- Re-run safety-matrix cases 2, 3, 6 driving with digit keys instead of the harness.
- `--ge_weapon_direct_switch=false` run: digits still work via visible Y-cycling (fallback intact).
- Grep the session log: no unexpected `GEWPN direct switch did not land` lines during normal switches.

- [ ] **Step 5: Commit**

```bash
git add src/ge_hooks.cpp
git commit -m "feat(weapons): instant weapon switch -- direct guest call under RequestEquipWeapon, Y-cycle fallback"
```

---

### Task 7: Thor verification + handoff doc closeout

**Files:**
- Modify: `docs/HANDOFF-weapon-scrollwheel-select.md`, `docs/HANDOFF-weapon-switch-direct-call.md`

**Interfaces:**
- Consumes: everything shipped in Tasks 1–6 (the Android build uses the same `src/`; the DS menu already posts `RequestEquipWeapon`).
- Produces: verified Android behavior + closed-out docs.

- [ ] **Step 1: Build + install on the Ayn Thor**

```bash
cd android && ./gradlew :app:installDebug -PrexSdkDir=/home/keith/Projects/GoldenEye-Recomp-rexglue
```

(absolute `-PrexSdkDir` required; if install fails on version, `adb install -r -d`.)

- [ ] **Step 2: Verify on-device.** Launch, load a mission with 3+ weapons:
- Tap a weapon on the bottom-screen menu → switch is instant (no visible cycling).
- Play ~5 minutes switching frequently; then pull the log:
  `adb pull /sdcard/Android/data/com.sunjaycy.goldeneye/files/ge.log /tmp/thor_ge.log`
- Expected: no `GEWPN direct switch did not land` storm (occasional single lines acceptable — note them), no fault-storm/`GEWATCHDOG STALL`, game holds its usual frame rate.
- If the direct call misbehaves ONLY on-device: set `ge_weapon_direct_switch=false` via `SetFlagByName` in `GeApp::OnConfigurePaths` (`src/ge_app.h`) as the Android default, note it in the handoff doc, and keep desktop default on — that is the designed per-device escape hatch, not a failure of the task.

- [ ] **Step 3: Close out the docs.**
- `docs/HANDOFF-weapon-switch-direct-call.md`: change the Status line to resolved, pointing at the Findings section and this plan.
- `docs/HANDOFF-weapon-scrollwheel-select.md`: update the Status block — Task-1 cleanups done (this plan Task 1), old Task 2 shipped (this plan Task 2), direct-call optimization DONE; old Tasks 3–4 (numbered overlay + pause-menu toggle) remain open and move to the future quick-select design.

- [ ] **Step 4: Commit**

```bash
git add docs/HANDOFF-weapon-switch-direct-call.md docs/HANDOFF-weapon-scrollwheel-select.md
git commit -m "docs(weapons): close out direct-switch handoffs; Thor verification notes"
```
