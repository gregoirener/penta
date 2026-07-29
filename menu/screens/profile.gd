extends Control
class_name ProfileScreen
## Account screen — real numbers, derived from the library and the daemon.
##
## No fake trophy counts or invented levels. Everything here is something the
## console actually knows: what you own, what you've played, and what the
## hardware is doing.

signal closed()

const MARGIN := Vector2(160, 150)

var _open := false
var _titles: Array = []

var _avatar: Panel
var _name_label: Label
var _sub_label: Label
var _stat_labels: Array[Label] = []
var _stat_values: Array[Label] = []
var _recent_cards: Array[GameCard] = []
var _recent_row: Control

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_build_header()
	_build_stats()

	_recent_row = Control.new()
	_recent_row.position = Vector2(MARGIN.x, 646)
	_recent_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_recent_row)

	var recent_title := Tokens.label("Recently played", Tokens.T_BODY, Tokens.TEXT_MUTED)
	recent_title.position = Vector2(MARGIN.x, 592)
	add_child(recent_title)

	var hint := Tokens.label("Circle  Back", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	hint.position = Vector2(MARGIN.x, 1080 - 46)
	add_child(hint)

func _build_header() -> void:
	# Generated avatar rather than a placeholder image: a flat accent tile with
	# the account initial. Deterministic, never missing, never a broken image.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Tokens.ACCENT.darkened(0.25)
	sb.set_corner_radius_all(12)

	_avatar = Panel.new()
	_avatar.add_theme_stylebox_override("panel", sb)
	_avatar.position = Vector2(MARGIN.x, 96)
	_avatar.size = Vector2(120, 120)
	_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_avatar)

	var initial := Tokens.label("", Tokens.T_TITLE)
	initial.name = "Initial"
	initial.size = Vector2(120, 120)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_avatar.add_child(initial)

	_name_label = Tokens.label("", Tokens.T_TITLE)
	_name_label.position = Vector2(MARGIN.x + 152, 112)
	add_child(_name_label)

	_sub_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_sub_label.position = Vector2(MARGIN.x + 152, 172)
	add_child(_sub_label)

func _build_stats() -> void:
	var labels := ["Titles", "Total played", "Most played", "Storage", "Controller", "System"]
	for i in labels.size():
		var y := 290.0 + i * 46.0
		var l := Tokens.label(labels[i], Tokens.T_BODY, Tokens.TEXT_DIM)
		l.position = Vector2(MARGIN.x, y)
		add_child(l)
		_stat_labels.append(l)

		var v := Tokens.label("…", Tokens.T_BODY, Tokens.TEXT)
		v.position = Vector2(MARGIN.x + 340, y)
		v.size = Vector2(1200, 36)
		add_child(v)
		_stat_values.append(v)

func is_open() -> bool:
	return _open

func open(titles: Array) -> void:
	if _open:
		return
	_open = true
	_titles = titles
	visible = true
	Router.set_consumed(true)
	_refresh()

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

func _refresh() -> void:
	var user := OS.get_environment("USER")
	if user.is_empty():
		user = "player"
	_name_label.text = user.capitalize()
	(_avatar.get_node("Initial") as Label).text = user.substr(0, 1).to_upper()

	# --- Aggregates over the real library ---
	var total_s := 0
	var most: Dictionary = {}
	var played := 0
	for t in _titles:
		var secs := int(t.get("playtime_s", 0))
		total_s += secs
		if secs > 0:
			played += 1
		if most.is_empty() or secs > int(most.get("playtime_s", 0)):
			most = t

	_sub_label.text = "%d titles  ·  %d played" % [_titles.size(), played]
	_stat_values[0].text = str(_titles.size())
	_stat_values[1].text = _hours(total_s)
	_stat_values[2].text = "%s  (%s)" % [
		str(most.get("name", "—")), _hours(int(most.get("playtime_s", 0)))] \
		if not most.is_empty() else "—"

	Ipc.request("storage.usage", {}, func(ok: bool, p: Variant) -> void:
		if ok and _open:
			var d: Dictionary = p
			_stat_values[3].text = "%.0f GB free of %.0f GB" % [
				float(d.get("free_gb", 0)), float(d.get("total_gb", 0))])

	Ipc.request("system.status", {}, func(ok: bool, p: Variant) -> void:
		if not (ok and _open):
			return
		var d: Dictionary = p
		var c: Dictionary = d.get("controllers", {})
		var b: Variant = c.get("battery")
		var txt := "%d connected" % int(c.get("count", 0))
		if b != null:
			txt += "  ·  %d%%" % int((b as Dictionary).get("pct", 0))
		_stat_values[4].text = txt
		_stat_values[5].text = "PENTA  ·  %s" % (
			"mock" if d.get("mock", false) else "console"))

	_build_recent()

func _hours(seconds: int) -> String:
	if seconds <= 0:
		return "—"
	var h := seconds / 3600
	if h < 1:
		return "%d min" % (seconds / 60)
	return "%d hours" % h

func _build_recent() -> void:
	for c in _recent_cards:
		c.queue_free()
	_recent_cards.clear()

	var recent := []
	for t in _titles:
		if t.get("last_played") != null:
			recent.append(t)
	recent.sort_custom(func(a, b): return float(a["last_played"]) > float(b["last_played"]))

	var x := 0.0
	for t in recent.slice(0, 6):
		var card := GameCard.new()
		_recent_row.add_child(card)
		card.setup(t)
		card.scale = Vector2.ONE * 0.62
		card.position = Vector2(x, 0)
		card.modulate.a = 0.9
		_recent_cards.append(card)
		x += GameCard.SIZE.x * 0.62 + 20

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_east") or event.is_action_pressed("penta_south"):
		close()
		get_viewport().set_input_as_handled()
