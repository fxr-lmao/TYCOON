extends Control

## The buy menu. One entry per MachineType found in res://data/machines/.
##
## Entries are built from the catalogue at runtime, so a new .tres shows up in
## the shop without anyone touching this script. Selecting an entry sets the
## pending machine on [GridSim]; placement.gd hears about it from there, so the
## shop and the placement code never reference each other.

## Container the entries are added to - a VBoxContainer, HBoxContainer or
## GridContainer. Its existing children are left alone.
@export var container_path: NodePath

## Optional styled entry. Its root must be a BaseButton. When it declares the
## scene-unique names below, they are filled in; otherwise the button's own
## text is used.
## [br][br]
## Recognised unique names: %NameLabel, %CostLabel, %OwnedLabel (all Label),
## and %Icon (TextureRect).
@export var entry_scene: PackedScene

@export_group("Plain entry fallback")

## Format for the generated Button when no entry_scene is set.
## Arguments are name, then cost.
@export var entry_text_format: String = "%s\n%s"

@export var entry_min_height: float = 56.0

@export_group("Affordability")

## Grey out entries the player cannot afford yet.
@export var dim_unaffordable: bool = true
@export var unaffordable_modulate: Color = Color(1.0, 1.0, 1.0, 0.45)

## Also make them untappable. Off by default so the player can still line up a
## ghost and see what they are saving towards.
@export var disable_unaffordable: bool = false


@onready var _container: Node = get_node_or_null(container_path)

var _button_group: ButtonGroup = ButtonGroup.new()

## StringName id -> BaseButton.
var _entries: Dictionary = {}


func _ready() -> void:
	if _container == null:
		push_error("shop_panel.gd: no container at '%s'. Point container_path at the box the buttons should go in." % [container_path])
		return

	GridSim.catalog_loaded.connect(_rebuild)
	GridSim.money_changed.connect(_on_money_changed)
	GridSim.machine_placed.connect(_on_machine_placed)
	GridSim.machine_removed.connect(_on_machine_removed)
	GridSim.selection_changed.connect(_on_selection_changed)

	# The catalogue was loaded by the autoload before this node existed, so the
	# signal has already been and gone. Build from what is there now.
	_rebuild()


func _rebuild() -> void:
	if _container == null:
		return
	for button: BaseButton in _entries.values():
		if is_instance_valid(button):
			_container.remove_child(button)
			button.queue_free()
	_entries.clear()

	for type: MachineType in GridSim.get_catalog():
		var button: BaseButton = _make_entry(type)
		_container.add_child(button)
		_entries[type.id] = button

	_refresh_entries()
	_sync_selection(GridSim.selected_type)


func _make_entry(type: MachineType) -> BaseButton:
	var button: BaseButton = null

	if entry_scene != null:
		var instance: Node = entry_scene.instantiate()
		button = instance as BaseButton
		if button == null:
			push_warning("shop_panel.gd: entry_scene root is not a BaseButton; using a plain Button instead.")
			instance.queue_free()

	if button == null:
		var plain: Button = Button.new()
		plain.clip_text = true
		plain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		plain.custom_minimum_size = Vector2(0.0, maxf(0.0, entry_min_height))
		plain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button = plain

	button.name = "Entry_" + String(type.id)
	button.toggle_mode = true
	button.button_group = _button_group
	button.tooltip_text = type.description
	button.pressed.connect(_on_entry_pressed.bind(type.id))
	return button


func _refresh_entries() -> void:
	for type: MachineType in GridSim.get_catalog():
		var button: BaseButton = _entries.get(type.id, null) as BaseButton
		if button == null or not is_instance_valid(button):
			continue
		_apply_entry_state(button, type)


func _apply_entry_state(button: BaseButton, type: MachineType) -> void:
	var cost: int = GridSim.current_cost(type)
	var owned: int = GridSim.owned_count(type)
	var affordable: bool = GridSim.can_afford(cost)

	# Scene-unique names only exist inside an instantiated entry_scene. Looking
	# them up on a Button we built ourselves has no owner to resolve against.
	var name_label: Label = null
	var cost_label: Label = null
	var owned_label: Label = null
	var icon_rect: TextureRect = null
	if entry_scene != null:
		name_label = button.get_node_or_null(^"%NameLabel") as Label
		cost_label = button.get_node_or_null(^"%CostLabel") as Label
		owned_label = button.get_node_or_null(^"%OwnedLabel") as Label
		icon_rect = button.get_node_or_null(^"%Icon") as TextureRect

	var wrote_text: bool = false
	if name_label != null:
		name_label.text = type.label()
		wrote_text = true
	if cost_label != null:
		cost_label.text = UiFormat.money(cost)
		wrote_text = true
	if owned_label != null:
		owned_label.text = str(owned)
		wrote_text = true
	if icon_rect != null and type.icon != null:
		icon_rect.texture = type.icon

	if not wrote_text and button is Button:
		var plain: Button = button as Button
		plain.text = entry_text_format % [type.label(), UiFormat.money(cost)]
		if type.icon != null:
			plain.icon = type.icon

	button.disabled = disable_unaffordable and not affordable
	if dim_unaffordable:
		button.modulate = Color.WHITE if affordable else unaffordable_modulate
	else:
		button.modulate = Color.WHITE


func _sync_selection(type: MachineType) -> void:
	for id: StringName in _entries.keys():
		var button: BaseButton = _entries[id] as BaseButton
		if not is_instance_valid(button):
			continue
		var selected: bool = type != null and type.id == id
		button.set_pressed_no_signal(selected)


func _on_entry_pressed(id: StringName) -> void:
	if GridSim.selected_type != null and GridSim.selected_type.id == id:
		GridSim.clear_selection()
		return
	GridSim.select_type(id)


func _on_money_changed(_total: int, _delta: int) -> void:
	_refresh_entries()


func _on_machine_placed(_machine: PlacedMachine) -> void:
	# cost_growth means the next one of that kind now costs more.
	_refresh_entries()


func _on_machine_removed(_machine: PlacedMachine, _refund: int) -> void:
	_refresh_entries()


func _on_selection_changed(type: MachineType) -> void:
	_sync_selection(type)
