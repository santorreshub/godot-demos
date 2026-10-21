extends Node2D
## DISPATCH: BEAT THE AI BROKER
## A cross-border load board (USA · Mexico · Canada). Loads pop up, you dispatch
## your trucks, and an AI broker agent competes for the same freight using a
## utility score (profit per total mile, deadhead limits). Out-earn it in a 3-minute shift.
##
## Click a load > click one of your idle trucks (or press 1/2/3). ENTER restarts.
## Everything is drawn in code.

const MAP_W := 860.0
const SHIFT := 180.0
const COST_PER_MILE := 1.6
const MILES_PER_PX := 2.2
const TRUCK_SPEED := 38.0
const MAX_LOADS := 7
const LOAD_LIFE := 24.0
const AI_THINK := 1.4
const AI_MAX_DEADHEAD := 650.0

const CITIES := {
	"LA": Vector2(110, 330), "DEN": Vector2(330, 250), "DAL": Vector2(470, 370),
	"HOU": Vector2(520, 430), "LRD": Vector2(440, 485), "MTY": Vector2(430, 540),
	"CDMX": Vector2(470, 650), "CHI": Vector2(610, 190), "ATL": Vector2(690, 370),
	"TOR": Vector2(735, 125),
}
const MEXICO := ["MTY", "CDMX"]
const CANADA := ["TOR"]

const BG := Color("0e1726")
const LAND := Color("1c2b40")
const LAND_EDGE := Color("2e4563")
const INK := Color("e6edf6")
const MUTED := Color("8aa0bb")
const YOU := Color("3fa9f5")
const AI := Color("ff8a3d")
const GOOD := Color("47d18c")
const PANEL := Color("131f33")

var font: Font
var rng := RandomNumberGenerator.new()
var loads: Array = []
var trucks: Array = []
var selected := -1
var money := {"you": 0.0, "ai": 0.0}
var delivered := {"you": 0, "ai": 0}
var time_left := SHIFT
var spawn_t := 0.0
var ai_t := 6.0  # head start for the human
var next_id := 1
var over := false
var feed: Array[String] = []


func _ready() -> void:
	font = ThemeDB.fallback_font
	rng.randomize()
	for i in range(3):
		trucks.append(_truck("you", i + 1, ["HOU", "DAL", "CHI"][i]))
		trucks.append(_truck("ai", i + 1, ["LRD", "ATL", "DEN"][i]))
	for i in range(4):
		_spawn_load()
	_log("Shift started. The AI broker is live.")


func _truck(owner: String, num: int, city: String) -> Dictionary:
	return {"owner": owner, "num": num, "pos": CITIES[city], "city": city, "state": "idle", "load": {}, "deadhead": 0.0}


# ------------------------------------------------------------------ loads
func _spawn_load() -> void:
	var names := CITIES.keys()
	var a: String = names[rng.randi() % names.size()]
	var b: String = a
	while b == a:
		b = names[rng.randi() % names.size()]
	var miles: float = CITIES[a].distance_to(CITIES[b]) * MILES_PER_PX
	var rpm := rng.randf_range(2.1, 3.5)
	var border := (a in MEXICO) != (b in MEXICO) or (a in CANADA) != (b in CANADA)
	if border:
		rpm *= 1.25  # cross-border pays more
	loads.append({
		"id": next_id, "from": a, "to": b, "miles": miles,
		"rate": roundf(miles * rpm / 10.0) * 10.0, "life": LOAD_LIFE, "border": border,
	})
	next_id += 1


func _load_by_id(id: int) -> Dictionary:
	for l in loads:
		if l.id == id:
			return l
	return {}


func _dispatch(t: Dictionary, l: Dictionary) -> void:
	t.state = "pickup"
	t.load = l
	t.deadhead = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
	loads.erase(l)
	if selected == l.id:
		selected = -1


func _profit(t: Dictionary, l: Dictionary) -> float:
	var dh: float = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
	return l.rate - (dh + l.miles) * COST_PER_MILE


# ------------------------------------------------------------------ AI broker
## Utility AI: score every (idle truck, open load) pair by profit per total mile,
## skip long deadheads and money-losers, then take the single best pair.
func _ai_think() -> void:
	var best_score := 0.25
	var best_t := {}
	var best_l := {}
	for t in trucks:
		if t.owner != "ai" or t.state != "idle":
			continue
		for l in loads:
			var dh: float = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
			if dh > AI_MAX_DEADHEAD:
				continue
			var total: float = dh + l.miles
			var profit: float = l.rate - total * COST_PER_MILE
			var score: float = profit / total
			if score > best_score:
				best_score = score
				best_t = t
				best_l = l
	if best_t.is_empty():
		return
	var est := _profit(best_t, best_l)
	_log("AI took %s>%s  est. +$%s  ($%.2f/mi)" % [best_l.from, best_l.to, _money(est), best_score])
	_dispatch(best_t, best_l)


# ------------------------------------------------------------------ loop
func _process(delta: float) -> void:
	if not over:
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			over = true
			_log("Shift over.")

		spawn_t -= delta
		if spawn_t <= 0.0 and loads.size() < MAX_LOADS:
			_spawn_load()
			spawn_t = rng.randf_range(2.0, 4.0)

		for l in loads.duplicate():
			l.life -= delta
			if l.life <= 0.0:
				loads.erase(l)
				if selected == l.id:
					selected = -1

		ai_t -= delta
		if ai_t <= 0.0:
			_ai_think()
			ai_t = AI_THINK

		for t in trucks:
			_move_truck(t, delta)

	queue_redraw()


func _move_truck(t: Dictionary, delta: float) -> void:
	if t.state == "idle":
		return
	var target: Vector2 = CITIES[t.load.from] if t.state == "pickup" else CITIES[t.load.to]
	t.pos = t.pos.move_toward(target, TRUCK_SPEED * delta)
	if t.pos.distance_to(target) < 0.5:
		if t.state == "pickup":
			t.state = "loaded"
		else:
			var profit: float = t.load.rate - (t.deadhead + t.load.miles) * COST_PER_MILE
			money[t.owner] += profit
			delivered[t.owner] += 1
			t.city = t.load.to
			t.state = "idle"
			var who := "You" if t.owner == "you" else "AI"
			_log("%s delivered %s>%s  %s$%s" % [who, t.load.from, t.load.to, "+" if profit >= 0 else "-", _money(absf(profit))])
			t.load = {}


# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ENTER:
			get_tree().reload_current_scene()
		elif event.physical_keycode in [KEY_1, KEY_2, KEY_3]:
			_try_dispatch(event.physical_keycode - KEY_1 + 1)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var m := get_global_mouse_position()
		for i in range(loads.size()):
			if _row_rect(i).has_point(m):
				selected = loads[i].id
				return
		for t in trucks:
			if t.owner == "you" and t.pos.distance_to(m) < 18.0:
				_try_dispatch(t.num)
				return


func _try_dispatch(num: int) -> void:
	if over:
		return
	var l := _load_by_id(selected)
	if l.is_empty():
		_log("Pick a load first.")
		return
	for t in trucks:
		if t.owner == "you" and t.num == num:
			if t.state != "idle":
				_log("Truck %d is busy." % num)
				return
			_log("You took %s>%s with truck %d  est. +$%s" % [l.from, l.to, num, _money(_profit(t, l))])
			_dispatch(t, l)
			return


# ------------------------------------------------------------------ helpers
func _row_rect(i: int) -> Rect2:
	return Rect2(MAP_W + 14, 96 + i * 64, 1280 - MAP_W - 28, 56)


func _money(v: float) -> String:
	var s := str(int(roundf(v)))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _log(text: String) -> void:
	feed.push_front(text)
	if feed.size() > 6:
		feed.pop_back()


func _text(pos: Vector2, s: String, size := 16, color := INK, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, pos, s, align, width, size, color)


# ------------------------------------------------------------------ drawing
func _draw() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), BG)
	_draw_map()
	_draw_panel()
	if over:
		_draw_result()


func _draw_map() -> void:
	# Stylized North America
	var land := PackedVector2Array([
		Vector2(60, 60), Vector2(820, 50), Vector2(840, 160), Vector2(760, 230), Vector2(760, 330),
		Vector2(700, 440), Vector2(600, 470), Vector2(540, 470), Vector2(520, 560), Vector2(560, 640),
		Vector2(520, 700), Vector2(420, 690), Vector2(380, 580), Vector2(300, 470), Vector2(200, 430),
		Vector2(80, 380), Vector2(60, 240),
	])
	draw_colored_polygon(land, LAND)
	var edge := land.duplicate()
	edge.append(land[0])
	draw_polyline(edge, LAND_EDGE, 2)
	# Borders
	draw_dashed_line(Vector2(80, 380), Vector2(540, 470), MUTED.darkened(0.4), 1.5, 8)
	draw_dashed_line(Vector2(560, 160), Vector2(840, 160), MUTED.darkened(0.4), 1.5, 8)
	_text(Vector2(80, 40), "DISPATCH  ·  BEAT THE AI BROKER", 22, INK)

	# Selected lane + your deadhead options
	var l := _load_by_id(selected)
	if not l.is_empty():
		draw_line(CITIES[l.from], CITIES[l.to], GOOD, 4)
		for t in trucks:
			if t.owner == "you" and t.state == "idle":
				draw_dashed_line(t.pos, CITIES[l.from], YOU, 2, 6)
				var mid: Vector2 = (t.pos + CITIES[l.from]) / 2
				_text(mid + Vector2(6, -6), "%d: %s mi dh" % [t.num, _money(t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX)], 13, YOU)

	# Active lanes
	for t in trucks:
		if t.state == "idle":
			continue
		var c: Color = YOU if t.owner == "you" else AI
		var target: Vector2 = CITIES[t.load.from] if t.state == "pickup" else CITIES[t.load.to]
		draw_line(t.pos, target, Color(c, 0.45), 2)

	for name in CITIES:
		var p: Vector2 = CITIES[name]
		draw_circle(p, 7, LAND_EDGE)
		draw_circle(p, 4, INK)
		_text(p + Vector2(10, -8), name, 14, MUTED)

	for t in trucks:
		var c: Color = YOU if t.owner == "you" else AI
		draw_rect(Rect2(t.pos - Vector2(13, 9), Vector2(26, 18)), c)
		if t.state == "loaded":
			draw_rect(Rect2(t.pos - Vector2(13, 9), Vector2(26, 18)), INK, false, 2)
		_text(t.pos + Vector2(-13, 5), str(t.num) if t.owner == "you" else "AI", 13, BG, HORIZONTAL_ALIGNMENT_CENTER, 26)


func _draw_panel() -> void:
	draw_rect(Rect2(MAP_W, 0, 1280 - MAP_W, 720), PANEL)
	_text(Vector2(MAP_W + 16, 32), "%d:%02d" % [int(time_left) / 60, int(time_left) % 60], 26, INK)
	_text(Vector2(MAP_W + 110, 24), "YOU  $%s  (%d)" % [_money(money.you), delivered.you], 16, YOU)
	_text(Vector2(MAP_W + 110, 46), "AI     $%s  (%d)" % [_money(money.ai), delivered.ai], 16, AI)
	_text(Vector2(MAP_W + 16, 80), "LOAD BOARD — click a load, then your truck (1/2/3)", 13, MUTED)

	for i in range(loads.size()):
		var l: Dictionary = loads[i]
		var r := _row_rect(i)
		draw_rect(r, Color("1d2c45") if l.id != selected else Color("23415e"))
		if l.id == selected:
			draw_rect(r, GOOD, false, 2)
		var lane := "%s > %s" % [l.from, l.to]
		_text(r.position + Vector2(12, 22), lane, 18, INK)
		if l.border:
			_text(r.position + Vector2(150, 22), "CROSS-BORDER", 12, GOOD)
		_text(r.position + Vector2(12, 44), "$%s  ·  %s mi  ·  $%.2f/mi" % [_money(l.rate), _money(l.miles), l.rate / l.miles], 14, MUTED)
		var frac: float = clampf(l.life / LOAD_LIFE, 0.0, 1.0)
		draw_rect(Rect2(r.position + Vector2(0, r.size.y - 3), Vector2(r.size.x * frac, 3)), AI if frac < 0.3 else GOOD)

	var y := 560.0
	_text(Vector2(MAP_W + 16, y), "ACTIVITY", 13, MUTED)
	for i in range(feed.size()):
		var c := AI if feed[i].begins_with("AI") else (YOU if feed[i].begins_with("You") else INK)
		_text(Vector2(MAP_W + 16, y + 22 + i * 22), feed[i], 13, Color(c, 1.0 - i * 0.12))


func _draw_result() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(0, 0, 0, 0.6))
	var won: bool = money.you > money.ai
	_text(Vector2(0, 300), "YOU BEAT THE AI BROKER" if won else "THE AI BROKER WINS THIS SHIFT", 44, GOOD if won else AI, HORIZONTAL_ALIGNMENT_CENTER, 1280)
	_text(Vector2(0, 360), "You $%s   ·   AI $%s" % [_money(money.you), _money(money.ai)], 26, INK, HORIZONTAL_ALIGNMENT_CENTER, 1280)
	_text(Vector2(0, 410), "ENTER to run another shift", 18, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 1280)
