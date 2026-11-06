# Changelog

## 1.1.3 - 2026-10-28

- Add a bounded native-only warning boost using two simultaneous local voices;
  set `reminder.soundLayers` to 1 to restore the original level.
- Keep the same warning cue, double-beep timing, GTA SFX volume and background
  muting behavior. Stop and release every voice on completion or cancellation.

## 1.1.2 - 2026-10-28

- Seatbelt reminders use a client-local native GTA double beep, following the
  game's SFX volume and mute-on-focus-loss setting instead of browser audio.
- Keep the existing reminder delay, repeat interval, seat restrictions and
  buckle/harness behavior. Cancel pending beeps when no longer eligible.
- Release native sound IDs on completion, cancellation and resource stop;
  discard expired second beeps instead of replaying a backlog after a stall.
- Positive reminder volume uses GTA SFX volume; zero still disables the sound.
- Buckle/unbuckle sounds and the visual indicator remain unchanged.

## 1.1.0 - 2026-10-21

- Personal and owner-shared saved-prop / animation libraries with dropdown access.
- Library add/update/remove persists to the selected JSON/SQL backend; no schema change.
- Saved animations retain dictionary, clip, timing, speed and enabled setting.
- Owner permissions, personal asset policy, allowlists, deduplication and 32-entry limits enforced server-side.
- Prop and animation changes explicitly retain the current six-axis calibration.
- Pending numeric/gizmo adjustments are applied before previewing or saving new assets.
- Server assets loads only prop/gestures, keeping the calibration and selected bone.
- Clearly named Reset calibration replaces Initial fit; removed the destructive personal-reset shortcut.
- Calibration persistence and asset-switch regressions covered by browser and isolated Lua tests.

## 1.0.0 - 2026-10-21

- RealitySucksRP-branded fork of qbx_seatbelt; upstream GPLv3 and bundled MIT notices retained.
- Internal Qbox, QBCore and ESX framework adapters; ox, qb and native ESX harness inventory paths.
- Owner-only, personal-fit and full-personal policies, with optional personal asset allowlists.
- Live prop/bone selection, combined dictionary/clip fields, gesture timing and test buttons.
- Existing actual-ped camera, Three.js gizmo, sounds, warning and HUD icon retained.
- Server-wide published default and isolated per-character saves; reset to server default.
- JSON persistence with last-write backup, or optional parameterized SQL storage.
- Legacy calibration import without changing the original saved file.
- Correct remote-ped saved profiles; unsaved editor assets/offsets stay local.
- Bounded, request-correlated replies with explicit permission/storage errors and stale-reply isolation.
- Harness item-name validation and server-issued, elapsed-time, same-character/vehicle equip sessions.
- Plug-and-play installation, policy, inventory, SQL, upgrade and rollback instructions.

This build is source/browser/simulation checked. Real FiveM, multiplayer, actual SQL and
non-Qbox server acceptance remain required. Activation on the current server is deferred
to the next planned restart at the owner's request.
