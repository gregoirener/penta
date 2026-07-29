extends Control
class_name StoreScreen
## Steam's catalogue, rendered in PENTA's design language.
##
## Steam's featured endpoint is public — no key, no account — and returns
## specials, top sellers, new releases and coming soon with names, prices and
## header art. We present that as big cards; buying still happens in Steam,
## because reimplementing payments and account handling would be strictly worse
## than the thing Valve already ships.

signal closed()

const API := "https://store.steampowered.com/api/featuredcategories?cc=us&l=en"
const MARGIN := Vector2(160, 150)
const CARD := Vector2(384, 180)
const GAP := 26.0
const COLS := 4

const SECTIONS := [
	{"key": "specials",     "label": "Specials"},
	{"key": "top_sellers",  "label": "Top Sellers"},
	{"key": "new_releases", "label": "New Releases"},
	{"key": "coming_soon",  "label": "Coming Soon"},
]

var _data: Dictionary = {}
var _items: Array = []
var _cards: Array[Control] = []
var _section := 0
var _index := 0
var _open := false
var _loaded := false

var _grid: Control
var _tabs: Array[Label] = []
var _name_label: Label
var _price_label: Label
var _status: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := Tokens.label("Store", Tokens.T_TITLE)
	title.position = Vector2(MARGIN.x, 46)
	add_child(title)

	var x := MARGIN.x
	for s in SECTIONS:
		var l := Tokens.label(str(s["label"]), Tokens.T_BODY, Tokens.TEXT_DIM)
		l.position = Vector2(x, 122)
		add_child(l)
		_tabs.append(l)
		x += str(s["label"]).length() * 13 + 56

	var nav := Tokens.label("L1 / R1  Switch section", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	nav.position = Vector2(1920 - 420, 126)
	add_child(nav)

	_grid = Control.new()
	_grid.position = MARGIN + Vector2(0, 42)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_grid)

	_name_label = Tokens.label("", Tokens.T_LABEL)
	_name_label.position = Vector2(MARGIN.x, 1080 - 112)
	_name_label.size = Vector2(1400, 46)
	add_child(_name_label)

	_price_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_price_label.position = Vector2(MARGIN.x, 1080 - 68)
	add_child(_price_label)

	_status = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_status.position = Vector2(MARGIN.x, 1080 - 34)
	add_child(_status)

	Art.art_ready.connect(_on_art_ready)

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	Router.set_consumed(true)
	modulate.a = 0.0
	var t := Tokens.tween(self)
	t.tween_property(self, "modulate:a", 1.0, Tokens.dur(Tokens.D_FAST))

	if _loaded:
		_populate()
	else:
		_status.text = "Loading store…"
		_fetch()

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

func _fetch() -> void:
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	req.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			req.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				_status.text = "Store unavailable — check the network"
				return
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) != TYPE_DICTIONARY:
				_status.text = "Store returned something unreadable"
				return
			_data = parsed
			_loaded = true
			_status.text = ""
			if _open:
				_populate())
	if req.request(API) != OK:
		_status.text = "Could not reach the store"

func _section_items(key: String) -> Array:
	var sec: Variant = _data.get(key)
	if typeof(sec) != TYPE_DICTIONARY:
		return []
	var raw: Array = (sec as Dictionary).get("items", [])
	# Steam repeats entries within a section; dedupe by appid so the grid isn't
	# four copies of the same thing.
	var seen := {}
	var out := []
	for it in raw:
		var id := str(int(it.get("id", 0)))
		if id.is_empty() or id == "0" or seen.has(id):
			continue
		seen[id] = true
		out.append(it)
	return out

# --- Rendering ----------------------------------------------------------------

func _populate() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()

	_items = _section_items(str(SECTIONS[_section]["key"]))
	_index = 0
	_grid.position.y = MARGIN.y + 42

	for i in _items.size():
		_cards.append(_make_card(_items[i], i))

	_apply_tabs()
	if _cards.is_empty():
		_name_label.text = "Nothing here right now"
		_price_label.text = ""
	else:
		_apply_focus(true)

func _make_card(item: Dictionary, i: int) -> Control:
	var holder := Control.new()
	holder.size = CARD
	holder.pivot_offset = CARD * 0.5
	holder.position = Vector2(
		(i % COLS) * (CARD.x + GAP),
		(i / COLS) * (CARD.y + GAP + 34))
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_child(holder)

	var base := ColorRect.new()
	base.size = CARD
	base.color = Tokens.SURFACE_HIGH
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(base)

	var img := TextureRect.new()
	img.size = CARD
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.clip_contents = true
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(img)
	holder.set_meta("img", img)

	var uid := "store:%d" % int(item.get("id", 0))
	var url := str(item.get("header_image", ""))
	var tex: Texture2D = Art.get_art(uid, "store", url)
	if tex:
		img.texture = tex

	var ring := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_border_width_all(3)
	sb.border_color = Tokens.TEXT
	sb.set_corner_radius_all(4)
	ring.add_theme_stylebox_override("panel", sb)
	ring.size = CARD
	ring.modulate.a = 0.0
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ring)
	holder.set_meta("ring", ring)

	var name_l := Tokens.label(str(item.get("name", "")), Tokens.T_CAPTION, Tokens.TEXT_MUTED)
	name_l.position = Vector2(2, CARD.y + 6)
	name_l.size = Vector2(CARD.x, 26)
	name_l.clip_text = true
	holder.add_child(name_l)

	return holder

func _on_art_ready(uid: String, kind: String, texture: Texture2D) -> void:
	if kind != "store" or not _open:
		return
	for i in _cards.size():
		if "store:%d" % int(_items[i].get("id", 0)) == uid:
			var img: TextureRect = _cards[i].get_meta("img")
			img.texture = texture
			img.modulate.a = 0.0
			var t := Tokens.tween(img)
			t.tween_property(img, "modulate:a", 1.0, Tokens.dur(Tokens.D_NORMAL))
			return

func _apply_tabs() -> void:
	for i in _tabs.size():
		_tabs[i].add_theme_color_override(
			"font_color", Tokens.TEXT if i == _section else Tokens.TEXT_DIM)

func _apply_focus(instant: bool) -> void:
	for i in _cards.size():
		var focused := i == _index
		var ring: Panel = _cards[i].get_meta("ring")
		var target := Vector2.ONE * (1.05 if focused else 1.0)
		if instant:
			_cards[i].scale = target
			ring.modulate.a = 1.0 if focused else 0.0
		else:
			var t := create_tween().set_parallel(true)
			t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			t.tween_property(_cards[i], "scale", target, Tokens.dur(Tokens.D_FOCUS))
			t.tween_property(ring, "modulate:a", 1.0 if focused else 0.0,
				Tokens.dur(Tokens.D_FOCUS))
		_cards[i].modulate.a = 1.0 if focused else 0.72

	var item: Dictionary = _items[_index]
	_name_label.text = str(item.get("name", ""))
	_price_label.text = _format_price(item)
	_status.text = "Cross  Open in Steam      Circle  Back"

	var row := _index / COLS
	var row_h := CARD.y + GAP + 34
	var first := maxi(0, row - 2)
	var target_y := MARGIN.y + 42 - first * row_h
	if instant:
		_grid.position.y = target_y
	elif absf(_grid.position.y - target_y) > 1.0:
		var t := Tokens.tween(_grid)
		t.tween_property(_grid, "position:y", target_y, Tokens.dur(Tokens.D_NORMAL))

func _format_price(item: Dictionary) -> String:
	if bool(item.get("free", false)):
		return "Free"
	var final_p := int(item.get("final_price", 0))
	if final_p <= 0:
		return ""
	var cur := str(item.get("currency", "USD"))
	var out := "%.2f %s" % [final_p / 100.0, cur]
	var disc := int(item.get("discount_percent", 0))
	if disc > 0:
		var orig := int(item.get("original_price", 0))
		out = "−%d%%    %.2f %s    was %.2f" % [disc, final_p / 100.0, cur, orig / 100.0]
	return out

# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_east"):
		close()
	elif event.is_action_pressed("penta_r1"):
		_switch_section(1)
	elif event.is_action_pressed("penta_l1"):
		_switch_section(-1)
	elif event.is_action_pressed("penta_right"):
		_move(1)
	elif event.is_action_pressed("penta_left"):
		_move(-1)
	elif event.is_action_pressed("penta_down"):
		_move(COLS)
	elif event.is_action_pressed("penta_up"):
		_move(-COLS)
	elif event.is_action_pressed("penta_south"):
		_open_in_steam()
	else:
		return
	get_viewport().set_input_as_handled()

func _switch_section(delta: int) -> void:
	var next := wrapi(_section + delta, 0, SECTIONS.size())
	if next == _section:
		return
	_section = next
	_populate()

func _move(delta: int) -> void:
	if _cards.is_empty():
		return
	var next := clampi(_index + delta, 0, _cards.size() - 1)
	if next == _index:
		return
	_index = next
	_apply_focus(false)

func _open_in_steam() -> void:
	if _cards.is_empty():
		return
	# JSON numbers arrive as floats in Godot; "1675200.0" is not an appid.
	var appid := str(int(_items[_index].get("id", 0)))
	_status.text = "Opening in Steam…"
	Ipc.request("steam.store", {"appid": appid}, func(ok: bool, payload: Variant) -> void:
		_status.text = "Opened in Steam" if ok else "Steam unavailable: %s" % str(payload))
