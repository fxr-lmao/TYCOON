class_name MachineType
extends Resource

## One kind of machine.
##
## Authored as a [code].tres[/code] in [code]res://data/machines/[/code] and tuned
## entirely in the Inspector. [GridSim] discovers every resource in that folder at
## startup, so adding a new machine must never require a code change. If a new
## machine idea needs behaviour that is not expressible here, the fix is a new
## [code]@export[/code] on this resource, not a special case in the simulation.

@export_group("Identity")

## Stable key. Must be unique across the whole catalogue and must never change
## once a save file exists - it is what a save refers to.
@export var id: StringName = &""

## Name shown in the shop. Falls back to [member id] when empty.
@export var display_name: String = ""

@export_multiline var description: String = ""

## Shop icon. Optional.
@export var icon: Texture2D

## The 3D representation spawned under World/Machines. Its origin should be the
## centre of its footprint, sitting on the ground plane (y = 0). Optional - the
## view layer spawns a plain placeholder box when this is empty.
@export var scene: PackedScene

## Lower values appear earlier in the shop. Ties break on cost, then name.
@export var sort_order: int = 0


@export_group("Footprint")

## Footprint in cells, before rotation. Both axes are clamped to at least 1.
@export var size: Vector2i = Vector2i.ONE


@export_group("Economy")

## Price of the first one. Balance value - Victor's call.
@export var cost: int = 10

## Each machine of this kind already owned multiplies the price by this much.
## 1.0 means a flat price forever.
@export_range(1.0, 4.0, 0.01, "or_greater") var cost_growth: float = 1.0

## Average money produced per simulation tick.
@export var income_per_tick: int = 1

## Payout lumpiness. 1 pays every tick. N pays [member income_per_tick] * N once
## every N ticks, so the long-run rate is unchanged either way.
@export_range(1, 60, 1, "or_greater") var ticks_per_payout: int = 1

## Fraction of the price actually paid that comes back when the machine is sold.
@export_range(0.0, 1.0, 0.01) var refund_ratio: float = 0.5


## Footprint with both axes forced to at least 1 cell.
func clamped_size() -> Vector2i:
	return Vector2i(maxi(1, size.x), maxi(1, size.y))


## Footprint after [param rotation_steps] quarter turns.
func footprint_size(rotation_steps: int = 0) -> Vector2i:
	return GridUtil.rotate_size(clamped_size(), rotation_steps)


## Number of grid cells this machine occupies.
func cell_count() -> int:
	var s: Vector2i = clamped_size()
	return s.x * s.y


## Price of the next one, given how many are already owned.
func cost_for_owned(owned: int) -> int:
	if owned <= 0 or cost_growth <= 1.0:
		return maxi(0, cost)
	return maxi(0, int(round(float(cost) * pow(cost_growth, float(owned)))))


## Name for the UI.
func label() -> String:
	if display_name.is_empty():
		return String(id)
	return display_name


## False for a half-filled resource. [GridSim] skips these at load time with a
## warning rather than letting them break placement later.
func is_valid() -> bool:
	return id != &"" and cost >= 0
