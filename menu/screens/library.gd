extends Control
class_name LibraryScreen
## Full library as a scrolling grid.
##
## The home carousel is for the handful of games you actually play; this is for
## finding the one you haven't touched in a year. Same cards, same art, denser
## layout, and it scrolls by row rather than by item so the eye keeps its place.

signal closed()
signal launch_requested(uid: String)

const COLS := 6
const CARD := Vector2(240, 240)
const GAP := 22.0
const MARGIN := Vector2(160, 212)

var _titles: Array = []
var _cards: Array[GameCard] = []
var _grid: Control
var _title_label: Label
var _count_label: Label
var _name_label: Label
var _index := 0
var _open := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_title_label = Tokens.label("Library", Tokens.T_TITLE)
	_title_label.position = Vector2(MARGIN.x, 56)
	add_child(_title_label)

	_count_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_count_label.position = Vector2(MARGIN.x, 118)
	add_child(_count_label)

	_grid = Control.new()
	_grid.position = MARGIN
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_grid)

	_name_label = Tokens.label("", Tokens.T_LABEL)
	_name_label.position = Vector2(MARGIN.x, 1080 - 90)
	_name_label.size = Vector2(1600, 46)
	add_child(_name_label)

	var hint := Tokens.label("Cross  Play      Circle  Back", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	hint.position = Vector2(MARGIN.x, 1080 - 46)
	add_child(hint)

func is_open() -> bool:
	return _open

func open(titles: Array) -> void:
	if _open:
		return
	_open = true
	_titles = titles
	_index = 0
	visible = true
	Router.set_consumed(true)
	_populate()

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

func _populate() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()

	_count_label.text = "%d titles" % _titles.size()

	for i in _titles.size():
		var card := GameCard.new()
		_grid.add_child(card)
		card.setup(_titles[i])
		# GameCard is built for the carousel; the grid wants it smaller.
		card.scale = Vector2.ONE * (CARD.x / GameCard.SIZE.x)
		card.position = Vector2(
			(i % COLS) * (CARD.x + GAP),
			(i / COLS) * (CARD.y + GAP))
		_cards.append(card)

	if not _cards.is_empty():
		_apply_focus(true)

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("penta_east"):
		close()
	elif event.is_action_pressed("penta_south"):
		if not _cards.is_empty():
			launch_requested.emit(str(_titles[_index].get("uid", "")))
	elif event.is_action_pressed("penta_right"):
		_move(1)
	elif event.is_action_pressed("penta_left"):
		_move(-1)
	elif event.is_action_pressed("penta_down"):
		_move(COLS)
	elif event.is_action_pressed("penta_up"):
		_move(-COLS)
	else:
		return
	get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	if _cards.is_empty():
		return
	var next := clampi(_index + delta, 0, _cards.size() - 1)
	if next == _index:
		return
	_index = next
	_apply_focus(false)

func _apply_focus(instant: bool) -> void:
	for i in _cards.size():
		# GameCard's own focus scale fights the grid's downscale, so drive the
		# ring and dimming through it but keep our scale authoritative.
		_cards[i].set_focused(i == _index)
		var base := CARD.x / GameCard.SIZE.x
		_cards[i].scale = Vector2.ONE * base * (1.08 if i == _index else 1.0)

	_name_label.text = str(_titles[_index].get("name", ""))

	# Scroll by row: the focused card is always fully visible, and the grid
	# never moves when you step sideways within a row.
	var row := _index / COLS
	var row_h := CARD.y + GAP
	var visible_rows := 3   # 3 rows fit between header and footer
	var first_visible := maxi(0, row - (visible_rows - 1))
	var target_y := MARGIN.y - first_visible * row_h
	if instant:
		_grid.position.y = target_y
	elif absf(_grid.position.y - target_y) > 1.0:
		var t := Tokens.tween(_grid)
		t.tween_property(_grid, "position:y", target_y, Tokens.dur(Tokens.D_NORMAL))
