extends Control
## PENTA home screen.
##
## Two focus rows: the icon strip along the top, and the title carousel. The
## carousel slides so the focused card always sits at a fixed anchor on the
## left — the row moves, the focus doesn't. That fixed-anchor behaviour is a
## large part of why console dashboards feel calm and PC launchers don't.

const ANCHOR_X := 160.0            # where the focused card always sits
const CARD_GAP := 28.0
const ROW_Y := 660.0
const ICONS_Y := 56.0
const INFO_Y := 400.0

enum Row { ICONS, CARDS }

var _bg: AmbientBG
var _row: Control
var _cards: Array[GameCard] = []
var _icons: Array[NavIcon] = []
var _titles: Array = []
var _running_uid := ""

var _row_focus: Row = Row.CARDS
var _card_index := 0
var _icon_index := 1

var _name_label: Label
var _meta_label: Label
var _hint_label: Label
var _clock_label: Label
var _status_label: Label
var _launch_veil: ColorRect
var _control: ControlCenter
var _power: PowerMenu
var _library: LibraryScreen
var _settings: SettingsScreen
var _store: StoreScreen
var _profile: ProfileScreen

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_background()
	_build_icons()
	_build_info()
	_build_row()
	_build_status()
	_build_veil()
	_build_overlays()

	Router.nav.connect(_on_nav)
	Router.confirm.connect(_on_confirm)
	Router.back.connect(_on_back)
	Router.ps_button.connect(_on_ps)

	Ipc.connected_changed.connect(_on_connection_changed)
	Ipc.event_received.connect(_on_daemon_event)

	_set_status("Connecting to pentad…")
	_tick_clock()
	var clock := Timer.new()
	clock.wait_time = 1.0
	clock.autostart = true
	clock.timeout.connect(_tick_clock)
	add_child(clock)

	_dev_capture_if_requested()

# --- Dev tooling --------------------------------------------------------------

## `godot --path menu -- /tmp/shot.png [control|power]` renders a few frames and
## writes a PNG, optionally with an overlay open. Lets UI changes be checked
## without a console or a controller attached.
func _dev_capture_if_requested() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	await get_tree().create_timer(6.0).timeout   # let cover art arrive
	if args.size() > 1:
		match args[1]:
			"control":  _control.open(false)
			"power":    _power.open()
			"library":  _library.open(_titles)
			"settings": _settings.open()
			"store":    _store.open()
			"profile":  _profile.open(_titles)
		await get_tree().create_timer(7.0).timeout
	for i in 3:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(args[0])
	print("captured ", args[0])
	get_tree().quit()

# --- Construction -------------------------------------------------------------

func _build_background() -> void:
	_bg = AmbientBG.new()
	add_child(_bg)

func _build_icons() -> void:
	var strip := HBoxContainer.new()
	strip.position = Vector2(ANCHOR_X, ICONS_Y)
	strip.add_theme_constant_override("separation", int(Tokens.S4))
	add_child(strip)

	var spec := [
		[NavIcon.Kind.SEARCH,   "Search"],
		[NavIcon.Kind.LIBRARY,  "Library"],
		[NavIcon.Kind.STORE,    "Store"],
		[NavIcon.Kind.SETTINGS, "Settings"],
		[NavIcon.Kind.PROFILE,  "Profile"],
	]
	for s in spec:
		var ic := NavIcon.new()
		strip.add_child(ic)
		ic.setup(s[0], s[1])
		_icons.append(ic)

func _build_info() -> void:
	_name_label = Tokens.label("", Tokens.T_HERO)
	_name_label.position = Vector2(ANCHOR_X, INFO_Y)
	add_child(_name_label)

	_meta_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_meta_label.position = Vector2(ANCHOR_X, INFO_Y + 96)
	add_child(_meta_label)

	_hint_label = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_hint_label.position = Vector2(ANCHOR_X, INFO_Y + 136)
	add_child(_hint_label)

func _build_row() -> void:
	_row = Control.new()
	_row.position = Vector2(ANCHOR_X, ROW_Y)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)

func _build_status() -> void:
	_clock_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_clock_label.position = Vector2(1920 - 260, ICONS_Y + 8)
	_clock_label.size = Vector2(180, 32)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_clock_label)

	_status_label = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_status_label.position = Vector2(ANCHOR_X, 1080 - 56)
	add_child(_status_label)

func _build_overlays() -> void:
	# Added last so they sit above everything, including the launch veil.
	_control = ControlCenter.new()
	add_child(_control)
	_control.power_requested.connect(_on_power_requested)

	_power = PowerMenu.new()
	add_child(_power)

	_library = LibraryScreen.new()
	add_child(_library)
	_library.launch_requested.connect(_on_library_launch)

	_settings = SettingsScreen.new()
	add_child(_settings)

	_store = StoreScreen.new()
	add_child(_store)

	_profile = ProfileScreen.new()
	add_child(_profile)

func _build_veil() -> void:
	# Covers the screen while a title launches, so the handoff to gamescope is
	# a fade rather than a flash of desktop.
	_launch_veil = ColorRect.new()
	_launch_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_launch_veil.color = Color(0, 0, 0, 1)
	_launch_veil.modulate.a = 0.0
	_launch_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_launch_veil)

# --- Library ------------------------------------------------------------------

func _on_connection_changed(is_connected: bool) -> void:
	if is_connected:
		_set_status("")
		Ipc.request("library.list", {}, _on_library)
	else:
		_set_status("pentad unavailable — retrying")

func _on_library(ok: bool, payload: Variant) -> void:
	if not ok:
		_set_status("library error: %s" % str(payload))
		return
	_titles = (payload as Dictionary).get("titles", [])
	_populate()

func _populate() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()

	var x := 0.0
	for t in _titles:
		var card := GameCard.new()
		_row.add_child(card)
		card.setup(t)
		card.position = Vector2(x, 0)
		_cards.append(card)
		x += GameCard.SIZE.x + CARD_GAP

	_card_index = 0
	if _cards.is_empty():
		_name_label.text = "No titles"
		_meta_label.text = "Add games to /games or sign in to Steam"
		return
	_apply_focus(true)

# --- Focus & navigation -------------------------------------------------------

func _on_nav(dir: Vector2i) -> void:
	if _row_focus == Row.CARDS:
		if dir.y < 0:
			_row_focus = Row.ICONS
			_apply_focus(false)
			return
		if dir.x != 0 and not _cards.is_empty():
			var next := clampi(_card_index + dir.x, 0, _cards.size() - 1)
			if next != _card_index:
				_card_index = next
				_apply_focus(false)
	else:
		if dir.y > 0:
			_row_focus = Row.CARDS
			_apply_focus(false)
			return
		if dir.x != 0:
			var next := clampi(_icon_index + dir.x, 0, _icons.size() - 1)
			if next != _icon_index:
				_icon_index = next
				_apply_focus(false)

func _apply_focus(instant: bool) -> void:
	for i in _icons.size():
		_icons[i].set_focused(_row_focus == Row.ICONS and i == _icon_index)
	for i in _cards.size():
		_cards[i].set_focused(_row_focus == Row.CARDS and i == _card_index)

	if _cards.is_empty():
		return

	# Slide the row so the focused card lands on the anchor.
	var target_x := -(_card_index * (GameCard.SIZE.x + CARD_GAP))
	if instant:
		_row.position.x = ANCHOR_X + target_x
	else:
		var t := Tokens.tween(_row)
		t.tween_property(_row, "position:x", ANCHOR_X + target_x,
			Tokens.dur(Tokens.D_NORMAL))

	_update_info()

func _update_info() -> void:
	if _cards.is_empty():
		return
	var t: Dictionary = _titles[_card_index]
	_name_label.text = str(t.get("name", ""))
	_meta_label.text = _format_meta(t)
	_hint_label.text = "Cross  Play      Triangle  Options" \
		if _row_focus == Row.CARDS else ""
	_bg.set_accent(Color(str(t.get("accent", "#2f6fe4"))))

	# Push the focused title's colour to the controller lightbar. Harmless if
	# the daemon is mocked; genuinely lovely on real hardware.
	var c := Color(str(t.get("accent", "#2f6fe4")))
	Ipc.request("led.set", {"r": int(c.r * 255), "g": int(c.g * 255), "b": int(c.b * 255)})

func _format_meta(t: Dictionary) -> String:
	var parts: Array[String] = []
	var hours := int(t.get("playtime_s", 0)) / 3600
	if hours > 0:
		parts.append("%d hours played" % hours)
	var last: Variant = t.get("last_played")
	if last == null:
		parts.append("Never played")
	parts.append(str(t.get("provider", "")).to_upper())
	return "   ·   ".join(parts)

# --- Actions ------------------------------------------------------------------

func _on_confirm() -> void:
	if _row_focus == Row.ICONS:
		_activate_icon()
		return
	if _cards.is_empty():
		return
	var t: Dictionary = _titles[_card_index]
	_set_status("Starting %s…" % str(t.get("name", "")))
	Router.set_consumed(true)

	var fade := Tokens.tween(_launch_veil)
	fade.tween_property(_launch_veil, "modulate:a", 1.0, Tokens.dur(Tokens.D_NORMAL))

	_running_uid = str(t.get("uid", ""))
	Ipc.request("title.launch", {"uid": t.get("uid", "")}, func(ok: bool, payload: Variant) -> void:
		if not ok:
			_running_uid = ""
			_set_status("Launch failed: %s" % str(payload))
			_restore_from_launch()
	)

## Top row actions. Search and Profile are honest placeholders — they say so
## rather than silently doing nothing, which is worse than being unfinished.
func _activate_icon() -> void:
	match _icon_index:
		0:  # Search — needs an on-screen keyboard; the grid is the useful half.
			_set_status("Search needs an on-screen keyboard — opening Library")
			_library.open(_titles)
		1:  # Library
			_library.open(_titles)
		2:  # Store — Steam's catalogue, our UI. Buying happens in Steam.
			_store.open()
		3:  # Settings
			_settings.open()
		4:  # Profile
			_profile.open(_titles)

func _on_library_launch(uid: String) -> void:
	await _library.close()
	for i in _titles.size():
		if str(_titles[i].get("uid", "")) == uid:
			_card_index = i
			_row_focus = Row.CARDS
			_apply_focus(false)
			break
	_on_confirm()

func _on_back() -> void:
	if _row_focus == Row.ICONS:
		_row_focus = Row.CARDS
		_apply_focus(false)

func _on_ps() -> void:
	if _power.visible:
		_power.close()
	elif _control.is_open():
		_control.close()
	else:
		_control.open(_running_uid != "")

func _on_power_requested() -> void:
	# Hand off from Control Center to the power menu without a flash of home.
	await _control.close()
	_power.open()

func _restore_from_launch() -> void:
	Router.set_consumed(false)
	var t := Tokens.tween(_launch_veil)
	t.tween_property(_launch_veil, "modulate:a", 0.0, Tokens.dur(Tokens.D_NORMAL))

func _on_daemon_event(event_name: String, args: Dictionary) -> void:
	match event_name:
		"title.exited":
			_running_uid = ""
			_set_status("")
			_restore_from_launch()
			# refresh, not list: you may have just installed a game inside
			# Steam, and a cached library would not show it until a reboot.
			Ipc.request("library.refresh", {}, _on_library)
		"input.ps_button":
			# The real PS button, seen by the daemon at the evdev layer — it
			# arrives even while a game holds focus, which is the entire point.
			if str(args.get("kind", "short")) == "long":
				_power.open()
			else:
				_on_ps()
		"controller.battery":
			var pct := int(args.get("pct", 0))
			if pct <= 20:
				_set_status("Controller battery %d%%" % pct)
		"notification":
			_set_status(str(args.get("text", "")))

# --- Chrome -------------------------------------------------------------------

func _tick_clock() -> void:
	var t := Time.get_time_dict_from_system()
	_clock_label.text = "%02d:%02d" % [t.hour, t.minute]

func _set_status(text: String) -> void:
	_status_label.text = text
