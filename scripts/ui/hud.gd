extends Control

## Balance, income rate and the mode buttons.
##
## Reads [GridSim] signals and calls back into [GridSim]. It never touches a
## machine node - it has no idea those exist.
##
## Every path below is optional. Wire up only the nodes you have built; the rest
## are skipped silently.

@export_group("Labels")

## Label showing the current balance.
@export var money_label_path: NodePath

## Label showing income per tick.
@export var income_label_path: NodePath

## Label showing the machine count.
@export var machine_count_label_path: NodePath

## Label used for transient messages ("Not enough money").
@export var status_label_path: NodePath

@export_group("Buttons")

## Toggle button that switches sell mode on and off.
@export var sell_button_path: NodePath

## Button that turns the pending machine 90 degrees.
@export var rotate_button_path: NodePath

## Button that clears the current selection.
@export var cancel_button_path: NodePath

@export_group("Text")
@export var income_suffix: String = " / tick"
@export var machine_count_format: String = "%d machines"

## How long a rejection message stays on screen.
@export var status_seconds: float = 1.6


@onready var _money_label: Label = get_node_or_null(money_label_path) as Label
@onready var _income_label: Label = get_node_or_null(income_label_path) as Label
@onready var _machine_count_label: Label = get_node_or_null(machine_count_label_path) as Label
@onready var _status_label: Label = get_node_or_null(status_label_path) as Label
@onready var _sell_button: BaseButton = get_node_or_null(sell_button_path) as BaseButton
@onready var _rotate_button: BaseButton = get_node_or_null(rotate_button_path) as BaseButton
@onready var _cancel_button: BaseButton = get_node_or_null(cancel_button_path) as BaseButton

var _status_clear_at: float = 0.0


func _ready() -> void:
	GridSim.money_changed.connect(_on_money_changed)
	GridSim.machine_placed.connect(_on_machine_placed)
	GridSim.machine_removed.connect(_on_machine_removed)
	GridSim.mode_changed.connect(_on_mode_changed)
	GridSim.placement_rejected.connect(_on_placement_rejected)

	if _sell_button != null:
		_sell_button.toggle_mode = true
		_sell_button.toggled.connect(_on_sell_toggled)
	if _rotate_button != null:
		_rotate_button.pressed.connect(_on_rotate_pressed)
	if _cancel_button != null:
		_cancel_button.pressed.connect(_on_cancel_pressed)

	if _status_label != null:
		_status_label.text = ""

	# GridSim is an autoload and finished its _ready() before this node existed,
	# so the opening balance never arrives as a signal. Pull it instead.
	_refresh_all()


func _process(_delta: float) -> void:
	if _status_clear_at <= 0.0:
		return
	if float(Time.get_ticks_msec()) / 1000.0 < _status_clear_at:
		return
	_status_clear_at = 0.0
	if _status_label != null:
		_status_label.text = ""


func _refresh_all() -> void:
	_refresh_money()
	_refresh_income()
	_refresh_mode()


func _refresh_money() -> void:
	if _money_label != null:
		_money_label.text = UiFormat.money(GridSim.money)


func _refresh_income() -> void:
	if _income_label != null:
		_income_label.text = UiFormat.money(GridSim.total_income_per_tick()) + income_suffix
	if _machine_count_label != null:
		_machine_count_label.text = machine_count_format % GridSim.machine_count()


func _refresh_mode() -> void:
	if _sell_button != null:
		_sell_button.set_pressed_no_signal(GridSim.get_mode() == GridSim.Mode.SELL)


func _on_money_changed(_total: int, _delta: int) -> void:
	_refresh_money()


func _on_machine_placed(_machine: PlacedMachine) -> void:
	_refresh_income()


func _on_machine_removed(_machine: PlacedMachine, _refund: int) -> void:
	_refresh_income()


func _on_mode_changed(_mode: int) -> void:
	_refresh_mode()


func _on_placement_rejected(_cell: Vector2i, reason: int) -> void:
	_show_status(GridSim.placement_result_text(reason))


func _on_sell_toggled(pressed: bool) -> void:
	GridSim.set_mode(GridSim.Mode.SELL if pressed else GridSim.Mode.NONE)


func _on_rotate_pressed() -> void:
	GridSim.rotate_selection(1)


func _on_cancel_pressed() -> void:
	GridSim.clear_selection()


func _show_status(text: String) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_clear_at = float(Time.get_ticks_msec()) / 1000.0 + maxf(0.1, status_seconds)
