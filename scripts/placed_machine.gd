class_name PlacedMachine
extends RefCounted

## One machine instance's live state. Pure data - it knows nothing about nodes.
##
## [GridSim] owns these. The view layer receives them through signals and uses
## them read-only to decide what to spawn and where.

## Unique per run. Also the key the view layer uses to track its spawned node.
var id: int = 0

## Which kind of machine this is. Never null for a machine [GridSim] accepted.
var type: MachineType = null

## Minimum corner of the (already rotated) footprint.
var origin: Vector2i = Vector2i.ZERO

## Quarter turns, 0..3.
var rotation_steps: int = 0

## Tick index at which this was placed. Used to phase lumpy payouts so machines
## bought at different times do not all pay out on the same tick.
var placed_at_tick: int = 0

## What was actually paid, which is what the refund is a fraction of. Stored
## rather than recomputed because [member MachineType.cost_growth] means the
## price at purchase time is not the price now.
var paid_cost: int = 0


## Footprint in cells, after rotation.
func footprint_size() -> Vector2i:
	if type == null:
		return Vector2i.ONE
	return type.footprint_size(rotation_steps)


## Every cell this machine occupies.
func cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var s: Vector2i = footprint_size()
	for y: int in range(s.y):
		for x: int in range(s.x):
			result.append(origin + Vector2i(x, y))
	return result


func occupies(cell: Vector2i) -> bool:
	var s: Vector2i = footprint_size()
	var d: Vector2i = cell - origin
	return d.x >= 0 and d.y >= 0 and d.x < s.x and d.y < s.y


## Money produced on tick [param tick_index]. Zero on ticks between lumpy payouts.
func income_for_tick(tick_index: int) -> int:
	if type == null:
		return 0
	var period: int = maxi(1, type.ticks_per_payout)
	if period == 1:
		return type.income_per_tick
	var elapsed: int = tick_index - placed_at_tick
	if elapsed <= 0 or elapsed % period != 0:
		return 0
	return type.income_per_tick * period


## Long-run rate, ignoring payout lumpiness. This is the number the HUD shows.
func average_income_per_tick() -> int:
	if type == null:
		return 0
	return type.income_per_tick


## Money returned if this is sold right now.
func refund_value() -> int:
	if type == null:
		return 0
	return maxi(0, int(floor(float(paid_cost) * clampf(type.refund_ratio, 0.0, 1.0))))
