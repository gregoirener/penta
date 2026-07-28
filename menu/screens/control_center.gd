extends Control
class_name ControlCenter
## The PS-button overlay.
##
## Slides up over whatever is running, blurred backdrop, never kills the title.
## This is the single feature that separates a console from a launcher: the
## daemon owns the PS button at the evdev layer, so this appears *during* a
## fullscreen game, and dismissing it returns you exactly where you were.
##
## Deliberately a strip, not a screen. A full-screen menu would break the
## illusion that the game is still there underneath — which it is.

signal dismissed()
signal power_requested()

const STRIP_H := 220.0
const TILE := Vector2(150, 132)
const TILE_GAP := 18.0

enum Tile { SOUND, CONTROLLERS, NETWORK, STORAGE, CLOSE_GAME, POWER }

const TILES := [
	{"id": Tile.SOUND,       "label": "Sound"},
	{"id": Tile.CONTROLLERS, "label": "Controllers"},
	{"id": Tile.NETWORK,     "label": "Network"},
	{"id": Tile.STORAGE,     "label": "Storage"},
	{"id": Tile.CLOSE_GAME,  "label": "Close Game"},
	{"id": Tile.POWER,       "label": "Power"},
]

var _scrim: ColorRect
var _strip: Control
var _tiles: Array[Panel] = []
var _labels: Array[Label] = []
var _detail: Label
var _index := 0
var _open := false
var _game_running := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_build_scrim()
	_build_strip()
	_build_tiles()

func _build_scrim() -> void:
	# Darkens and desaturates what's behind rather than hiding it. The game
	# staying visible is the whole point.
	_scrim = ColorRect.new()
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.55)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

func _build_strip() -> void:
	# Plain position/size, no anchor preset: the strip is animated by moving
	# position.y, and non-equal opposite anchors would fight that after _ready.
	_strip = Control.new()
	_strip.size = Vector2(1920, STRIP_H)
	_strip.position = Vector2(0, 1080 - STRIP_H)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_strip)

	var bg := ColorRect.new()
	bg.size = Vector2(1920, STRIP_H)
	bg.color = Color(Tokens.SURFACE, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.add_child(bg)

	_detail = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_MUTED)
	_detail.position = Vector2(Tokens.S6, STRIP_H - 38)
	_strip.add_child(_detail)

func _build_tiles() -> void:
	var x := Tokens.S6
	for spec in TILES:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Tokens.SURFACE_HIGH
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(2)
		sb.border_color = Color(0, 0, 0, 0)

		var tile := Panel.new()
		tile.add_theme_stylebox_override("panel", sb)
		tile.position = Vector2(x, 28)
		tile.size = TILE
		tile.pivot_offset = TILE * 0.5
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_strip.add_child(tile)

		var l := Tokens.label(str(spec["label"]), Tokens.T_CAPTION, Tokens.TEXT_MUTED)
		l.position = Vector2(0, TILE.y - 40)
		l.size = Vector2(TILE.x, 30)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tile.add_child(l)

		_tiles.append(tile)
		_labels.append(l)
		x += TILE.x + TILE_GAP

# --- Open / close -------------------------------------------------------------

func is_open() -> bool:
	return _open

func open(game_running: bool) -> void:
	if _open:
		return
	_open = true
	_game_running = game_running
	_index = 0
	visible = true
	Router.set_consumed(true)

	_scrim.modulate.a = 0.0
	_strip.position.y = 1080.0

	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_scrim, "modulate:a", 1.0, Tokens.dur(Tokens.D_FAST))
	t.tween_property(_strip, "position:y", 1080.0 - STRIP_H, Tokens.dur(Tokens.D_NORMAL))

	_apply_focus(true)
	Ipc.request("system.status", {}, _on_status)

func close() -> void:
	if not _open:
		return
	_open = false

	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_scrim, "modulate:a", 0.0, Tokens.dur(Tokens.D_FAST))
	t.tween_property(_strip, "position:y", 1080.0, Tokens.dur(Tokens.D_FAST))
	await t.finished

	visible = false
	Router.set_consumed(false)
	dismissed.emit()

# --- Input --------------------------------------------------------------------
# Router is "consumed" while we're open, so we read input directly rather than
# through its signals — that keeps the underlying screen completely inert.

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_ps") or event.is_action_pressed("penta_east"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("penta_right"):
		_move(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("penta_left"):
		_move(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("penta_south"):
		_activate()
		get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	var next := clampi(_index + delta, 0, _tiles.size() - 1)
	if next == _index:
		return
	_index = next
	_apply_focus(false)

func _apply_focus(instant: bool) -> void:
	for i in _tiles.size():
		var focused := i == _index
		var sb: StyleBoxFlat = _tiles[i].get_theme_stylebox("panel")
		sb.border_color = Tokens.TEXT if focused else Color(0, 0, 0, 0)
		sb.bg_color = Tokens.SURFACE_HIGH.lightened(0.10 if focused else 0.0)
		_labels[i].add_theme_color_override(
			"font_color", Tokens.TEXT if focused else Tokens.TEXT_MUTED)
		var target := Vector2.ONE * (1.06 if focused else 1.0)
		if instant:
			_tiles[i].scale = target
		else:
			var t := Tokens.tween(_tiles[i])
			t.tween_property(_tiles[i], "scale", target, Tokens.dur(Tokens.D_FOCUS))
	_update_detail()

func _update_detail() -> void:
	match TILES[_index]["id"]:
		Tile.CLOSE_GAME:
			_detail.text = "Close the running title" if _game_running \
				else "Nothing is running"
		Tile.POWER:
			_detail.text = "Rest Mode, Restart, Power Off"
		_:
			_detail.text = str(TILES[_index]["label"])

func _activate() -> void:
	match TILES[_index]["id"]:
		Tile.POWER:
			power_requested.emit()
		Tile.CLOSE_GAME:
			if _game_running:
				Ipc.request("title.close", {}, func(_ok, _p): close())
		Tile.CONTROLLERS:
			Ipc.request("controller.rescan", {}, _on_controllers)
		Tile.STORAGE:
			Ipc.request("storage.usage", {}, _on_storage)
		_:
			_detail.text = "%s — not wired up yet" % str(TILES[_index]["label"])

# --- Live data ----------------------------------------------------------------

func _on_status(ok: bool, payload: Variant) -> void:
	if not ok or not _open:
		return
	var d: Dictionary = payload
	_game_running = d.get("running_uid") != null
	_update_detail()

func _on_controllers(ok: bool, payload: Variant) -> void:
	if not ok:
		_detail.text = "Controller scan failed"
		return
	var d: Dictionary = payload
	var battery: Variant = d.get("battery")
	if battery == null:
		_detail.text = "%d controller(s)" % int(d.get("count", 0))
	else:
		_detail.text = "%d controller(s) · %d%%%s" % [
			int(d.get("count", 0)),
			int((battery as Dictionary).get("pct", 0)),
			" charging" if (battery as Dictionary).get("charging", false) else ""]

func _on_storage(ok: bool, payload: Variant) -> void:
	if not ok:
		_detail.text = "Storage unavailable"
		return
	var d: Dictionary = payload
	var by: Dictionary = d.get("by_category", {})
	_detail.text = "%.0f GB free of %.0f GB   ·   Games %.0f GB" % [
		float(d.get("free_gb", 0)), float(d.get("total_gb", 0)),
		float(by.get("games", 0))]
