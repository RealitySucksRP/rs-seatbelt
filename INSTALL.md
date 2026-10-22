# RS Seatbelt: Plug-And-Play Setup

## Windshield ejection setup

RS Seatbelt already calls `SetConvarReplicated` at resource start to enable this native FiveM feature. For clarity or earlier application, you can **also** add this replicated convar to `server.cfg`:

```cfg
setr game_enableFlyThroughWindscreen true
```

This enables FiveM's native crash ejection physics. `config/client.lua` adjusts the thresholds for unbuckled, buckled and harness states. Players are **not ejected just because they reach the threshold speed**: a qualifying collision is also required. Verify the feature on your own GTA Legacy/Enhanced builds, vehicle types and seats.

## Before installing or updating

- Use folder name `rs-seatbelt`. Stop `qbx_seatbelt` and other belt controllers,
  including belt control built into HUD resources. Do not run two controllers together.
- Keep backups of current `data/profiles.json`, `data/profiles.json.bak`, and any
  `data/seatbelt_alignment.json`. Release ZIPs include clean starter data; an upgrade
  must not overwrite customer saves or calibration.
- The supported frameworks are Qbox, QBCore and ESX. Standalone is not supported.
- Legacy and GTAV Enhanced require separate in-game verification. This distribution
  contains no independently verified Enhanced acceptance-test results.
- No other resources or `server.cfg` files are modified automatically. Any old radial
  menu reference to `qbx_seatbelt` needs a manual integration update.

## Fresh Server

1. Stop other seatbelt controllers and remove their `ensure` lines. Some HUDs include a
   built-in belt controller; disable that controller too, leaving their HUD indicator enabled.
2. Put the complete `rs-seatbelt` folder in your resources directory.
3. Choose ONE startup example below. Existing framework/inventory ensures should not be duplicated.
4. Grant ACE to a real admin group or identifier. A framework's admin role alone does not
   necessarily grant ACE: ensure your administrator belongs to the configured ACE principal.
5. Start/restart the server. Look for `[rs-seatbelt] Framework: ...; inventory: ...; storage: json`.

### Qbox + ox_inventory

```cfg
ensure ox_lib
ensure qbx_core
ensure ox_inventory
ensure rs-seatbelt
add_ace group.admin rs-seatbelt.admin allow
```

Keep your existing framework/database startup requirements. A `harness` item must exist in
`ox_inventory/data/items.lua`. The Qbox usable-item registration already forwards its slot.

### QBCore + qb-inventory

```cfg
ensure ox_lib
ensure qb-core
ensure qb-inventory
ensure rs-seatbelt
add_ace group.admin rs-seatbelt.admin allow
```

Define `harness` in QBCore's shared items as usable and unique; its metadata holds durability:

```lua
harness = { name='harness', label='Harness', weight=200, type='item', image='harness.png',
    unique=true, useable=true, shouldClose=true, description='Vehicle safety harness' },
```

Use your own inventory image. This resource includes a belt HUD icon, not an inventory harness image.
For QBCore + ox_inventory use the ox startup line instead and the item export below.

### ESX + Native Inventory

```cfg
ensure ox_lib
ensure es_extended
# Start your ESX inventory here, if it is a separate resource.
ensure rs-seatbelt
add_ace group.admin rs-seatbelt.admin allow
```

Add a standard item named `harness` using your ESX inventory's normal item setup.
Native ESX inventory has no per-slot item metadata: ONE harness is consumed each time it
is equipped. Qbox/ox and QBCore/qb instead wear durability by 5. Use ox_inventory if you
want slot-based durability on ESX. Do not assume every third-party inventory is compatible.

### ESX Or QBCore + ox_inventory

Start ox_inventory after your framework and before rs-seatbelt. Replace/add the harness
entry in ox_inventory's items table:

```lua
['harness'] = {
    label = 'Harness', weight = 200, stack = false, consume = 0,
    server = { export = 'rs-seatbelt.useHarness' }
},
```

Restart ox_inventory as part of a planned server restart after changing its item definition.
The export supplies the exact slot and prevents double consumption. Do not define both
`client.export` and this server export for the same item. Unknown custom inventories need
an adapter; framework support is not a promise of compatibility with every inventory fork.

## Owner Choices

Edit `config/server.lua` before starting. Full replacement examples:

```lua
personalMode = 'server',    -- Only owners edit/publish; every player uses the default.
-- OR
personalMode = 'alignment', -- Players save fit only; owner supplies prop and animations.
-- OR
personalMode = 'full',      -- Players save their own prop, animations and fit (default).
```

These are alternative values of ONE field, not three fields to paste together.
`framework` can be `auto`, `qbox`, `qbcore`, or `esx`.
`inventory` can be `auto`, `ox`, `qb` (QBCore), or `esx` (native ESX).
Pin these values when a compatibility bridge makes multiple framework names appear running.
Restart rs-seatbelt after configuration changes. Changing modes does not delete existing saves.

Optionally limit personal props and animation dictionaries:

```lua
allowedModels = { 'prop_cs_heist_bag_strap_01' },
allowedDictionaries = { 'oddjobs@basejump@ig_15', 'missfam3' },
```

Empty lists allow valid names. Restrictions apply to personal full-mode presets, including
previous saves when reloaded after restart. Owners are not restricted when publishing.

## JSON Or SQL

**JSON (default):** leave `storage = 'json'`. No SQL setup or oxmysql dependency is added by
RS Seatbelt. `data/profiles.json` is created on first start. It contains a separate entry
per framework character plus the server default. Do not overwrite it during updates.

**SQL (optional):** import `sql/install.sql` into YOUR existing server database, start
`oxmysql` before RS Seatbelt, set `storage = 'sql'`, restart. No database credentials belong
in this resource. The table is `rs_seatbelt_profiles`. Existing personal JSON records are
not automatically imported; switching modes selects a different store.

If JSON is corrupt, stop the resource and restore a known-good backup. Do not delete it
as a troubleshooting shortcut. If SQL fails, fix the database/table/connection; the resource
does not silently overwrite JSON instead. Standard B-key safety continues independently,
but customization and new harness equip cannot be confirmed while the service is unavailable.

## Player Steps

1. Sit in a supported car and press B. Wait for the strap to appear.
2. Type `/rsbelt` (alias `/rsbeltalign`). Appearance edits the model, bone and gestures;
   Alignment edits placement with the gizmo and camera.
3. Paste an animation in ONE box, for example:
   `oddjobs@basejump@ig_15 : puton_parachute`.
   The left side is the dictionary, the right side is the clip. Keep the colon separator.
4. Preview prop / Test fasten / Test unfasten check changes on your seated character.
   Only valid streamed object models and existing clips work. The editor cannot upload assets.
5. Save personal affects your character only. Owner-only Publish default changes the default.
   In full mode existing personal saves keep their own choices; enforce server mode to override everyone.
6. Your calibration stays in place when you change props or animations, including after saving
   and reopening. Make minor adjustments as needed. Server assets loads the owner's prop and
   gestures without changing your calibration or bone.
7. Only Reset calibration resets placement to the initial fit. It keeps your selected prop
   and animations, and stays unsaved until you choose Save personal or Publish default.
   Revert restores the opening preset. Cancel discards the unsaved preview.

All saves require a server confirmation. A timeout is NOT proof that a save failed to reach
storage: close/reopen to reload its actual state before retrying.

## Save Assets For Easy Access

1. In Appearance, type the model into Prop model and click the Save beside Saved props.
2. Type `dictionary : clip` into either gesture, adjust duration/speed, and click its Save
   beside Saved animations. This saves the dictionary AND clip as a reusable animation entry.
3. Pick an entry from the saved dropdown next time. Both animation dropdowns share the same
   animation library. Loading any entry keeps your current calibration and bone.
4. Players use My library. Owners can select Server library before saving to publish a
   reusable entry for other permitted editors. Only owners can add/remove shared entries.
5. Remove deletes the chosen saved entry only; it does not reset placement or change the
   current prop/animation. Up to 32 props and 32 animations fit in each library.
6. Save personal or Publish default still saves the active setup and calibration. Saving
   a favorite entry alone does not automatically equip it or change the active saved setup.

Libraries use the SAME JSON/SQL backend and character identity as presets. They persist
across reconnects and restarts. No new database table/import is needed. Back up the entire
JSON file (or SQL table) to include both presets and libraries. In alignment-only/server-only
mode ordinary players cannot choose their own assets; owner restrictions still apply.

## First In-Game Check

- B buckle/unbuckle: sound, icon, reminder, crash thresholds and vehicle exit behavior.
- Harness equip/remove, cancellation and item durability/consumption.
- `/rsbelt`: camera outside the body, model change, both animation tests and gizmo alignment.
- Save personal, reconnect, switch characters and restart: each character keeps its own values.
- Publish as owner; try as non-owner; test owner mode restrictions.
- Use two players: only saved straps are visible to the observer; Cancel never changes theirs.
- Save/load/remove personal and owner-shared assets; reconnect and verify the collections
  persist, selection keeps all calibration values, and non-owners cannot edit shared entries.

Browser/simulated tests have passed locally. They do not prove FiveM camera, sound, physics,
OneSync, or real QBCore/ESX/database operation. Perform this check before public release.

## Upgrade / Rollback

Stop the server before changing controllers. Back up this resource's `config/` and `data/`.
Keep live `profiles.json`, its backup and your legacy calibration when upgrading.
For SQL, back up the `rs_seatbelt_profiles` table using your database tools.

To roll back this migration: stop rs-seatbelt, restore the backed-up qbx_seatbelt folder,
replace `ensure rs-seatbelt` with `ensure qbx_seatbelt`, and restore the old ACE
`add_ace group.admin qbx_seatbelt.calibrate allow`. Start only the original controller.
The radial menu's new state-based harness check also works with the original controller.

Retain LICENSE and THIRD_PARTY_NOTICES.md when distributing this fork.
