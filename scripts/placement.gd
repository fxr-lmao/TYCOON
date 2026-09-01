extends Node3D

## Touch -> grid cell, plus the placement ghost.
##
## Attach to World/PlacementGhost. This node moves itself to the cell under the
## player's finger and builds its own preview geometry as children, so the scene
## node itself can stay an empty Node3D at the origin.
##
## What the player is placing lives in [GridSim] (selected type, rotation, mode)
## so the shop UI and this script never have to know about each other.

## Camera used for the raycast. Leave empty to use the viewport's current
## Camera3D, which is usually what you want.
@export var camera_path: NodePath

@export_group("Raycast")

## Physics layers the ground collider is on.
@export_flags_3d_physics var ground_collision_mask: int = 1

@export var ray_length: float = 1000.0

## When the ray hits no collider at all, fall back to intersecting the y = 0
## plane. Keeps placement working even if Ground's collision shape is missing.
@export var fall_back_to_ground_plane: bool = true

@export_group("Tap")

## A touch that travels further than this many pixels is a camera drag, not a tap.
@export var tap_max_drag_pixels: float = 16.0

## A touch held longer than this is not a tap either.
@export var tap_max_seconds: float = 0.7

@export_group("Ghost")

## Show the machine's own scene inside the ghost footprint, if it has one.
@export var show_type_preview: bool = true

@export var ghost_height: float = 0.06
@export_range(0.1, 1.0, 0.01) var ghost_inset: float = 0.96
@export var valid_color: Color = Color(0.35, 0.90, 0.45, 0.45)
@export var invalid_color: Color = Color(0.95, 0.30, 0.30, 0.45)
@export var sell_color: Color = Color(0.98, 0.72, 0.20, 0.45)


var _camera: Camera3D = null
var _ghost: MeshInstance3D = null
var _ghost_mesh: BoxMesh = null
var _ghost_material: StandardMaterial3D = null
var _preview_root: Node3D = null
var _preview_type: MachineType = null

var _cell: Vector2i = Vector2i.ZERO
var _has_cell: bool = false

## How many fingers are currently down. Anything above one is a camera gesture.
var _active_touches: int = 0
var _tap_index: int = -1
var _tap_valid: bool = false
var _tap_start: Vector2 = Vector2.ZERO
var _tap_start_seconds: float = 0.0


func _ready() -> void:
	_build_ghost()

	GridSim.selection_changed.connect(_on_selection_changed)
	GridSim.rotation_changed.connect(_on_intent_changed)
	GridSim.mode_changed.connect(_on_intent_changed)
	GridSim.money_changed.connect(_on_money_changed)
	GridSim.machine_placed.connect(_on_world_changed)
	GridSim.machine_removed.connect(_on_machine_removed)

	_refresh_ghost()


func _resolve_camera() -> Camera3D:
	if is_instance_valid(_camera) and _camera.is_inside_tree():
		return _camera
	if not camera_path.is_empty():
		_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
	return _camera


# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# _unhandled_input, not _input: anything the UI consumed never reaches here,
	# which is what stops a tap on a shop button from also placing a machine.
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_active_touches += 1
		if _active_touches > 1:
			# A second finger means the player is panning or pinching.
			_tap_valid = false
			return
		_tap_index = event.index
		_tap_start = event.position
		_tap_start_seconds = _seconds_now()
		_tap_valid = true
		_update_cell_from_screen(event.position)
		return

	_active_touches = maxi(0, _active_touches - 1)
	if event.index != _tap_index:
		if _active_touches == 0:
			_tap_valid = false
		return

	var was_tap: bool = _tap_valid \
		and _active_touches == 0 \
		and (_seconds_now() - _tap_start_seconds) <= tap_max_seconds
	_tap_index = -1
	if _active_touches == 0:
		_tap_valid = false
	if was_tap:
		_commit(event.position)


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index != _tap_index or _active_touches != 1:
		return
	if _tap_valid and event.position.distance_to(_tap_start) > tap_max_drag_pixels:
		_tap_valid = false
	# Keep the ghost under the finger while panning, so the player can see where
	# a tap would land before committing to it.
	_update_cell_from_screen(event.position)


func _seconds_now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# --- Picking -----------------------------------------------------------------

## Updates the hovered cell from a screen position. Returns false when the ray
## missed the ground entirely.
func _update_cell_from_screen(screen_position: Vector2) -> bool:
	var point: Variant = _ground_point(screen_position)
	if point == null:
		_has_cell = false
		_refresh_ghost()
		return false
	var cell: Vector2i = GridUtil.world_to_cell(point as Vector3)
	if _has_cell and cell == _cell:
		return true
	_cell = cell
	_has_cell = true
	_refresh_ghost()
	return true


## World point on the ground under a screen position, or null.
func _ground_point(screen_position: Vector2) -> Variant:
	var camera: Camera3D = _resolve_camera()
	if camera == null:
		return null

	var from: Vector3 = camera.project_ray_origin(screen_position)
	var direction: Vector3 = camera.project_ray_normal(screen_position)

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			from, from + direction * ray_length
		)
		query.collision_mask = ground_collision_mask
		query.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			return hit["position"] as Vector3

	if fall_back_to_ground_plane:
		var plane: Plane = Plane(Vector3.UP, 0.0)
		return plane.intersects_ray(from, direction)

	return null


# --- Acting ------------------------------------------------------------------

func _commit(screen_position: Vector2) -> void:
	if not _update_cell_from_screen(screen_position):
		return
	var mode: int = GridSim.get_mode()
	if mode == GridSim.Mode.PLACE:
		var type: MachineType = GridSim.selected_type
		if type == null:
			return
		GridSim.try_place(type, _placement_origin(type), GridSim.rotation_steps)
	elif mode == GridSim.Mode.SELL:
		GridSim.remove_at(_cell)


## Minimum corner for the current selection, centred on the hovered cell.
func _placement_origin(type: MachineType) -> Vector2i:
	return GridUtil.centered_origin(_cell, type.footprint_size(GridSim.rotation_steps))


# --- Ghost -------------------------------------------------------------------

func _build_ghost() -> void:
	_ghost_mesh = BoxMesh.new()
	_ghost_mesh.size = Vector3(GridUtil.CELL_SIZE, maxf(0.01, ghost_height), GridUtil.CELL_SIZE)

	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.albedo_color = valid_color
	_ghost_mesh.material = _ghost_material

	_ghost = MeshInstance3D.new()
	_ghost.name = "GhostFootprint"
	_ghost.mesh = _ghost_mesh
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)

	_preview_root = Node3D.new()
	_preview_root.name = "GhostPreview"
	add_child(_preview_root)


func _on_selection_changed(_type: MachineType) -> void:
	_refresh_ghost()


func _on_intent_changed(_value: int) -> void:
	_refresh_ghost()


func _on_money_changed(_total: int, _delta: int) -> void:
	# Affordability is part of what makes a placement valid, so the ghost colour
	# has to follow the balance.
	_refresh_ghost()


func _on_world_changed(_machine: PlacedMachine) -> void:
	_refresh_ghost()


func _on_machine_removed(_machine: PlacedMachine, _refund: int) -> void:
	_refresh_ghost()


func _refresh_ghost() -> void:
	if _ghost == null:
		return

	var mode: int = GridSim.get_mode()
	if not _has_cell or mode == GridSim.Mode.NONE:
		_set_ghost_visible(false)
		return

	if mode == GridSim.Mode.SELL:
		_clear_preview()
		_apply_ghost_footprint(_cell, Vector2i.ONE, 0)
		var target: PlacedMachine = GridSim.machine_at(_cell)
		_ghost_material.albedo_color = sell_color if target != null else invalid_color
		_set_ghost_visible(true)
		return

	var type: MachineType = GridSim.selected_type
	if type == null:
		_set_ghost_visible(false)
		return

	var steps: int = GridSim.rotation_steps
	var size: Vector2i = type.footprint_size(steps)
	var origin: Vector2i = GridUtil.centered_origin(_cell, size)
	_apply_ghost_footprint(origin, size, steps)

	var ok: bool = GridSim.can_place(type, origin, steps)
	_ghost_material.albedo_color = valid_color if ok else invalid_color

	_update_preview(type, steps)
	_set_ghost_visible(true)


func _apply_ghost_footprint(origin: Vector2i, size: Vector2i, steps: int) -> void:
	var extents: Vector3 = GridUtil.footprint_extents(size)
	var height: float = maxf(0.01, ghost_height)
	_ghost_mesh.size = Vector3(
		maxf(0.01, extents.x * ghost_inset),
		height,
		maxf(0.01, extents.z * ghost_inset)
	)
	_ghost.position = Vector3(0.0, height * 0.5, 0.0)

	position = GridUtil.footprint_center(origin, size)
	rotation = Vector3.ZERO
	if _preview_root != null:
		_preview_root.rotation = Vector3(0.0, GridUtil.rotation_radians(steps), 0.0)


func _set_ghost_visible(value: bool) -> void:
	visible = value


func _update_preview(type: MachineType, _steps: int) -> void:
	if not show_type_preview or type == null or type.scene == null:
		_clear_preview()
		return
	if _preview_type == type and _preview_root.get_child_count() > 0:
		return

	_clear_preview()
	var instance: Node = type.scene.instantiate()
	var node: Node3D = instance as Node3D
	if node == null:
		instance.queue_free()
		return
	_preview_root.add_child(node)
	_preview_type = type


func _clear_preview() -> void:
	if _preview_root == null:
		return
	for child: Node in _preview_root.get_children():
		# Detach before freeing: queue_free() leaves the child in the tree until
		# the end of the frame, and a rebuild in the same frame would double up.
		_preview_root.remove_child(child)
		child.queue_free()
	_preview_type = null


## The cell currently under the player's finger, if any.
func hovered_cell() -> Vector2i:
	return _cell


func has_hovered_cell() -> bool:
	return _has_cell
