extends Node
## The single place gamepad input becomes menu intent.
##
## Autoloaded as `Router`. Every screen listens to these signals and never
## touches raw Input — which is what makes the Cross/Circle swap a one-line
## change instead of forty call sites, and gives us one place to fire the
## navigation click + haptic tick.

signal nav(dir: Vector2i)          # (0,-1) up, (1,0) right, ...
signal confirm()
signal back()
signal options()
signal shoulder(dir: int)          # -1 = L1, +1 = R1
signal ps_button()                 # local fallback; the real one comes from pentad

# --- Repeat ramp --------------------------------------------------------------
# Hold a direction: one immediate step, a pause, then accelerating repeats.
# These three numbers are most of what "good menu feel" actually is.
const REPEAT_DELAY  := 0.40        # before the first repeat
const REPEAT_FAST   := 0.09        # steady-state repeat interval
const REPEAT_RAMP   := 0.55        # how quickly it accelerates toward FAST
const STICK_DEADZONE := 0.55       # high: menus should need a deliberate flick

## Swap Cross/Circle. Japan ships the opposite convention; so does half of
## everyone's muscle memory.
var confirm_is_south := true

var _held := Vector2i.ZERO
var _repeat_timer := 0.0
var _repeat_interval := REPEAT_DELAY
var _consumed := false             # true while a modal owns input

func _ready() -> void:
	_build_input_map()
	set_process(true)
	set_process_unhandled_input(true)

## Screens push/pop this when a modal takes over.
func set_consumed(v: bool) -> void:
	_consumed = v
	if v:
		_held = Vector2i.ZERO

func _build_input_map() -> void:
	# Built in code rather than stored in project.godot: readable, diffable,
	# and it can't drift out of sync with this file.
	_action("penta_up",    [KEY_UP],    [JOY_BUTTON_DPAD_UP])
	_action("penta_down",  [KEY_DOWN],  [JOY_BUTTON_DPAD_DOWN])
	_action("penta_left",  [KEY_LEFT],  [JOY_BUTTON_DPAD_LEFT])
	_action("penta_right", [KEY_RIGHT], [JOY_BUTTON_DPAD_RIGHT])
	_action("penta_south", [KEY_ENTER], [JOY_BUTTON_A])
	_action("penta_east",  [KEY_ESCAPE],[JOY_BUTTON_B])
	_action("penta_north", [KEY_TAB],   [JOY_BUTTON_Y])
	_action("penta_l1",    [KEY_Q],     [JOY_BUTTON_LEFT_SHOULDER])
	_action("penta_r1",    [KEY_E],     [JOY_BUTTON_RIGHT_SHOULDER])
	_action("penta_ps",    [KEY_HOME],  [JOY_BUTTON_GUIDE])

func _action(name: String, keys: Array, buttons: Array) -> void:
	if InputMap.has_action(name):
		InputMap.erase_action(name)
	InputMap.add_action(name, 0.5)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(name, e)
	for b in buttons:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(name, e)

func _unhandled_input(event: InputEvent) -> void:
	if _consumed:
		return
	if event.is_action_pressed("penta_ps"):
		ps_button.emit()
	elif event.is_action_pressed("penta_south"):
		_emit_confirm_or_back(true)
	elif event.is_action_pressed("penta_east"):
		_emit_confirm_or_back(false)
	elif event.is_action_pressed("penta_north"):
		options.emit()
	elif event.is_action_pressed("penta_l1"):
		shoulder.emit(-1)
	elif event.is_action_pressed("penta_r1"):
		shoulder.emit(1)

func _emit_confirm_or_back(is_south: bool) -> void:
	if is_south == confirm_is_south:
		confirm.emit()
	else:
		back.emit()

func _process(delta: float) -> void:
	if _consumed:
		return

	var dir := _read_direction()

	if dir == Vector2i.ZERO:
		_held = Vector2i.ZERO
		_repeat_interval = REPEAT_DELAY
		return

	if dir != _held:
		# New direction: fire immediately, then wait the long delay.
		_held = dir
		_repeat_timer = REPEAT_DELAY
		_repeat_interval = REPEAT_DELAY
		nav.emit(dir)
		return

	_repeat_timer -= delta
	if _repeat_timer <= 0.0:
		# Accelerate toward the fast interval instead of snapping to it —
		# a constant repeat rate feels mechanical, a ramp feels responsive.
		_repeat_interval = lerp(_repeat_interval, REPEAT_FAST, REPEAT_RAMP)
		_repeat_timer = _repeat_interval
		nav.emit(dir)

func _read_direction() -> Vector2i:
	var d := Vector2i.ZERO
	if Input.is_action_pressed("penta_left"):  d.x -= 1
	if Input.is_action_pressed("penta_right"): d.x += 1
	if Input.is_action_pressed("penta_up"):    d.y -= 1
	if Input.is_action_pressed("penta_down"):  d.y += 1

	if d == Vector2i.ZERO:
		var stick := Vector2(
			Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
			Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
		if stick.length() > STICK_DEADZONE:
			# Cardinal only: diagonals in a grid menu are almost never intended.
			if absf(stick.x) > absf(stick.y):
				d.x = int(signf(stick.x))
			else:
				d.y = int(signf(stick.y))
	return d
