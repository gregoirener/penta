extends Control
class_name NetworkScreen
## Wi-Fi, with the on-screen keyboard a console has to have.
##
## Without this the machine has no network unless someone plugs in Ethernet,
## which means Steam cannot sign in, no cover art loads and the store is empty.
## It is the difference between a dashboard and a games console.
##
## The keyboard is the awkward part and there is no way around it: a password
## has to be typed, and the only input device is a gamepad.

signal closed()

const MARGIN := Vector2(160, 150)
const ROW_H := 64.0

# 10 wide keeps every key reachable in a few d-pad presses, and matches the
# proportions of the on-screen keyboards people already know.
const ROWS := [
	"1234567890",
	"qwertyuiop",
	"asdfghjkl-",
	"zxcvbnm_.@",
]
const KEY := Vector2(96, 76)
const KEY_GAP := 10.0

enum Phase { LIST, PASSWORD, CONNECTING }

var _networks: Array = []
var _rows: Array[Control] = []
var _index := 0
var _open := false
var _phase: Phase = Phase.LIST

var _password := ""
var _shift := false
var _key_r := 0
var _key_c := 0
var _keys: Array = []            # [row][col] -> Label

var _title: Label
var _status: Label
var _hint: Label
var _pw_label: Label
var _keyboard: Control

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_title = Tokens.label("Network", Tokens.T_TITLE)
	_title.position = Vector2(MARGIN.x, 56)
	add_child(_title)

	_status = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_status.position = Vector2(MARGIN.x, 118)
	_status.size = Vector2(1500, 40)
	add_child(_status)

	_pw_label = Tokens.label("", Tokens.T_LABEL)
	_pw_label.position = Vector2(MARGIN.x, 232)
	_pw_label.visible = false
	add_child(_pw_label)

	_build_keyboard()

	_hint = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_hint.position = Vector2(MARGIN.x, 1080 - 46)
	add_child(_hint)

func _build_keyboard() -> void:
	_keyboard = Control.new()
	_keyboard.position = Vector2(MARGIN.x, 320)
	_keyboard.visible = false
	_keyboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_keyboard)

	for r in ROWS.size():
		var row: Array = []
		for c in ROWS[r].length():
			var sb := StyleBoxFlat.new()
			sb.bg_color = Tokens.SURFACE_HIGH
			sb.set_corner_radius_all(8)
			sb.set_border_width_all(2)
			sb.border_color = Color(0, 0, 0, 0)

			var panel := Panel.new()
			panel.add_theme_stylebox_override("panel", sb)
			panel.position = Vector2(c * (KEY.x + KEY_GAP), r * (KEY.y + KEY_GAP))
			panel.size = KEY
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_keyboard.add_child(panel)

			var l := Tokens.label(ROWS[r][c], Tokens.T_LABEL)
			l.size = KEY
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			panel.add_child(l)
			row.append(panel)
		_keys.append(row)

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_phase = Phase.LIST
	_index = 0
	_password = ""
	Router.set_consumed(true)
	_keyboard.visible = false
	_pw_label.visible = false

	_status.text = "Scanning…"
	_hint.text = "Circle  Back"
	Ipc.request("network.status", {}, _on_status)
	Ipc.request("network.scan", {}, _on_scan)

	modulate.a = 0.0
	var t := Tokens.tween(self)
	t.tween_property(self, "modulate:a", 1.0, Tokens.dur(Tokens.D_FAST))

func close() -> void:
	if not _open:
		return
	_open = false
	var t := Tokens.tween(self)
	t.tween_property(self, "modulate:a", 0.0, Tokens.dur(Tokens.D_FAST))
	await t.finished
	visible = false
	Router.set_consumed(false)
	closed.emit()

# --- Data ---------------------------------------------------------------------

func _on_status(ok: bool, payload: Variant) -> void:
	if not ok or not _open:
		return
	var d: Dictionary = payload
	if not d.get("wifi_available", false):
		_status.text = "No Wi-Fi adapter found. Connect Ethernet instead."
	elif d.get("connected", false):
		_status.text = "Connected to %s   ·   %s" % [
			str(d.get("ssid", "")), str(d.get("ip", ""))]

func _on_scan(ok: bool, payload: Variant) -> void:
	if not _open:
		return
	if not ok:
		_status.text = "Scan failed: %s" % str(payload)
		return
	_networks = (payload as Dictionary).get("networks", [])
	if _networks.is_empty():
		_status.text = "No networks found."
	_build_rows()

func _build_rows() -> void:
	for r in _rows:
		r.queue_free()
	_rows.clear()

	for i in _networks.size():
		var n: Dictionary = _networks[i]
		var row := Control.new()
		row.position = Vector2(MARGIN.x, 200 + i * ROW_H)
		row.size = Vector2(1300, ROW_H - 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)

		var name_l := Tokens.label(str(n.get("ssid", "")), Tokens.T_LABEL, Tokens.TEXT_MUTED)
		row.add_child(name_l)

		# Signal as bars rather than a percentage: it is a relative judgement,
		# not a number anyone acts on precisely.
		var sig := int(n.get("signal", 0))
		var bars := "▂▄▆█".substr(0, clampi(sig / 25 + 1, 1, 4))
		var meta := "%s   %s%s" % [
			bars,
			"secured" if n.get("secure", false) else "open",
			"   ·   saved" if n.get("known", false) else ""]
		var meta_l := Tokens.label(meta, Tokens.T_CAPTION, Tokens.TEXT_DIM)
		meta_l.position = Vector2(760, 8)
		row.add_child(meta_l)

		_rows.append(row)

	_apply_focus()

func _apply_focus() -> void:
	for i in _rows.size():
		var focused: bool = i == _index
		var l: Label = _rows[i].get_child(0)
		l.add_theme_color_override("font_color",
			Tokens.TEXT if focused else Tokens.TEXT_MUTED)
		l.text = ("›  " if focused else "    ") + str(_networks[i].get("ssid", ""))
	if not _networks.is_empty():
		_hint.text = "Cross  Connect      Circle  Back"

# --- Keyboard -----------------------------------------------------------------

func _apply_keys() -> void:
	for r in _keys.size():
		for c in _keys[r].size():
			var focused: bool = (r == _key_r and c == _key_c)
			var panel: Panel = _keys[r][c]
			var sb: StyleBoxFlat = panel.get_theme_stylebox("panel")
			sb.border_color = Tokens.TEXT if focused else Color(0, 0, 0, 0)
			sb.bg_color = Tokens.SURFACE_HIGH.lightened(0.12 if focused else 0.0)
			var l: Label = panel.get_child(0)
			var ch: String = ROWS[r][c]
			l.text = ch.to_upper() if _shift else ch
	# Never render the password itself — someone is always looking at a console.
	_pw_label.text = "Password:  " + "•".repeat(_password.length()) + "_"

func _type_key() -> void:
	var ch: String = ROWS[_key_r][_key_c]
	_password += ch.to_upper() if _shift else ch
	_apply_keys()

# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return

	if _phase == Phase.CONNECTING:
		return                          # nothing to do but wait

	if _phase == Phase.LIST:
		if event.is_action_pressed("penta_east"):
			close()
		elif event.is_action_pressed("penta_down"):
			_move(1)
		elif event.is_action_pressed("penta_up"):
			_move(-1)
		elif event.is_action_pressed("penta_south"):
			_choose()
		else:
			return
		get_viewport().set_input_as_handled()
		return

	# --- password entry ---
	if event.is_action_pressed("penta_east"):
		# Backspace while there is something to delete, otherwise leave.
		if _password.is_empty():
			_phase = Phase.LIST
			_keyboard.visible = false
			_pw_label.visible = false
			_apply_focus()
		else:
			_password = _password.substr(0, _password.length() - 1)
			_apply_keys()
	elif event.is_action_pressed("penta_south"):
		_type_key()
	elif event.is_action_pressed("penta_north"):
		_shift = not _shift
		_apply_keys()
	elif event.is_action_pressed("penta_r1"):
		_connect()
	elif event.is_action_pressed("penta_right"):
		_key_c = (_key_c + 1) % ROWS[_key_r].length()
		_apply_keys()
	elif event.is_action_pressed("penta_left"):
		_key_c = (_key_c - 1 + ROWS[_key_r].length()) % ROWS[_key_r].length()
		_apply_keys()
	elif event.is_action_pressed("penta_down"):
		_key_r = (_key_r + 1) % ROWS.size()
		_key_c = mini(_key_c, ROWS[_key_r].length() - 1)
		_apply_keys()
	elif event.is_action_pressed("penta_up"):
		_key_r = (_key_r - 1 + ROWS.size()) % ROWS.size()
		_key_c = mini(_key_c, ROWS[_key_r].length() - 1)
		_apply_keys()
	else:
		return
	get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	if _networks.is_empty():
		return
	_index = clampi(_index + delta, 0, _networks.size() - 1)
	_apply_focus()

func _choose() -> void:
	if _networks.is_empty():
		return
	var n: Dictionary = _networks[_index]
	# An open network, or one we already have a saved password for, needs no
	# keyboard at all.
	if not n.get("secure", false) or n.get("known", false):
		_connect()
		return
	_phase = Phase.PASSWORD
	_password = ""
	_key_r = 0
	_key_c = 0
	_shift = false
	_keyboard.visible = true
	_pw_label.visible = true
	for r in _rows:
		r.visible = false
	_status.text = "Password for %s" % str(n.get("ssid", ""))
	_hint.text = "Cross  Type      Triangle  Shift      R1  Connect      Circle  Delete"
	_apply_keys()

func _connect() -> void:
	var ssid := str(_networks[_index].get("ssid", ""))
	_phase = Phase.CONNECTING
	_keyboard.visible = false
	_pw_label.visible = false
	_status.text = "Connecting to %s…" % ssid
	_hint.text = ""

	Ipc.request("network.connect", {"ssid": ssid, "password": _password},
		func(ok: bool, payload: Variant) -> void:
			_password = ""              # never keep it around
			if not _open:
				return
			if ok:
				var d: Dictionary = payload
				_status.text = "Connected to %s   ·   %s" % [
					str(d.get("ssid", ssid)), str(d.get("ip", ""))]
				_hint.text = "Circle  Back"
				_phase = Phase.LIST
				for r in _rows:
					r.visible = true
				_apply_focus()
			else:
				_status.text = "Could not connect: %s" % str(payload)
				_hint.text = "Cross  Try again      Circle  Back"
				_phase = Phase.LIST
				for r in _rows:
					r.visible = true
				_apply_focus())
