extends Node3D

## Touch camera: one-finger drag pans, two-finger pinch zooms, two-finger twist
## rotates. Attach to CameraRig.
##
## The rig is an orbit pivot sitting at the point being looked at. The Camera3D
## child is pushed straight back along its local +Z; rig pitch and yaw do the
## rest. On ready the script reads whatever transform you authored and folds it
## into that model, so a camera placed at (0, 8, 10) tilted down by 38 degrees
## comes out looking at very nearly the same thing.
##
## Every gesture has an invert flag. Signs in touch space are easy to get
## backwards and I cannot run this - flip them in the Inspector rather than
## waiting on a code change.

@export var camera_path: NodePath = ^"Camera3D"

## Used only when the Camera3D sits on top of the rig with no offset to read.
@export var default_distance: float = 18.0

@export_group("Pan")

## World units panned per screen height of finger travel, at unit distance.
@export var pan_speed: float = 2.0
@export var invert_pan_x: bool = false
@export var invert_pan_y: bool = false

## Keep the focus point near the buildable plot.
@export var limit_to_grid: bool = true

## How far past the plot edge the focus may wander, in cells.
@export var grid_margin_cells: float = 4.0

@export_group("Zoom")
@export var min_distance: float = 4.0
@export var max_distance: float = 45.0

## Higher is snappier. Zero disables smoothing.
@export var zoom_smoothing: float = 12.0

## Zoom step per mouse wheel notch, for anyone testing with a trackpad.
@export_range(1.0, 2.0, 0.01) var wheel_zoom_factor: float = 1.12

@export_group("Rotate")
@export var allow_twist_rotate: bool = true
@export_range(0.0, 4.0, 0.05) var twist_speed: float = 1.0
@export var invert_rotation: bool = false

## Ignore twists smaller than this, so a sloppy pinch does not also spin the map.
@export_range(0.0, 0.2, 0.001) var twist_deadzone_radians: float = 0.01

@export_group("Pitch")

## Two-finger vertical drag tilts the camera. Off by default: it competes with
## twist for the same gesture and I have not been able to feel it out.
@export var allow_pitch_gesture: bool = false
@export_range(0.0, 2.0, 0.01) var pitch_speed: float = 0.35
@export var invert_pitch: bool = false
@export var min_pitch_degrees: float = -85.0
@export var max_pitch_degrees: float = -12.0


var _camera: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 0.0
var _target_distance: float = 0.0

## touch index -> last known screen position.
var _touches: Dictionary = {}


func _ready() -> void:
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		push_warning("camera_rig.gd: no Camera3D at '%s'. Pan and rotate still work; zoom does nothing." % [camera_path])

	_yaw = rotation.y
	_pitch = rotation.x
	_distance = default_distance

	if _camera != null:
		var offset: float = _camera.position.length()
		if offset > 0.001:
			_distance = offset
		# Fold any tilt authored on the camera itself into the rig, then zero it,
		# so there is exactly one place pitch lives from here on.
		_pitch += _camera.rotation.x
		_camera.rotation = Vector3.ZERO

	_distance = clampf(_distance, min_distance, max_distance)
	_target_distance = _distance
	_pitch = clampf(_pitch, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
	_apply()


func _process(delta: float) -> void:
	if not is_equal_approx(_distance, _target_distance):
		if zoom_smoothing <= 0.0:
			_distance = _target_distance
		else:
			_distance = lerpf(_distance, _target_distance, clampf(zoom_smoothing * delta, 0.0, 1.0))
		_apply()


func _apply() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)
	if _camera != null:
		_camera.position = Vector3(0.0, 0.0, _distance)


# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = touch.position
		else:
			_touches.erase(touch.index)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		_handle_wheel(event as InputEventMouseButton)


func _handle_drag(event: InputEventScreenDrag) -> void:
	var previous: Vector2 = _touches.get(event.index, event.position) as Vector2
	_touches[event.index] = event.position

	if _touches.size() == 1:
		_pan(event.relative)
		return
	if _touches.size() != 2:
		return

	var indices: Array = _touches.keys()
	var other_index: int = int(indices[0])
	if other_index == event.index:
		other_index = int(indices[1])
	var anchor: Vector2 = _touches[other_index] as Vector2

	var before: Vector2 = previous - anchor
	var after: Vector2 = event.position - anchor
	var before_length: float = before.length()
	var after_length: float = after.length()
	if before_length < 1.0 or after_length < 1.0:
		return

	# Fingers spreading apart (after > before) should bring the camera closer.
	_set_target_distance(_target_distance * (before_length / after_length))

	if allow_twist_rotate:
		var twist: float = wrapf(after.angle() - before.angle(), -PI, PI)
		if absf(twist) > twist_deadzone_radians:
			var sign_multiplier: float = -1.0 if invert_rotation else 1.0
			_yaw += twist * twist_speed * sign_multiplier
			_apply()

	if allow_pitch_gesture:
		var vertical: float = (event.position.y - previous.y)
		var pitch_sign: float = -1.0 if invert_pitch else 1.0
		_set_pitch(_pitch + vertical * pitch_speed * 0.01 * pitch_sign)


func _handle_wheel(event: InputEventMouseButton) -> void:
	if not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_set_target_distance(_target_distance / wheel_zoom_factor)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_set_target_distance(_target_distance * wheel_zoom_factor)


# --- Movement ----------------------------------------------------------------

## Drag-to-pan: the ground stays under the finger.
##
## Moving the focus point right pushes content left on screen, so the focus
## moves opposite the finger on X. Moving the focus forward (away from the
## camera) pushes content down, so the focus moves with the finger on Y.
func _pan(relative: Vector2) -> void:
	var viewport_height: float = maxf(1.0, get_viewport().get_visible_rect().size.y)
	var scale: float = pan_speed * _distance / viewport_height

	var yaw_basis: Basis = Basis(Vector3.UP, _yaw)
	var right: Vector3 = yaw_basis.x
	var forward: Vector3 = -yaw_basis.z

	var dx: float = relative.x * (-1.0 if invert_pan_x else 1.0)
	var dy: float = relative.y * (-1.0 if invert_pan_y else 1.0)

	position += (-right * dx + forward * dy) * scale
	_clamp_to_grid()


func _clamp_to_grid() -> void:
	if not limit_to_grid or not GridSim.bounds_enabled:
		return
	var bounds: Rect2i = GridSim.grid_bounds
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return
	var cell: float = GridUtil.CELL_SIZE
	var min_x: float = (float(bounds.position.x) - grid_margin_cells) * cell
	var max_x: float = (float(bounds.end.x - 1) + grid_margin_cells) * cell
	var min_z: float = (float(bounds.position.y) - grid_margin_cells) * cell
	var max_z: float = (float(bounds.end.y - 1) + grid_margin_cells) * cell
	position.x = clampf(position.x, min_x, max_x)
	position.z = clampf(position.z, min_z, max_z)


func _set_target_distance(value: float) -> void:
	_target_distance = clampf(value, min_distance, max_distance)


func _set_pitch(value: float) -> void:
	var clamped: float = clampf(value, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
	if is_equal_approx(clamped, _pitch):
		return
	_pitch = clamped
	_apply()


# --- Public ------------------------------------------------------------------

## Move the focus point to a cell. Useful for a "find my base" button later.
func focus_cell(cell: Vector2i) -> void:
	var target: Vector3 = GridUtil.cell_to_world(cell)
	position = Vector3(target.x, position.y, target.z)
	_clamp_to_grid()


func set_zoom_distance(value: float) -> void:
	_set_target_distance(value)


func get_zoom_distance() -> float:
	return _target_distance
