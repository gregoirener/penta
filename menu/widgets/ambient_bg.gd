extends ColorRect
class_name AmbientBG
## The living background.
##
## A slow-drifting two-blob gradient tinted by the focused title's accent
## colour. This single effect carries most of the "expensive console" feeling —
## a static background is the fastest way to look like a launcher.
##
## Cross-fades over D_SLOW when focus changes, which is deliberately much slower
## than the card animation: the foreground should feel snappy, the background
## should feel like weather.

const SHADER := """
shader_type canvas_item;

uniform vec3 tint : source_color = vec3(0.18, 0.43, 0.89);
uniform vec3 base : source_color = vec3(0.043, 0.051, 0.063);
uniform float t = 0.0;
uniform float intensity = 1.0;

// NOTE: smoothstep's edges must be ordered low..high — reversing them is
// undefined in GLSL and silently renders nothing on some drivers.
float blob(vec2 uv, vec2 c, float r) {
	return 1.0 - smoothstep(0.0, r, distance(uv, c));
}

void fragment() {
	vec2 uv = UV;
	// Correct for aspect so the blobs stay round on a 16:9 panel.
	uv.x *= 1.777;

	vec2 c1 = vec2(0.55 + 0.16 * sin(t * 0.13), 0.30 + 0.10 * cos(t * 0.11));
	vec2 c2 = vec2(1.35 + 0.12 * cos(t * 0.09), 0.78 + 0.09 * sin(t * 0.15));

	float g = blob(uv, c1, 0.62) * 0.90 + blob(uv, c2, 0.50) * 0.45;

	vec3 col = base + tint * g * intensity * 0.15;

	// Vignette, and a floor so we never hit pure black (banding on OLED/VA).
	float v = 1.0 - 0.45 * smoothstep(0.30, 1.05, distance(UV, vec2(0.5)));
	col *= v;
	col = max(col, base * 0.85);

	COLOR = vec4(col, 1.0);
}
"""

var _mat: ShaderMaterial
var _time := 0.0

func _ready() -> void:
	color = Tokens.BG
	# ...and_offsets_, not set_anchors_preset: the latter preserves the current
	# rect, which is 0x0 for a node built in code, so it renders nothing.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("tint", Vector3(Tokens.ACCENT.r, Tokens.ACCENT.g, Tokens.ACCENT.b))
	_mat.set_shader_parameter("base", Vector3(Tokens.BG.r, Tokens.BG.g, Tokens.BG.b))
	material = _mat
	set_process(true)

func _process(delta: float) -> void:
	# Keep drifting even under reduced-motion, just slower: the background is
	# ambient, not an animation someone has to track.
	_time += delta * (0.25 if Tokens.reduced_motion else 1.0)
	_mat.set_shader_parameter("t", _time)

## Cross-fade the tint toward a title's accent colour.
func set_accent(c: Color) -> void:
	var from: Vector3 = _mat.get_shader_parameter("tint")
	var to := Vector3(c.r, c.g, c.b)
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_method(_set_tint, from, to, Tokens.dur(Tokens.D_SLOW))

func _set_tint(v: Vector3) -> void:
	_mat.set_shader_parameter("tint", v)
