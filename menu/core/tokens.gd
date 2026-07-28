extends Node
## Design tokens. Every colour, size, duration and curve in PENTA comes from
## here — never hardcode a value in a screen or widget.
##
## Autoloaded as `Tokens`.

# --- Colour -------------------------------------------------------------------
const BG            := Color("0b0d10")   # near-black, not pure black (banding)
const SURFACE       := Color("14171c")
const SURFACE_HIGH  := Color("1d222a")
const TEXT          := Color("f2f4f8")
const TEXT_MUTED    := Color("9aa3b0")
const TEXT_DIM      := Color("636c7a")
const ACCENT        := Color("2f6fe4")
const DANGER        := Color("e2564a")

# --- Type scale ---------------------------------------------------------------
# Five sizes. If you need a sixth, you probably need a different layout.
const T_CAPTION := 16
const T_BODY    := 20
const T_LABEL   := 26
const T_TITLE   := 44
const T_HERO    := 72

# --- Spacing (8pt rhythm) -----------------------------------------------------
const S1 := 8
const S2 := 16
const S3 := 24
const S4 := 40
const S5 := 64
const S6 := 96

# --- Elevation ----------------------------------------------------------------
# Four levels, each pairing a shadow spread with a surface tint. Blur radius in
# overlays is tied to the same scale. Nothing gets an ad-hoc shadow.
const ELEV := [
	{"spread": 0.0,  "alpha": 0.00, "tint": 0.00},
	{"spread": 8.0,  "alpha": 0.25, "tint": 0.04},
	{"spread": 20.0, "alpha": 0.38, "tint": 0.08},
	{"spread": 44.0, "alpha": 0.50, "tint": 0.14},
]

# --- Motion -------------------------------------------------------------------
# Nothing linear, nothing over 250ms. Focus movement is the fastest thing on
# screen because it has to feel like a direct response to the stick.
const D_INSTANT := 0.08
const D_FOCUS   := 0.12
const D_FAST    := 0.18
const D_NORMAL  := 0.25
const D_SLOW    := 0.45   # ambient background cross-fade only

const EASE_OUT   := Tween.EASE_OUT
const TRANS_CUBIC := Tween.TRANS_CUBIC
const TRANS_BACK  := Tween.TRANS_BACK

## Reduced-motion shortens durations rather than removing transitions —
## a hard cut is more disorienting than a fast fade.
var reduced_motion := false

func dur(d: float) -> float:
	return d * 0.35 if reduced_motion else d

## Standard tween: ease-out cubic, the house curve.
func tween(node: Node) -> Tween:
	var t := node.create_tween()
	t.set_ease(EASE_OUT).set_trans(TRANS_CUBIC)
	return t

## A label with the type scale applied. Saves four override calls everywhere.
func label(text: String, size: int, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
