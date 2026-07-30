extends Control
class_name SettingsScreen
## Settings, driven by real data from pentad.
##
## Deliberately shows facts before it offers switches: on a console you built
## yourself, "what does this machine think is going on" is more useful than a
## toggle. Rows that can act, act; rows that only report, say so.

signal closed()
signal installer_requested()
signal network_requested()

const MARGIN := Vector2(160, 150)
const ROW_H := 74.0

enum Kind { INFO, ACTION }

var _rows: Array = []                 # {label, value, kind, action}
var _labels: Array[Label] = []
var _values: Array[Label] = []
var _index := 0
var _open := false
var _detail: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := Tokens.label("Settings", Tokens.T_TITLE)
	title.position = Vector2(MARGIN.x, 56)
	add_child(title)

	_detail = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_detail.position = Vector2(MARGIN.x, 1080 - 90)
	_detail.size = Vector2(1600, 60)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_detail)

	var hint := Tokens.label("Cross  Select      Circle  Back", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	hint.position = Vector2(MARGIN.x, 1080 - 40)
	add_child(hint)

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	_index = 0
	visible = true
	Router.set_consumed(true)
	_build_rows()
	_refresh_live()

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

func _build_rows() -> void:
	for l in _labels:
		l.queue_free()
	for v in _values:
		v.queue_free()
	_labels.clear()
	_values.clear()

	_rows = [
		{"label": "Storage",          "value": "…", "kind": Kind.INFO,
		 "detail": "Space used by games, captures and the system."},
		{"label": "Network",          "value": "…", "kind": Kind.ACTION,
		 "action": "open.network",
		 "detail": "Connect to Wi-Fi. Without a network Steam cannot sign in and no cover art loads."},
		{"label": "Controllers",      "value": "…", "kind": Kind.ACTION,
		 "action": "controller.rescan",
		 "detail": "Scan for controllers. Pair a DualSense by holding Create + PS."},
		{"label": "Steam",            "value": "…", "kind": Kind.ACTION,
		 "action": "open.steam",
		 "detail": "Open Steam to sign in or install games. Games launch straight from the dashboard — Steam never appears."},
		{"label": "Hardware check",   "value": "…", "kind": Kind.INFO,
		 "detail": "Results of the probe that ran on first boot."},
		{"label": "Refresh library",  "value": "", "kind": Kind.ACTION,
		 "action": "library.refresh",
		 "detail": "Rescan Steam, ROMs and native titles."},
		{"label": "Reduced motion",   "value": "Off", "kind": Kind.ACTION,
		 "action": "toggle.motion",
		 "detail": "Shortens transitions rather than removing them."},
		{"label": "Confirm button",   "value": "Cross", "kind": Kind.ACTION,
		 "action": "toggle.confirm",
		 "detail": "Swap Cross and Circle."},
		{"label": "Install to disk",  "value": "", "kind": Kind.ACTION,
		 "action": "open.installer",
		 "detail": "Copy this console onto an internal drive. Erases the target disk completely."},
		{"label": "System",           "value": "PENTA", "kind": Kind.INFO,
		 "detail": "Original console environment. Arch, gamescope, Godot."},
	]

	for i in _rows.size():
		var y := MARGIN.y + i * ROW_H
		var l := Tokens.label(str(_rows[i]["label"]), Tokens.T_LABEL, Tokens.TEXT_MUTED)
		l.position = Vector2(MARGIN.x, y)
		add_child(l)
		_labels.append(l)

		var v := Tokens.label(str(_rows[i]["value"]), Tokens.T_BODY, Tokens.TEXT_DIM)
		v.position = Vector2(MARGIN.x + 620, y + 8)
		v.size = Vector2(900, 40)
		add_child(v)
		_values.append(v)

	_apply_focus()

func _refresh_live() -> void:
	Ipc.request("storage.usage", {}, func(ok: bool, p: Variant) -> void:
		if not ok or not _open:
			return
		var d: Dictionary = p
		_set_value(0, "%.0f GB free of %.0f GB" % [
			float(d.get("free_gb", 0)), float(d.get("total_gb", 0))]))

	Ipc.request("system.status", {}, func(ok: bool, p: Variant) -> void:
		if not ok or not _open:
			return
		var c: Dictionary = (p as Dictionary).get("controllers", {})
		var b: Variant = c.get("battery")
		var txt := "%d connected" % int(c.get("count", 0))
		if b != null:
			txt += "  ·  %d%%" % int((b as Dictionary).get("pct", 0))
		_set_value(2, txt))

	Ipc.request("network.status", {}, func(ok: bool, p: Variant) -> void:
		if not ok or not _open:
			return
		var d: Dictionary = p
		if d.get("connected", false):
			_set_value(1, "%s  ·  %s" % [str(d.get("ssid", "")), str(d.get("ip", ""))])
		elif not d.get("wifi_available", false):
			_set_value(1, "no adapter")
		else:
			_set_value(1, "not connected"))

	Ipc.request("steam.status", {}, func(ok: bool, p: Variant) -> void:
		if not ok or not _open:
			return
		var d: Dictionary = p
		if not d.get("installed", false):
			_set_value(3, "not installed")
			return
		var libs: Array = d.get("libraries", [])
		_set_value(3, "%d games  ·  %d librar%s" % [
			int(d.get("games", 0)), libs.size(),
			"y" if libs.size() == 1 else "ies"])
		# The detail line carries the paths, which is what you actually need
		# when the count is zero and you expected it not to be.
		if not libs.is_empty() and _index == 3:
			_detail.text = str(libs[0]))

	Ipc.request("system.selftest", {}, func(ok: bool, p: Variant) -> void:
		if not ok or not _open:
			return
		var d: Dictionary = p
		if not d.get("ran", true):
			_set_value(4, "not run yet")
		else:
			_set_value(4, "%d passed, %d failed" % [
				int(d.get("pass", 0)), int(d.get("fail", 0))]))

func _set_value(i: int, text: String) -> void:
	if i < _values.size():
		_values[i].text = text

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_east"):
		close()
	elif event.is_action_pressed("penta_down"):
		_move(1)
	elif event.is_action_pressed("penta_up"):
		_move(-1)
	elif event.is_action_pressed("penta_south"):
		_activate()
	else:
		return
	get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	_index = clampi(_index + delta, 0, _rows.size() - 1)
	_apply_focus()

func _apply_focus() -> void:
	for i in _labels.size():
		var focused := i == _index
		_labels[i].add_theme_color_override(
			"font_color", Tokens.TEXT if focused else Tokens.TEXT_MUTED)
		_labels[i].text = ("›  " if focused else "    ") + str(_rows[i]["label"])
		_values[i].add_theme_color_override(
			"font_color", Tokens.TEXT_MUTED if focused else Tokens.TEXT_DIM)
	_detail.text = str(_rows[_index].get("detail", ""))

func _activate() -> void:
	var row: Dictionary = _rows[_index]
	if row["kind"] != Kind.ACTION:
		return

	match str(row.get("action", "")):
		"toggle.motion":
			Tokens.reduced_motion = not Tokens.reduced_motion
			_set_value(_index, "On" if Tokens.reduced_motion else "Off")
		"toggle.confirm":
			Router.confirm_is_south = not Router.confirm_is_south
			_set_value(_index, "Cross" if Router.confirm_is_south else "Circle")
		"open.network":
			network_requested.emit()
		"open.installer":
			installer_requested.emit()
		"open.steam":
			_detail.text = "Opening Steam…"
			Ipc.request("title.launch", {"uid": "system:steam"},
				func(ok: bool, p: Variant) -> void:
					_detail.text = "Steam opened — install a game, then Refresh library" \
						if ok else "Steam is not installed")
		"controller.rescan":
			_detail.text = "Scanning…"
			Ipc.request("controller.rescan", {}, func(ok: bool, p: Variant) -> void:
				if ok:
					var d: Dictionary = p
					_set_value(2, "%d connected" % int(d.get("count", 0)))
				_detail.text = "Scan complete" if ok else "Scan failed")
		"library.refresh":
			_detail.text = "Rescanning…"
			Ipc.request("library.refresh", {}, func(ok: bool, p: Variant) -> void:
				if ok:
					var n := ((p as Dictionary).get("titles", []) as Array).size()
					_detail.text = "Found %d titles" % n
				else:
					_detail.text = "Rescan failed")
