extends Control
class_name GameCard
## One title tile.
##
## Until real key art exists (M2), the card generates its own: a gradient built
## from the title's accent colour plus typeset name. A card is never blank and
## never shows a broken image — that rule is why the dashboard looks finished
## long before the artwork pipeline does.

const SIZE := Vector2(280, 280)
const FOCUS_SCALE := 1.10

var title: Dictionary = {}
var accent: Color = Tokens.ACCENT

var _uid := ""
var _art: TextureRect
var _cover: TextureRect
var _shade: ColorRect
var _name: Label
var _ring: Panel
var _focused := false

func setup(t: Dictionary) -> void:
	title = t
	accent = Color(str(t.get("accent", "#2f6fe4")))
	_uid = str(t.get("uid", ""))
	custom_minimum_size = SIZE
	size = SIZE
	pivot_offset = SIZE * 0.5          # scale from the centre, not the corner
	clip_contents = false

	_build_art()
	_build_shade()
	_build_name()
	_build_ring()
	_apply_focus(false, true)
	_request_cover()

## Real cover art if Steam has it, generated gradient until then.
##
## The gradient stays underneath rather than being replaced: a card is never
## blank, never shows a broken image, and the swap is a fade rather than a pop.
func _request_cover() -> void:
	var art: Dictionary = title.get("art", {})
	if art.is_empty():
		return

	_cover = TextureRect.new()
	_cover.size = SIZE
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Portrait capsules are 2:3; centre-crop into the square tile so the key
	# artwork survives instead of being squashed.
	_cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_cover.clip_contents = true
	_cover.modulate.a = 0.0
	add_child(_cover)
	move_child(_cover, 1)              # above the gradient, below the shade

	var tex: Texture2D = Art.get_art(_uid, "cover", str(art.get("cover", "")))
	if tex:
		_show_cover(tex)
	else:
		Art.art_ready.connect(_on_art_ready)

func _on_art_ready(uid: String, kind: String, texture: Texture2D) -> void:
	if uid != _uid:
		return
	if kind == "cover":
		_show_cover(texture)
	elif kind == "fallback" and _cover and _cover.texture == null:
		_show_cover(texture)

func _show_cover(tex: Texture2D) -> void:
	if not _cover:
		return
	_cover.texture = tex
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_cover, "modulate:a", 1.0, Tokens.dur(Tokens.D_NORMAL))

func _build_art() -> void:
	var grad := Gradient.new()
	grad.set_color(0, accent.darkened(0.55))
	grad.set_color(1, accent.lightened(0.12))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = int(SIZE.x)
	tex.height = int(SIZE.y)
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0.1, 0.0)
	tex.fill_to = Vector2(0.9, 1.0)

	_art = TextureRect.new()
	_art.texture = tex
	_art.size = SIZE
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_art)

func _build_shade() -> void:
	# Darkens the lower half so the name is always legible over any art —
	# the same trick a real cover-art pipeline needs anyway.
	_shade = ColorRect.new()
	_shade.size = SIZE
	_shade.color = Color(0, 0, 0, 0.0)
	_shade.material = _shade_material()
	add_child(_shade)

func _shade_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
void fragment() {
	float g = smoothstep(0.45, 1.0, UV.y);
	COLOR = vec4(0.0, 0.0, 0.0, g * 0.72);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

func _build_name() -> void:
	_name = Tokens.label(str(title.get("name", "Untitled")), Tokens.T_CAPTION)
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name.position = Vector2(Tokens.S2, SIZE.y - 74)
	_name.size = Vector2(SIZE.x - Tokens.S2 * 2, 60)
	_name.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(_name)

func _build_ring() -> void:
	# Focus indicator. Deliberately a *shape*, not just a colour change —
	# colour alone fails for anyone who can't distinguish it.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_border_width_all(3)
	sb.border_color = Tokens.TEXT
	sb.set_corner_radius_all(4)
	sb.expand_margin_left = 5.0
	sb.expand_margin_right = 5.0
	sb.expand_margin_top = 5.0
	sb.expand_margin_bottom = 5.0

	_ring = Panel.new()
	_ring.add_theme_stylebox_override("panel", sb)
	_ring.size = SIZE
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.modulate.a = 0.0
	add_child(_ring)

func set_focused(v: bool) -> void:
	if v == _focused:
		return
	_focused = v
	_apply_focus(v, false)

func _apply_focus(v: bool, instant: bool) -> void:
	var target_scale := Vector2.ONE * (FOCUS_SCALE if v else 1.0)
	var target_ring := 1.0 if v else 0.0
	var target_dim := 1.0 if v else 0.62      # unfocused cards recede

	if instant:
		scale = target_scale
		_ring.modulate.a = target_ring
		modulate.a = target_dim
		return

	# Slight overshoot on focus-in: it reads as physical rather than digital.
	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_BACK if v else Tween.TRANS_CUBIC)
	t.tween_property(self, "scale", target_scale, Tokens.dur(Tokens.D_FOCUS))
	t.tween_property(_ring, "modulate:a", target_ring, Tokens.dur(Tokens.D_FOCUS))
	t.tween_property(self, "modulate:a", target_dim, Tokens.dur(Tokens.D_FOCUS))
