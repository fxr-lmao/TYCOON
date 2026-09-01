class_name GridUtil
extends RefCounted

## Pure static grid <-> world helpers. No state, never instantiated.
##
## Grid coordinates are [Vector2i] on the XZ plane: grid X maps to world X and
## grid Y maps to world Z. Cell (0, 0) is centred on the world origin, so cell
## [code]c[/code] spans [code]c - 0.5[/code] .. [code]c + 0.5[/code] cell units.
##
## This file exists so that [code]grid_sim.gd[/code] never has to mention
## [Vector3]. The simulation stays pure [Vector2i] data, and both view scripts
## share a single source of truth for the conversion.

## Width of one grid cell in world units.
const CELL_SIZE: float = 1.0


## World-space centre of a single cell, on the ground plane (y = 0).
static func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * CELL_SIZE, 0.0, float(cell.y) * CELL_SIZE)


## Cell containing a world-space point. The point's Y is ignored.
static func world_to_cell(world_position: Vector3) -> Vector2i:
	return Vector2i(
		roundi(world_position.x / CELL_SIZE),
		roundi(world_position.z / CELL_SIZE)
	)


## World-space centre of a footprint whose minimum corner is [param origin].
## [param size] must already be rotated (see [method rotate_size]).
static func footprint_center(origin: Vector2i, size: Vector2i) -> Vector3:
	var w: float = float(maxi(1, size.x))
	var h: float = float(maxi(1, size.y))
	return Vector3(
		(float(origin.x) + (w - 1.0) * 0.5) * CELL_SIZE,
		0.0,
		(float(origin.y) + (h - 1.0) * 0.5) * CELL_SIZE
	)


## World-space width/depth of a footprint. Y is always 0.
static func footprint_extents(size: Vector2i) -> Vector3:
	return Vector3(
		float(maxi(1, size.x)) * CELL_SIZE,
		0.0,
		float(maxi(1, size.y)) * CELL_SIZE
	)


## Footprint after [param rotation_steps] quarter turns. Odd steps swap the axes.
static func rotate_size(size: Vector2i, rotation_steps: int) -> Vector2i:
	if posmod(rotation_steps, 2) == 1:
		return Vector2i(size.y, size.x)
	return size


## World Y rotation matching [param rotation_steps] quarter turns.
##
## A +90 degree turn in grid space maps (x, y) -> (-y, x); on the XZ plane that
## is a rotation of -PI/2 about world +Y, hence the negative sign.
static func rotation_radians(rotation_steps: int) -> float:
	return -PI * 0.5 * float(posmod(rotation_steps, 4))


## Minimum corner for a footprint of [param size] centred on [param cell].
## Odd sizes centre exactly; even sizes lean towards the touched cell.
static func centered_origin(cell: Vector2i, size: Vector2i) -> Vector2i:
	var w: int = maxi(1, size.x)
	var h: int = maxi(1, size.y)
	return cell - Vector2i((w - 1) / 2, (h - 1) / 2)
