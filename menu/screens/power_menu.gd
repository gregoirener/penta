extends Control
class_name PowerMenu
## Rest Mode / Restart / Power Off.
##
## Every entry here is irreversible from the user's point of view, so each one
## confirms. Rest Mode is default-focused because it is the one you want 95% of
## the time and the only one that is genuinely cheap to get wrong.

signal dismissed()

const PANEL := Vector2(560, 420)

const ENTRIES := [
	{"cmd": "power.rest",    "label": "Rest Mode",
	 "hint": "Suspends now, hibernates later. Resumes into the same game."},
	{"cmd": "power.restart", "label": "Restart",
	 "hint": "Closes everything and reboots."},
	{"cmd": "power.off",     "label": "Power Off",
	 "hint": "Closes everything and shuts down."},
]

var _scrim: ColorRect
var _panel: Panel
var _rows: Array[Label] = []
var _hint: Label
var _index := 0
var _open := false
var _confirming := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build()

func _build() -> void:
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.72)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Tokens.SURFACE
	sb.set_corner_radius_all(14)
	sb.shadow_size = int(Tokens.ELEV[3]["spread"])
	sb.shadow_color = Color(0, 0, 0, Tokens.ELEV[3]["alpha"])

	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.size = PANEL
	_panel.position = (Vector2(1920, 1080) - PANEL) * 0.5
	_panel.pivot_offset = PANEL * 0.5
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var title := Tokens.label("Power", Tokens.T_TITLE)
	title.position = Vector2(Tokens.S4, Tokens.S4)
	_panel.add_child(title)

	var y := 140.0
	for e in ENTRIES:
		var l := Tokens.label(str(e["label"]), Tokens.T_LABEL, Tokens.TEXT_MUTED)
		l.position = Vector2(Tokens.S4, y)
		l.size = Vector2(PANEL.x - Tokens.S4 * 2, 44)
		_panel.add_child(l)
		_rows.append(l)
		y += 62

	_hint = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_hint.position = Vector2(Tokens.S4, PANEL.y - 76)
	_hint.size = Vector2(PANEL.x - Tokens.S4 * 2, 60)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_hint)

func open() -> void:
	if _open:
		return
	_open = true
	_confirming = false
	_index = 0
	visible = true
	Router.set_consumed(true)

	_scrim.modulate.a = 0.0
	_panel.scale = Vector2.ONE * 0.94

	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_scrim, "modulate:a", 1.0, Tokens.dur(Tokens.D_FAST))
	t.tween_property(_panel, "scale", Vector2.ONE, Tokens.dur(Tokens.D_NORMAL))
	_apply_focus()

func close() -> void:
	if not _open:
		return
	_open = false
	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_scrim, "modulate:a", 0.0, Tokens.dur(Tokens.D_FAST))
	t.tween_property(_panel, "scale", Vector2.ONE * 0.96, Tokens.dur(Tokens.D_FAST))
	await t.finished
	visible = false
	Router.set_consumed(false)
	dismissed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_east"):
		if _confirming:
			_confirming = false
			_apply_focus()
		else:
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
	if _confirming:
		return
	_index = clampi(_index + delta, 0, _rows.size() - 1)
	_apply_focus()

func _apply_focus() -> void:
	for i in _rows.size():
		var focused := i == _index
		_rows[i].add_theme_color_override(
			"font_color", Tokens.TEXT if focused else Tokens.TEXT_MUTED)
		_rows[i].text = ("›  " if focused else "    ") + str(ENTRIES[i]["label"])
	_hint.text = "Press Cross again to confirm" if _confirming \
		else str(ENTRIES[_index]["hint"])
	_hint.add_theme_color_override(
		"font_color", Tokens.DANGER if _confirming else Tokens.TEXT_DIM)

func _activate() -> void:
	# Two presses, always. A mis-flicked stick should never power off a console
	# mid-game, and there is no undo for any entry here.
	if not _confirming:
		_confirming = true
		_apply_focus()
		return

	var cmd := str(ENTRIES[_index]["cmd"])
	_hint.text = "…"
	Ipc.request(cmd, {}, func(ok: bool, payload: Variant) -> void:
		if not ok:
			_confirming = false
			_hint.text = "Failed: %s" % str(payload)
			_hint.add_theme_color_override("font_color", Tokens.DANGER)
	)
