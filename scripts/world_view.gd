extends Node3D

## Spawns and frees the 3D representation of every machine in [GridSim].
##
## Attach to World. It listens to [GridSim] and reparents nothing else - the
## children of World/Machines exist only because this script put them there, so
## do not hand-author anything under that node.

## Container the machine nodes are parented to. Relative to this node.
@export var machines_root_path: NodePath = ^"Machines"

## Used when a [MachineType] has no scene of its own. Optional - a plain box is
## generated when this is empty too, so the game is playable before any art
## exists.
@export var fallback_machine_scene: PackedScene

## Extra height applied to every spawned machine, in world units.
@export var machine_y_offset: float = 0.0

@export_group("Placeholder box")
@export var placeholder_height: float = 0.6
@export_range(0.1, 1.0, 0.01) var placeholder_inset: float = 0.9
@export var placeholder_color: Color = Color(0.55, 0.62, 0.72)


@onready var _machines_root: Node3D = get_node_or_null(machines_root_path) as Node3D

## int machine id -> Node3D.
var _nodes: Dictionary = {}


func _ready() -> void:
	if _machines_root == null:
		push_error("world_view.gd: no Node3D at '%s'. Add a Node3D named 'Machines' under World, or repoint machines_root_path." % [machines_root_path])
		return

	GridSim.machine_placed.connect(_on_machine_placed)
	GridSim.machine_removed.connect(_on_machine_removed)

	# GridSim is an autoload, so it is ready before this node is. Anything it
	# already holds was placed before we could hear about it.
	_rebuild()


func _rebuild() -> void:
	for id: int in _nodes.keys():
		var node: Node3D = _nodes[id] as Node3D
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	for machine: PlacedMachine in GridSim.get_machines():
		_spawn(machine)


func _on_machine_placed(machine: PlacedMachine) -> void:
	_spawn(machine)


func _on_machine_removed(machine: PlacedMachine, _refund: int) -> void:
	if machine == null:
		return
	var node: Node3D = _nodes.get(machine.id, null) as Node3D
	_nodes.erase(machine.id)
	if is_instance_valid(node):
		node.queue_free()


func _spawn(machine: PlacedMachine) -> void:
	if machine == null or _machines_root == null:
		return
	if _nodes.has(machine.id):
		return

	var node: Node3D = _instantiate_visual(machine)
	if node == null:
		return

	node.name = "Machine_%d" % machine.id
	_machines_root.add_child(node)

	var size: Vector2i = machine.footprint_size()
	node.position = GridUtil.footprint_center(machine.origin, size) + Vector3(0.0, machine_y_offset, 0.0)
	node.rotation = Vector3(0.0, GridUtil.rotation_radians(machine.rotation_steps), 0.0)

	_nodes[machine.id] = node


func _instantiate_visual(machine: PlacedMachine) -> Node3D:
	var scene: PackedScene = null
	if machine.type != null:
		scene = machine.type.scene
	if scene == null:
		scene = fallback_machine_scene

	if scene != null:
		var instance: Node = scene.instantiate()
		var node: Node3D = instance as Node3D
		if node != null:
			return node
		var type_label: String = "?"
		if machine.type != null:
			type_label = machine.type.label()
		push_warning("world_view.gd: the scene for '%s' does not have a Node3D root; using a placeholder." % type_label)
		instance.queue_free()

	return _build_placeholder(machine)


## A simple footprint-sized box, so an untextured machine is still visible and
## still reads at the right size.
func _build_placeholder(machine: PlacedMachine) -> Node3D:
	var root: Node3D = Node3D.new()

	var size: Vector2i = machine.footprint_size()
	var extents: Vector3 = GridUtil.footprint_extents(size)
	var height: float = maxf(0.01, placeholder_height)

	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(
		maxf(0.01, extents.x * placeholder_inset),
		height,
		maxf(0.01, extents.z * placeholder_inset)
	)

	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = placeholder_color
	box.material = material

	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.name = "Placeholder"
	mesh_instance.mesh = box
	# BoxMesh is centred on its origin; lift it so it sits on the ground plane.
	mesh_instance.position = Vector3(0.0, height * 0.5, 0.0)
	root.add_child(mesh_instance)

	return root


## The spawned node for a machine, or null. Handy for future effects; nothing
## outside this script should reach into it.
func node_for(machine: PlacedMachine) -> Node3D:
	if machine == null:
		return null
	return _nodes.get(machine.id, null) as Node3D
