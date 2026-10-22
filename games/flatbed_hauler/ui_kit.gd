class_name UIKit
extends RefCounted
## Shared UI primitives for the godot-demos portfolio.
## Translucent panels, 8-pt spacing, type scale, eased tweens,
## reduced-motion + mute flags persisted to user://settings.cfg.
##
## Keep this file copy-usable by other games in the repo. No scene
## references, no autoload lookups.

const S1 := 8
const S2 := 16
const S3 := 24
const S4 := 32
const S5 := 48

const TYPE_TITLE := 34
const TYPE_HEADLINE := 22
const TYPE_BODY := 15
const TYPE_CAPTION := 12
const TYPE_HUD := 48

const PANEL_FILL := Color(1, 1, 1, 0.06)
const PANEL_BORDER := Color(1, 1, 1, 0.12)
const PANEL_RADIUS := 16.0

const INK := Color("e6edf6")
const MUTED := Color("8aa0bb")
const DIM := Color("5c6c86")
const ACCENT := Color("5cc8ff")
const WARN := Color("ffb64d")
const BAD := Color("ff6b6b")
const GOOD := Color("47d18c")

const SETTINGS_PATH := "user://settings.cfg"


static func draw_panel(ci: CanvasItem, rect: Rect2, radius: float = PANEL_RADIUS, fill: Color = PANEL_FILL, border: Color = PANEL_BORDER) -> void:
	_draw_rounded(ci, rect, radius, fill)
	_draw_rounded_outline(ci, rect, radius, border, 1.0)


static func draw_card(ci: CanvasItem, rect: Rect2, accent: Color = ACCENT) -> void:
	draw_panel(ci, rect)
	# Thin accent strip on the left edge keeps the "card" affordance without
	# color-only meaning for the main content.
	var strip := Rect2(rect.position + Vector2(0, 6), Vector2(3, rect.size.y - 12))
	ci.draw_rect(strip, Color(accent.r, accent.g, accent.b, 0.8))


static func _draw_rounded(ci: CanvasItem, rect: Rect2, r: float, color: Color) -> void:
	r = minf(r, minf(rect.size.x, rect.size.y) * 0.5)
	# Center rectangle
	ci.draw_rect(Rect2(rect.position + Vector2(r, 0), Vector2(rect.size.x - 2 * r, rect.size.y)), color)
	# Side rectangles
	ci.draw_rect(Rect2(rect.position + Vector2(0, r), Vector2(r, rect.size.y - 2 * r)), color)
	ci.draw_rect(Rect2(rect.position + Vector2(rect.size.x - r, r), Vector2(r, rect.size.y - 2 * r)), color)
	# Corner fans
	var corners := [
		Vector2(rect.position.x + r, rect.position.y + r),
		Vector2(rect.position.x + rect.size.x - r, rect.position.y + r),
		Vector2(rect.position.x + rect.size.x - r, rect.position.y + rect.size.y - r),
		Vector2(rect.position.x + r, rect.position.y + rect.size.y - r),
	]
	var starts := [PI, -PI / 2.0, 0.0, PI / 2.0]
	for i in range(4):
		var pts := PackedVector2Array()
		pts.append(corners[i])
		var steps := 10
		for s in range(steps + 1):
			var a: float = starts[i] + (PI / 2.0) * (float(s) / steps)
			pts.append(corners[i] + Vector2(cos(a), sin(a)) * r)
		ci.draw_colored_polygon(pts, color)


static func _draw_rounded_outline(ci: CanvasItem, rect: Rect2, r: float, color: Color, width: float) -> void:
	r = minf(r, minf(rect.size.x, rect.size.y) * 0.5)
	var pts := PackedVector2Array()
	var steps := 10
	# TL corner
	var c := rect.position + Vector2(r, r)
	for s in range(steps + 1):
		var a: float = PI + (PI / 2.0) * (float(s) / steps)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	# TR
	c = rect.position + Vector2(rect.size.x - r, r)
	for s in range(steps + 1):
		var a: float = -PI / 2.0 + (PI / 2.0) * (float(s) / steps)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	# BR
	c = rect.position + Vector2(rect.size.x - r, rect.size.y - r)
	for s in range(steps + 1):
		var a: float = 0.0 + (PI / 2.0) * (float(s) / steps)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	# BL
	c = rect.position + Vector2(r, rect.size.y - r)
	for s in range(steps + 1):
		var a: float = PI / 2.0 + (PI / 2.0) * (float(s) / steps)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	pts.append(pts[0])
	ci.draw_polyline(pts, color, width, true)


static func draw_ring(ci: CanvasItem, center: Vector2, radius: float, frac: float, color: Color, width: float = 3.0) -> void:
	# Draws an arc from 12 o'clock clockwise for `frac` of a full circle.
	frac = clampf(frac, 0.0, 1.0)
	var steps := int(maxf(6.0, 48.0 * frac))
	var pts := PackedVector2Array()
	for i in range(steps + 1):
		var a: float = -PI / 2.0 + TAU * (float(i) / 48.0)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	if pts.size() >= 2:
		ci.draw_polyline(pts, color, width, true)


static func draw_ring_bg(ci: CanvasItem, center: Vector2, radius: float, color: Color, width: float = 3.0) -> void:
	var pts := PackedVector2Array()
	for i in range(49):
		var a: float = TAU * (float(i) / 48.0)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	ci.draw_polyline(pts, color, width, true)


# Easing helpers --------------------------------------------------------------
static func ease_out_250(tween: Tween, obj: Object, prop: String, to) -> PropertyTweener:
	return tween.tween_property(obj, prop, to, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


static func spring_back(tween: Tween, obj: Object, prop: String, to) -> PropertyTweener:
	return tween.tween_property(obj, prop, to, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Formatting ------------------------------------------------------------------
static func money(v: float) -> String:
	var neg := v < 0.0
	var s := str(int(roundf(absf(v))))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-$" if neg else "$") + s + out


static func mmss(v: float) -> String:
	v = maxf(0.0, v)
	return "%d:%02d" % [int(v) / 60, int(v) % 60]


# Settings persistence --------------------------------------------------------
# ConfigFile keys: audio.volume (float 0..1), audio.mute (bool),
# accessibility.reduced_motion (bool), accessibility.colorblind (bool),
# ui.show_controls (bool).
static func default_settings() -> Dictionary:
	return {
		"volume": 0.7,
		"mute": false,
		"reduced_motion": false,
		"colorblind": false,
		"show_controls": true,
	}


static func load_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	var d := default_settings()
	if cfg.load(SETTINGS_PATH) != OK:
		return d
	d.volume = cfg.get_value("audio", "volume", d.volume)
	d.mute = cfg.get_value("audio", "mute", d.mute)
	d.reduced_motion = cfg.get_value("accessibility", "reduced_motion", d.reduced_motion)
	d.colorblind = cfg.get_value("accessibility", "colorblind", d.colorblind)
	d.show_controls = cfg.get_value("ui", "show_controls", d.show_controls)
	return d


static func save_settings(d: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "volume", d.volume)
	cfg.set_value("audio", "mute", d.mute)
	cfg.set_value("accessibility", "reduced_motion", d.reduced_motion)
	cfg.set_value("accessibility", "colorblind", d.colorblind)
	cfg.set_value("ui", "show_controls", d.show_controls)
	cfg.save(SETTINGS_PATH)


# Font helpers ----------------------------------------------------------------
static func tabular_variation(font: FontFile) -> FontVariation:
	var v := FontVariation.new()
	v.base_font = font
	v.opentype_features = {&"tnum": 1}
	return v
