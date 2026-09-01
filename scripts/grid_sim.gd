extends Node

## Autoload singleton "GridSim" - the whole economy, as plain data.
##
## HARD RULE: this script never touches the scene tree. No [method Node.get_node],
## no [MeshInstance3D], no [Camera3D], no [method Node.add_child], and no
## [Vector3] - world-space maths lives in [GridUtil]. It owns money, occupancy
## and the tick loop, and announces every change with a signal. The view layer
## reacts.
##
## If a change here seems to need a node reference, that logic belongs in the
## view layer instead.

## Default heartbeat in seconds. [member tick_seconds] is the live, tunable value.
const TICK_SECONDS: float = 1.0

## Ceiling on ticks resolved in one frame. Without it, returning from a long
## pause (backgrounded app, a breakpoint) would stall on a huge catch-up loop.
## Leftover time beyond this is discarded; real absences are handled by
## [method grant_offline_earnings] instead.
const MAX_CATCHUP_TICKS: int = 8

enum Mode {
	NONE, ## Taps do nothing.
	PLACE, ## Taps place [member selected_type].
	SELL, ## Taps sell whatever is under them.
}

enum PlacementResult {
	OK,
	INVALID_TYPE,
	OUT_OF_BOUNDS,
	OCCUPIED,
	CANT_AFFORD,
}

## Emitted on every balance change. [param delta] is signed.
signal money_changed(total: int, delta: int)

## Emitted once per simulation tick, after income has been credited.
signal ticked(tick_index: int, income: int)

signal machine_placed(machine: PlacedMachine)
signal machine_removed(machine: PlacedMachine, refund: int)

## [param reason] is a [enum PlacementResult]. See [method placement_result_text].
signal placement_rejected(cell: Vector2i, reason: int)

## [param type] is null when the selection was cleared.
signal selection_changed(type: MachineType)

signal rotation_changed(rotation_steps: int)

## [param mode] is a [enum Mode].
signal mode_changed(mode: int)

## Emitted after the machine catalogue has been (re)scanned.
signal catalog_loaded()

signal offline_earnings_granted(amount: int, ticks: int)
signal simulation_running_changed(is_running: bool)


@export_group("Tuning")

## Seconds between ticks. Read fresh each frame, so it is safe to change live.
@export var tick_seconds: float = TICK_SECONDS

## Balance at the start of a fresh run.
@export var starting_money: int = 50

## Cap on how many ticks [method grant_offline_earnings] will ever pay out.
@export var max_offline_ticks: int = 8 * 60 * 60


@export_group("Grid")

## Buildable area, in cells. Cell (0, 0) sits at the world origin, so a rect
## straddling the origin gives a plot centred on it.
@export var grid_bounds: Rect2i = Rect2i(-8, -8, 16, 16)

## When false the plot is unlimited and [member grid_bounds] is ignored.
@export var bounds_enabled: bool = true


@export_group("Data")

## Every MachineType resource in here is discovered at startup.
@export_dir var machine_data_dir: String = "res://data/machines"


var _money: int = 0
var _tick_index: int = 0
var _accumulator: float = 0.0
var _running: bool = true

## int id -> PlacedMachine. The authoritative list. Always tick this one.
var _machines: Dictionary = {}

## Vector2i cell -> PlacedMachine. A multi-cell machine appears under every cell
## it covers, all pointing at the same object, so ticking this would pay a 2x2
## machine four times. It is a lookup index, never an iteration source.
var _occupancy: Dictionary = {}

## StringName id -> MachineType.
var _catalog: Dictionary = {}

## Catalogue in display order.
var _catalog_order: Array[MachineType] = []

## StringName id -> int, for cost_growth.
var _owned_counts: Dictionary = {}

var _next_id: int = 1
var _selected_type: MachineType = null
var _rotation_steps: int = 0
var _mode: int = Mode.NONE


## Current balance. Read-only; use [method add_money] / [method try_spend].
var money: int:
	get:
		return _money

## Ticks elapsed this run.
var tick_index: int:
	get:
		return _tick_index

## Machine kind the player is currently placing, or null.
var selected_type: MachineType:
	get:
		return _selected_type

## Quarter turns applied to the next placement, 0..3.
var rotation_steps: int:
	get:
		return _rotation_steps


func _ready() -> void:
	_money = starting_money
	_load_catalog()


func _process(delta: float) -> void:
	# _process is used only as a clock. No economy maths happens per frame: the
	# accumulator below converts wall time into whole ticks, so the outcome is
	# identical at 60fps, at 120fps and while thermal-throttled.
	if not _running or tick_seconds <= 0.0:
		return
	_accumulator += delta
	var resolved: int = 0
	while _accumulator >= tick_seconds and resolved < MAX_CATCHUP_TICKS:
		_accumulator -= tick_seconds
		resolved += 1
		_run_tick()
	if _accumulator >= tick_seconds:
		_accumulator = fmod(_accumulator, tick_seconds)


func _run_tick() -> void:
	_tick_index += 1
	var income: int = 0
	for machine: PlacedMachine in _machines.values():
		income += machine.income_for_tick(_tick_index)
	if income != 0:
		_add_money(income)
	ticked.emit(_tick_index, income)


# --- Catalogue ---------------------------------------------------------------

## Rescans [member machine_data_dir]. Safe to call again after adding a .tres.
func reload_catalog() -> void:
	_load_catalog()


func _load_catalog() -> void:
	_catalog.clear()
	_catalog_order.clear()

	var dir: DirAccess = DirAccess.open(machine_data_dir)
	if dir == null:
		push_warning("GridSim: no machine data folder at '%s'. The shop will be empty." % machine_data_dir)
		catalog_loaded.emit()
		return

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			_try_load_type(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	_catalog_order.sort_custom(_compare_types)

	if _catalog_order.is_empty():
		push_warning("GridSim: '%s' contains no valid MachineType resources." % machine_data_dir)
	catalog_loaded.emit()


func _try_load_type(file_name: String) -> void:
	var candidate: String = file_name
	# Exported builds may convert text resources to binary and leave a .remap
	# beside the original path.
	if candidate.ends_with(".remap"):
		candidate = candidate.get_basename()
	var extension: String = candidate.get_extension().to_lower()
	if extension != "tres" and extension != "res":
		return

	var path: String = machine_data_dir.path_join(candidate)
	var resource: Resource = ResourceLoader.load(path)
	var type: MachineType = resource as MachineType
	if type == null:
		push_warning("GridSim: '%s' is not a MachineType, skipping." % path)
		return
	if not type.is_valid():
		push_warning("GridSim: '%s' has an empty id or a negative cost, skipping." % path)
		return
	if _catalog.has(type.id):
		push_warning("GridSim: duplicate machine id '%s' in '%s', skipping." % [type.id, path])
		return

	_catalog[type.id] = type
	_catalog_order.append(type)


func _compare_types(a: MachineType, b: MachineType) -> bool:
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	if a.cost != b.cost:
		return a.cost < b.cost
	return a.label().naturalnocasecmp_to(b.label()) < 0


## Every known machine kind, in display order.
func get_catalog() -> Array[MachineType]:
	return _catalog_order.duplicate()


func get_type(id: StringName) -> MachineType:
	return _catalog.get(id, null) as MachineType


func has_type(id: StringName) -> bool:
	return _catalog.has(id)


# --- Money -------------------------------------------------------------------

func add_money(amount: int) -> void:
	_add_money(amount)


## Spends [param amount] if it is affordable. Returns false and changes nothing
## otherwise.
func try_spend(amount: int) -> bool:
	if amount < 0:
		return false
	if _money < amount:
		return false
	_add_money(-amount)
	return true


func can_afford(amount: int) -> bool:
	return _money >= amount


func _add_money(amount: int) -> void:
	if amount == 0:
		return
	_money += amount
	money_changed.emit(_money, amount)


## Price of the next [param type], accounting for how many are already owned.
func current_cost(type: MachineType) -> int:
	if type == null:
		return 0
	return type.cost_for_owned(owned_count(type))


func owned_count(type: MachineType) -> int:
	if type == null:
		return 0
	return int(_owned_counts.get(type.id, 0))


## Long-run income per tick across every placed machine.
func total_income_per_tick() -> int:
	var total: int = 0
	for machine: PlacedMachine in _machines.values():
		total += machine.average_income_per_tick()
	return total


# --- Placement ---------------------------------------------------------------

func is_in_bounds(cell: Vector2i) -> bool:
	if not bounds_enabled:
		return true
	return grid_bounds.has_point(cell)


func machine_at(cell: Vector2i) -> PlacedMachine:
	return _occupancy.get(cell, null) as PlacedMachine


func is_cell_free(cell: Vector2i) -> bool:
	return is_in_bounds(cell) and not _occupancy.has(cell)


## Why a placement would fail, as a [enum PlacementResult]. OK means it would
## succeed right now.
func placement_status(type: MachineType, origin: Vector2i, rotation_steps_in: int = 0) -> int:
	if type == null or not type.is_valid():
		return PlacementResult.INVALID_TYPE
	var size: Vector2i = type.footprint_size(rotation_steps_in)
	for y: int in range(size.y):
		for x: int in range(size.x):
			var cell: Vector2i = origin + Vector2i(x, y)
			if not is_in_bounds(cell):
				return PlacementResult.OUT_OF_BOUNDS
			if _occupancy.has(cell):
				return PlacementResult.OCCUPIED
	if _money < current_cost(type):
		return PlacementResult.CANT_AFFORD
	return PlacementResult.OK


func can_place(type: MachineType, origin: Vector2i, rotation_steps_in: int = 0) -> bool:
	return placement_status(type, origin, rotation_steps_in) == PlacementResult.OK


## Buys and places a machine. Returns the new [PlacedMachine], or null if the
## placement was rejected (in which case [signal placement_rejected] fired and
## no money was spent).
func try_place(type: MachineType, origin: Vector2i, rotation_steps_in: int = 0) -> PlacedMachine:
	var status: int = placement_status(type, origin, rotation_steps_in)
	if status != PlacementResult.OK:
		placement_rejected.emit(origin, status)
		return null

	var price: int = current_cost(type)
	if not try_spend(price):
		# Unreachable while placement_status checks affordability, but placement
		# and payment must never disagree about whether money left the account.
		placement_rejected.emit(origin, PlacementResult.CANT_AFFORD)
		return null

	var machine: PlacedMachine = PlacedMachine.new()
	machine.id = _next_id
	_next_id += 1
	machine.type = type
	machine.origin = origin
	machine.rotation_steps = posmod(rotation_steps_in, 4)
	machine.placed_at_tick = _tick_index
	machine.paid_cost = price

	_machines[machine.id] = machine
	for cell: Vector2i in machine.cells():
		_occupancy[cell] = machine
	_owned_counts[type.id] = owned_count(type) + 1

	machine_placed.emit(machine)
	return machine


## Sells whatever covers [param cell]. Returns false if the cell was empty.
func remove_at(cell: Vector2i) -> bool:
	return remove_machine(machine_at(cell))


func remove_machine(machine: PlacedMachine) -> bool:
	if machine == null or not _machines.has(machine.id):
		return false

	for cell: Vector2i in machine.cells():
		if _occupancy.get(cell, null) == machine:
			_occupancy.erase(cell)
	_machines.erase(machine.id)

	if machine.type != null:
		_owned_counts[machine.type.id] = maxi(0, owned_count(machine.type) - 1)

	var refund: int = machine.refund_value()
	if refund > 0:
		_add_money(refund)
	machine_removed.emit(machine, refund)
	return true


## Every placed machine. Iterate this to tick, never [member _occupancy].
func get_machines() -> Array[PlacedMachine]:
	var result: Array[PlacedMachine] = []
	for machine: PlacedMachine in _machines.values():
		result.append(machine)
	return result


func machine_count() -> int:
	return _machines.size()


# --- Placement intent (what the player is about to do) ------------------------

func select_type(id: StringName) -> void:
	var type: MachineType = get_type(id)
	if type == null:
		push_warning("GridSim: no machine type with id '%s'." % id)
		return
	if _selected_type == type and _mode == Mode.PLACE:
		return
	_selected_type = type
	selection_changed.emit(_selected_type)
	set_mode(Mode.PLACE)


func clear_selection() -> void:
	if _selected_type == null and _mode == Mode.NONE:
		return
	_selected_type = null
	selection_changed.emit(null)
	set_mode(Mode.NONE)


func set_rotation_steps(steps: int) -> void:
	var wrapped: int = posmod(steps, 4)
	if wrapped == _rotation_steps:
		return
	_rotation_steps = wrapped
	rotation_changed.emit(_rotation_steps)


func rotate_selection(delta_steps: int = 1) -> void:
	set_rotation_steps(_rotation_steps + delta_steps)


func get_mode() -> int:
	return _mode


func set_mode(new_mode: int) -> void:
	if new_mode == _mode:
		return
	_mode = new_mode
	if _mode != Mode.PLACE and _selected_type != null:
		_selected_type = null
		selection_changed.emit(null)
	mode_changed.emit(_mode)


func toggle_sell_mode() -> void:
	set_mode(Mode.NONE if _mode == Mode.SELL else Mode.SELL)


# --- Clock control -----------------------------------------------------------

func is_running() -> bool:
	return _running


func set_running(value: bool) -> void:
	if value == _running:
		return
	_running = value
	if _running:
		_accumulator = 0.0
	simulation_running_changed.emit(_running)


## Credits whole ticks' worth of average income for time spent away. Uses the
## long-run rate, so lumpy machines keep their payout phase. Nothing calls this
## yet - it is here for the save/load PR.
func grant_offline_earnings(elapsed_seconds: float) -> int:
	if elapsed_seconds <= 0.0 or tick_seconds <= 0.0:
		return 0
	var ticks: int = mini(int(floor(elapsed_seconds / tick_seconds)), maxi(0, max_offline_ticks))
	if ticks <= 0:
		return 0
	var earned: int = total_income_per_tick() * ticks
	if earned <= 0:
		return 0
	_add_money(earned)
	offline_earnings_granted.emit(earned, ticks)
	return earned


# --- Misc --------------------------------------------------------------------

## Human-readable form of a [enum PlacementResult], for UI feedback.
func placement_result_text(reason: int) -> String:
	match reason:
		PlacementResult.OK:
			return "OK"
		PlacementResult.INVALID_TYPE:
			return "Nothing selected"
		PlacementResult.OUT_OF_BOUNDS:
			return "Outside the plot"
		PlacementResult.OCCUPIED:
			return "Space taken"
		PlacementResult.CANT_AFFORD:
			return "Not enough money"
	return "Cannot place here"


## Wipes every machine and resets the balance. Emits a removal per machine so
## the view layer frees its nodes; no refunds are paid, since the balance is
## being replaced wholesale.
func reset() -> void:
	var existing: Array[PlacedMachine] = get_machines()
	_machines.clear()
	_occupancy.clear()
	_owned_counts.clear()
	_next_id = 1
	_tick_index = 0
	_accumulator = 0.0
	clear_selection()
	set_rotation_steps(0)
	for machine: PlacedMachine in existing:
		machine_removed.emit(machine, 0)
	var delta: int = starting_money - _money
	_money = starting_money
	if delta != 0:
		money_changed.emit(_money, delta)
