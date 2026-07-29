extends Control
class_name InstallerScreen
## Install PENTA to an internal disk.
##
## The daemon demands a typed token ("ERASE NVME0N1") before it will touch a
## disk. That guard exists to stop programmatic accidents — but there is no
## keyboard on a console, so the *human* gate here is holding Cross for three
## seconds. The menu fetches the token and sends it once the hold completes.
##
## Two different mistakes, two different guards: a stray API call cannot wipe a
## disk, and neither can a dropped controller.

signal closed()

const MARGIN := Vector2(160, 200)
const ROW_H := 92.0
const HOLD_SECONDS := 3.0

enum Phase { PICK, CONFIRM, WORKING, DONE }

var _targets: Array = []
var _rows: Array[Control] = []
var _index := 0
var _open := false
var _phase: Phase = Phase.PICK
var _hold := 0.0
var _token := ""

var _title: Label
var _blurb: Label
var _detail: Label
var _hint: Label
var _bar_bg: ColorRect
var _bar_fill: ColorRect
var _bar_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Tokens.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_title = Tokens.label("Install PENTA", Tokens.T_TITLE)
	_title.position = Vector2(MARGIN.x, 56)
	add_child(_title)

	_blurb = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_blurb.position = Vector2(MARGIN.x, 118)
	_blurb.size = Vector2(1500, 40)
	add_child(_blurb)

	_bar_bg = ColorRect.new()
	_bar_bg.position = Vector2(MARGIN.x, 700)
	_bar_bg.size = Vector2(1200, 16)
	_bar_bg.color = Tokens.SURFACE_HIGH
	_bar_bg.visible = false
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_bg)

	_bar_fill = ColorRect.new()
	_bar_fill.position = _bar_bg.position
	_bar_fill.size = Vector2(0, 16)
	_bar_fill.color = Tokens.ACCENT
	_bar_fill.visible = false
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_fill)

	_bar_label = Tokens.label("", Tokens.T_BODY, Tokens.TEXT)
	_bar_label.position = Vector2(MARGIN.x, 660)
	_bar_label.visible = false
	add_child(_bar_label)

	_detail = Tokens.label("", Tokens.T_BODY, Tokens.TEXT_MUTED)
	_detail.position = Vector2(MARGIN.x, 1080 - 120)
	_detail.size = Vector2(1500, 60)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_detail)

	_hint = Tokens.label("", Tokens.T_CAPTION, Tokens.TEXT_DIM)
	_hint.position = Vector2(MARGIN.x, 1080 - 46)
	add_child(_hint)

	Ipc.event_received.connect(_on_event)

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_phase = Phase.PICK
	_index = 0
	_hold = 0.0
	Router.set_consumed(true)
	set_process(true)

	_blurb.text = "Choose a disk. Everything on it will be erased."
	_detail.text = "Reading disks…"
	Ipc.request("install.targets", {}, _on_targets)

	modulate.a = 0.0
	var t := Tokens.tween(self)
	t.tween_property(self, "modulate:a", 1.0, Tokens.dur(Tokens.D_FAST))

func close() -> void:
	# Refusing to close mid-write is not politeness: leaving would let the user
	# start a game while dd is halfway through their partition table.
	if not _open or _phase == Phase.WORKING:
		return
	_open = false
	set_process(false)
	var t := Tokens.tween(self)
	t.tween_property(self, "modulate:a", 0.0, Tokens.dur(Tokens.D_FAST))
	await t.finished
	visible = false
	Router.set_consumed(false)
	closed.emit()

# --- Targets ------------------------------------------------------------------

func _on_targets(ok: bool, payload: Variant) -> void:
	if not ok:
		_detail.text = "Could not read disks: %s" % str(payload)
		return
	_targets = (payload as Dictionary).get("targets", [])
	_build_rows()

func _build_rows() -> void:
	for r in _rows:
		r.queue_free()
	_rows.clear()

	for i in _targets.size():
		var t: Dictionary = _targets[i]
		var row := Control.new()
		row.position = Vector2(MARGIN.x, MARGIN.y + i * ROW_H)
		row.size = Vector2(1300, ROW_H - 12)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)

		var eligible := bool(t.get("eligible", false))
		var name_col := Tokens.TEXT if eligible else Tokens.TEXT_DIM

		var dev := Tokens.label(str(t.get("device", "")), Tokens.T_LABEL, name_col)
		dev.position = Vector2(0, 0)
		row.add_child(dev)

		var meta := Tokens.label("%s  ·  %.0f GB%s" % [
				str(t.get("model", "")), float(t.get("size_gb", 0)),
				"  ·  removable" if t.get("removable", false) else ""],
			Tokens.T_CAPTION, Tokens.TEXT_DIM)
		meta.position = Vector2(0, 40)
		row.add_child(meta)

		if not eligible:
			var why := Tokens.label(str(t.get("reason", "")), Tokens.T_CAPTION, Tokens.DANGER)
			why.position = Vector2(700, 12)
			row.add_child(why)

		_rows.append(row)

	_index = _first_eligible()
	_apply_focus()

func _first_eligible() -> int:
	for i in _targets.size():
		if bool(_targets[i].get("eligible", false)):
			return i
	return 0

func _apply_focus() -> void:
	for i in _rows.size():
		_rows[i].modulate.a = 1.0 if i == _index else 0.55
		var dev: Label = _rows[i].get_child(0)
		dev.text = ("›  " if i == _index else "    ") + str(_targets[i].get("device", ""))

	if _targets.is_empty():
		_detail.text = "No disks found."
		_hint.text = "Circle  Back"
		return

	var t: Dictionary = _targets[_index]
	if bool(t.get("eligible", false)):
		_detail.text = "Installing will erase every partition on %s, including any other operating system on it. This cannot be undone." % str(t.get("device", ""))
		_hint.text = "Hold Cross to install      Circle  Back"
	else:
		_detail.text = str(t.get("reason", ""))
		_hint.text = "Circle  Back"

# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _open or _phase == Phase.WORKING:
		return
	if _phase == Phase.DONE:
		if event.is_action_pressed("penta_east") or event.is_action_pressed("penta_south"):
			close()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("penta_east"):
		close()
	elif event.is_action_pressed("penta_down"):
		_move(1)
	elif event.is_action_pressed("penta_up"):
		_move(-1)
	else:
		return
	get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	if _targets.is_empty():
		return
	_index = clampi(_index + delta, 0, _targets.size() - 1)
	_hold = 0.0
	_apply_focus()

func _process(delta: float) -> void:
	if not _open or _phase == Phase.WORKING or _phase == Phase.DONE:
		return
	if _targets.is_empty():
		return
	if not bool(_targets[_index].get("eligible", false)):
		return

	# Hold, not press. Three seconds is long enough that it cannot happen by
	# accident and short enough that it does not feel like a punishment.
	if Input.is_action_pressed("penta_south"):
		_hold += delta
		_show_hold(_hold / HOLD_SECONDS)
		if _hold >= HOLD_SECONDS:
			_begin_install()
	elif _hold > 0.0:
		_hold = 0.0
		_show_hold(0.0)

func _show_hold(fraction: float) -> void:
	var f := clampf(fraction, 0.0, 1.0)
	_bar_bg.visible = f > 0.0
	_bar_fill.visible = f > 0.0
	_bar_label.visible = f > 0.0
	_bar_fill.size.x = 1200.0 * f
	_bar_fill.color = Tokens.DANGER
	_bar_label.text = "Keep holding to erase %s…" % str(_targets[_index].get("device", ""))

# --- Install ------------------------------------------------------------------

func _begin_install() -> void:
	_phase = Phase.CONFIRM
	var device := str(_targets[_index].get("device", ""))
	_bar_label.text = "Starting…"
	Ipc.request("install.confirm_token", {"device": device},
		func(ok: bool, payload: Variant) -> void:
			if not ok:
				_fail(str(payload))
				return
			_token = str((payload as Dictionary).get("token", ""))
			Ipc.request("install.start", {"device": device, "confirm": _token},
				func(ok2: bool, payload2: Variant) -> void:
					if ok2:
						_phase = Phase.WORKING
						_hint.text = "Do not power off"
					else:
						_fail(str(payload2))))

func _fail(reason: String) -> void:
	_phase = Phase.PICK
	_hold = 0.0
	_show_hold(0.0)
	_detail.text = "Install failed: %s" % reason
	_hint.text = "Circle  Back"

func _on_event(name: String, args: Dictionary) -> void:
	if not _open:
		return
	if name == "install.progress":
		_phase = Phase.WORKING
		var pct := float(args.get("percent", 0.0))
		_bar_bg.visible = true
		_bar_fill.visible = true
		_bar_label.visible = true
		_bar_fill.color = Tokens.ACCENT
		_bar_fill.size.x = 1200.0 * (pct / 100.0)
		var stage := str(args.get("stage", ""))
		if stage == "writing" and args.has("copied_bytes"):
			_bar_label.text = "Writing…  %.0f%%   (%.1f of %.1f GB)" % [
				pct,
				float(args["copied_bytes"]) / 1073741824.0,
				float(args.get("total_bytes", 1)) / 1073741824.0]
		else:
			_bar_label.text = "%s…  %.0f%%" % [stage.capitalize(), pct]
		_detail.text = "Do not power off or remove the USB drive."
		_hint.text = ""
	elif name == "install.done":
		_phase = Phase.DONE
		if bool(args.get("ok", false)):
			_bar_fill.size.x = 1200.0
			_bar_label.text = "Installed"
			_detail.text = "PENTA is installed on %s. Power off, remove the USB drive, and start the machine again." % str(args.get("target", ""))
			_hint.text = "Cross  Done"
		else:
			_fail(str(args.get("error", "unknown error")))
