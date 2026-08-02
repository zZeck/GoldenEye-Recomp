// ge - guest game-state bridge (carried weapons / ammo + active-weapon switch).
//
// This file is yours to edit. 'rexglue migrate' will NOT overwrite it.
//
// PURPOSE
//   The dual-screen weapon menu (a second-screen ImGui surface) needs to (a)
//   read what the player is currently carrying, what is equipped, and how much
//   ammo each weapon has, and (b) ask the game to switch to a chosen weapon --
//   WITHOUT the UI thread ever reaching into guest memory directly (that races
//   the game thread that mutates the same structs every frame).
//
//   This bridge owns that boundary. The game thread publishes a thread-safe
//   `WeaponSnapshot` once per frame from a guest hook (see ge_gamestate.cpp,
//   pumped from ge_hooks.cpp); any other thread reads a consistent copy via
//   GetWeaponSnapshot(). Equip requests flow the other way: any thread posts
//   one with RequestEquipWeapon() and the actuation driver in ge_hooks.cpp
//   (game thread) walks the game to the target over the following frames.
//
// THREAD-SAFETY CONTRACT
//   - GetWeaponSnapshot()    : callable from ANY thread, lock-free, never blocks,
//                              never touches guest memory. Returns the most
//                              recently published frame's snapshot.
//   - RequestEquipWeapon()   : callable from ANY thread, lock-free, non-blocking.
//                              Coalescing: only the most recent request before
//                              the next frame is applied.
//   - OnFrame()              : called ONLY from the game/guest thread (a per-frame
//                              hook). Not part of the menu-facing API.
//
// This header intentionally pulls in NOTHING from the recompiler/PPC generated
// code, so the second-screen UI translation unit can include it cheaply.

#pragma once

#include <cstdint>

namespace ge::gamestate {

// Upper bound on weapon slots we track in a snapshot. GoldenEye's full weapon
// enum is larger than what a player carries at once; this bounds the per-slot
// arrays / bitmask. Sized generously so a held-weapon id can index ammo[] and
// be addressed by the held bitmask without overflow.
inline constexpr int kMaxWeaponSlots = 32;

// Sentinel for "no weapon" / "unknown equipped weapon".
inline constexpr int32_t kNoWeapon = -1;

// A consistent, point-in-time view of the player's weapon state. POD + trivially
// copyable so GetWeaponSnapshot() can hand back a by-value copy.
struct WeaponSnapshot {
  // False until the bridge has located a live, plausible player/inventory struct
  // in guest memory (e.g. still at the title screen, or the guest layout
  // constants have not been confirmed on-device yet). When false, every other
  // field is zero/sentinel and the menu should render an "unavailable" state
  // rather than trust stale values.
  bool valid = false;

  // Bridge frame counter at publish time (monotonic, increments once per pumped
  // game frame). Lets a consumer detect a stalled producer.
  uint32_t frame = 0;

  // The weapon id the game currently has equipped, or kNoWeapon. Same id space
  // as held_ids[] / the argument to RequestEquipWeapon().
  int32_t equipped_id = kNoWeapon;

  // Carried-weapon set as a bitmask: bit i set => weapon/slot id i is held.
  // Cheap to test from the UI ("is the player carrying X?").
  uint32_t held_mask = 0;

  // Dense list form of the same set: held_ids[0..held_count) are the ids the
  // player is carrying, in slot order. held_count <= kMaxWeaponSlots.
  uint8_t held_count = 0;
  uint8_t held_ids[kMaxWeaponSlots] = {};

  // Ammo indexed by weapon/slot id (NOT by position in held_ids). ammo[id] is
  // only meaningful when (held_mask & (1u << id)) is set. Combined reserve count
  // for that weapon (clip semantics are documented in ge_gamestate.cpp).
  uint16_t ammo[kMaxWeaponSlots] = {};
};

// Returns the most recently published snapshot. Lock-free, wait-free for the
// reader, safe from any thread. If the producer is mid-write the call retries
// internally and still returns a self-consistent (never torn) snapshot.
WeaponSnapshot GetWeaponSnapshot();

// Requests that the game switch the active weapon to `weapon_id` (an id from
// the snapshot's held set). Non-blocking: the request is recorded here and
// actuated by the game-thread driver in ge_hooks.cpp over the following frames.
// Targets not held per the current snapshot (or with no valid snapshot) are
// cleared by the driver without switching. Calling again before actuation
// completes replaces the pending request (last-writer-wins).
void RequestEquipWeapon(int32_t weapon_id);

// Non-clearing read of the pending equip target (kNoWeapon if none). The
// actuation driver (ge_hooks) polls this across frames while it cycles the
// game's native weapon-switch input, then calls ClearEquipRequest() once the
// equipped weapon matches (or it gives up). Callable from any thread.
int32_t PeekEquipRequest();
void ClearEquipRequest();

// Diag-only (Phase-2 verification harness): post a weapon id for the driver
// to switch to via the verified two-hand pair call (see ge_direct_equip in
// ge_hooks.cpp -- one hook invocation issues sub_820A6F70 for hand 0 AND
// hand 1 back-to-back, so a single switch clears the off-hand and a
// dual-wield weapon grants both hands; no separate hand argument needed).
// TakeDirectEquip returns-and-clears the pending id (kNoWeapon if none).
// Callable from any thread. No-ops in normal play (only the memscan `equip`
// command posts).
void PostDirectEquip(int32_t weapon_id);
int32_t TakeDirectEquip();

// Game-thread per-frame pump. Reads guest memory and publishes a fresh
// snapshot. (Equip actuation does NOT happen here -- see the driver in
// ge_hooks.cpp.) MUST be called only from a guest-thread
// hook with the live PPC context. `ppc_ctx` is a PPCContext* (passed as void* so
// this header stays free of generated headers); `guest_base` is the guest
// virtual membase. See the call site in ge_hooks.cpp.
void OnFrame(void* ppc_ctx, uint8_t* guest_base);

}  // namespace ge::gamestate
