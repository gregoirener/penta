extends Control
class_name NavIcon
## Top-row navigation icon, drawn as vector geometry.
##
## Drawn rather than imported so the set stays consistent (one 24pt grid, one
## stroke weight) and scales to any panel without assets. Emoji are never used
## as structural icons — they render differently per platform, can't be
## restyled, and carry no accessible name.

enum Kind { SEARCH, LIBRARY, STORE, SETTINGS, PROFILE }

const BOX := 44.0
const STROKE := 2.5

var kind: Kind = Kind.LIBRARY
var label_text := ""

var _focused := false
var _tint := Tokens.TEXT_MUTED

func setup(k: Kind, text: String) -> void:
	kind = k
	label_text = text
	custom_minimum_size = Vector2(BOX, BOX)
	size = Vector2(BOX, BOX)
	pivot_offset = size * 0.5
	# Accessible name, so this is not a mystery glyph to a screen reader.
	tooltip_text = text

func set_focused(v: bool) -> void:
	if v == _focused:
		return
	_focused = v
	var t := create_tween().set_parallel(true)
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(self, "scale", Vector2.ONE * (1.18 if v else 1.0),
		Tokens.dur(Tokens.D_FOCUS))
	t.tween_method(_set_tint, _tint, Tokens.TEXT if v else Tokens.TEXT_MUTED,
		Tokens.dur(Tokens.D_FOCUS))

func _set_tint(c: Color) -> void:
	_tint = c
	queue_redraw()

func _draw() -> void:
	var c := size * 0.5
	var r := BOX * 0.30
	match kind:
		Kind.SEARCH:
			draw_arc(c - Vector2(2, 2), r * 0.75, 0, TAU, 32, _tint, STROKE, true)
			draw_line(c + Vector2(r * 0.45, r * 0.45), c + Vector2(r, r), _tint, STROKE, true)
		Kind.LIBRARY:
			var s := r * 0.66
			for i in 4:
				var p := Vector2(-1 if i % 2 == 0 else 1, -1 if i < 2 else 1)
				draw_rect(Rect2(c + p * s * 0.55 - Vector2(s, s) * 0.5,
					Vector2(s, s)), _tint, false, STROKE)
		Kind.STORE:
			draw_line(c + Vector2(-r, -r * 0.5), c + Vector2(r, -r * 0.5), _tint, STROKE, true)
			draw_line(c + Vector2(-r, -r * 0.5), c + Vector2(-r * 0.7, r), _tint, STROKE, true)
			draw_line(c + Vector2(r, -r * 0.5), c + Vector2(r * 0.7, r), _tint, STROKE, true)
			draw_line(c + Vector2(-r * 0.7, r), c + Vector2(r * 0.7, r), _tint, STROKE, true)
			draw_arc(c + Vector2(0, -r * 0.5), r * 0.42, PI, TAU, 20, _tint, STROKE, true)
		Kind.SETTINGS:
			draw_arc(c, r * 0.45, 0, TAU, 28, _tint, STROKE, true)
			for i in 6:
				var a := TAU * float(i) / 6.0
				var d := Vector2(cos(a), sin(a))
				draw_line(c + d * r * 0.72, c + d * r * 1.05, _tint, STROKE, true)
		Kind.PROFILE:
			draw_arc(c + Vector2(0, -r * 0.35), r * 0.42, 0, TAU, 28, _tint, STROKE, true)
			draw_arc(c + Vector2(0, r * 0.95), r * 0.85, PI, TAU, 28, _tint, STROKE, true)
