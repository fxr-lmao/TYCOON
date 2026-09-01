# 3D Placement-Sim Tycoon

Grid-based 3D tycoon. Place machines on a grid, machines produce money on a
fixed tick, money buys more machines.

Built in **Xogot (Godot 4.4 on iPad)**. That constrains everything below:
GDScript only, no C#, no GDExtension, no native addons, no terminal, no build
step. Touch-first input — assume no mouse, no keyboard, no hover.

## Division of labour

| Owner  | Files |
| ------ | ----- |
| Claude | `res://scripts/**/*.gd` |
| Victor | `.tscn`, `.tres`, `project.godot`, all assets |

Scripts may *read* scene files to learn real node names. Scripts never edit
them. If a script needs a node that doesn't exist, that goes in the PR
description as a request, not into a scene file.

## Layers

```
Simulation — pure data, no scene tree
  scripts/grid_util.gd       Static grid <-> world maths. Owns CELL_SIZE.
  scripts/machine_type.gd    Resource. One kind of machine, tuned in Inspector.
  scripts/placed_machine.gd  RefCounted. One machine instance's live state.
  scripts/grid_sim.gd        Autoload "GridSim". Money, occupancy, tick loop.

View — reacts to GridSim signals
  scripts/world_view.gd      Spawns/frees 3D nodes under World/Machines.
  scripts/placement.gd       Touch raycast -> grid cell. Ghost preview.
  scripts/camera_rig.gd      Pan / pinch-zoom / twist-rotate.
  scripts/ui/hud.gd          Balance, income, mode buttons.
  scripts/ui/shop_panel.gd   Buy menu, built from the catalogue.
  scripts/ui/ui_format.gd    Static number formatting.
```

## The one hard rule

`grid_sim.gd` never touches the scene tree. No `get_node`, no `add_child`, no
`MeshInstance3D`, no `Camera3D` — and no `Vector3` either, which is why
`grid_util.gd` exists. GridSim is pure data that emits signals; the view layer
reacts.

If a change seems to need a node reference inside `GridSim`, that logic belongs
in the view layer. This separation is what lets the economy be rewritten without
breaking scenes, and scenes be rebuilt without breaking the economy.

## Conventions

- Grid is `Vector2i` on the XZ plane. Grid Y maps to world Z. `CELL_SIZE = 1.0`.
  Cell `(0, 0)` is **centred** on the world origin, so cell `c` spans
  `c - 0.5 .. c + 0.5`.
- The economy runs on a fixed tick, never per-frame. `GridSim._process` is used
  only as a clock: it accumulates `delta` and resolves whole ticks, so the
  outcome is identical at 60fps, 120fps and while thermal-throttled.
- Multi-cell machines appear in `_occupancy` under every cell they cover, all
  pointing at the same object. **Never iterate `_occupancy` to tick** — iterate
  `_machines`, or a 2x2 machine pays out four times.
- New machine kinds are `.tres` files in `res://data/machines/`. They are
  discovered automatically at startup. Adding a machine must never require a code
  change; if a feature would, the fix is a new `@export` on `MachineType`.
- UI reads GridSim signals and calls back into GridSim. UI never reaches into
  machine nodes.
- Balance numbers (costs, rates, refund fractions) live in `.tres` or exported
  vars. Never hardcoded in logic.
- Everything is statically typed. There is no way to run the game from the
  authoring side, so the compiler is the only reviewer available.

## Scene tree this code expects

```
Main (Node3D)
├── World (Node3D)                                 <- world_view.gd
│   ├── Ground (StaticBody3D + MeshInstance3D)     raycast target, y = 0
│   ├── GridVisual (MeshInstance3D)
│   ├── Machines (Node3D)                          spawned into at runtime
│   └── PlacementGhost (Node3D)                    <- placement.gd
├── CameraRig (Node3D)                             <- camera_rig.gd
│   └── Camera3D
└── UI (CanvasLayer)                               <- hud.gd, shop_panel.gd
```

`World`, `Machines` and `PlacementGhost` should sit at the origin with identity
transforms — the view scripts position machines and the ghost in local space
relative to their container.

Never hand-author children of `World/Machines`. They are spawned and freed by
`world_view.gd` in response to GridSim signals.

## Git

- One feature per branch and PR. Small PRs — they get reviewed on an iPad.
- Never commit to `main` directly.
- `.godot/` is gitignored. `*.import` files are committed — removing them makes
  every pull trigger a full reimport.
- PR descriptions list: what changed, what needs wiring up in the editor, and
  what to watch for when testing.
