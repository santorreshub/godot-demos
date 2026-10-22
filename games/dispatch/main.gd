extends Node2D
## DISPATCH — BEAT THE AI BROKER
## A single-file state machine: title / how-to / play / pause / settings / results.
## Everything drawn in code against a stylised North America map.

const UI = preload("res://ui_kit.gd")

enum State { TITLE, HOW_TO, PLAY, PAUSE, SETTINGS, RESULTS }

const VIEW_W := 1280.0
const VIEW_H := 720.0
const MAP_W := 860.0
const SHIFT := 180.0
const TUTORIAL_SHIFT := 45.0
const COST_PER_MILE := 1.6
const MILES_PER_PX := 2.2
const TRUCK_SPEED := 38.0
const MAX_LOADS := 7
const LOAD_LIFE := 24.0

const DIFFICULTIES := [
	{"name": "Rookie",     "think": 2.2, "max_dh": 500.0, "head_start": 10.0},
	{"name": "Dispatcher", "think": 1.4, "max_dh": 650.0, "head_start": 6.0},
	{"name": "Veteran",    "think": 0.9, "max_dh": 850.0, "head_start": 3.0},
]

const CITIES := {
	"LA":   Vector2(110, 330),
	"DEN":  Vector2(330, 250),
	"DAL":  Vector2(470, 370),
	"HOU":  Vector2(520, 430),
	"LRD":  Vector2(440, 485),
	"MTY":  Vector2(430, 540),
	"CDMX": Vector2(470, 650),
	"CHI":  Vector2(610, 190),
	"ATL":  Vector2(690, 370),
	"TOR":  Vector2(735, 125),
}
const MEXICO := ["MTY", "CDMX"]
const CANADA := ["TOR"]

# Palette — core
const BG_TOP := Color("0a1120")
const BG_BOT := Color("121d31")
const LAND := Color("1c2b40")
const LAND_EDGE := Color("2e4563")
const PANEL_BG := Color("0f1a2e")
const ACCENT := Color("5cc8ff")       # Your color (stays blue)
const AI_ORANGE := Color("ff8a3d")    # AI color (orange default)
const AI_PURPLE := Color("c38bff")    # AI color (colorblind palette)
const GOOD := Color("47d18c")
const AMBER := Color("ffb64d")
const BAD := Color("ff6b6b")

# Fonts
var font_regular: FontFile
var font_bold: FontFile
var font_tnum: FontVariation
var font_bold_tnum: FontVariation

# RNG / seed
var rng := RandomNumberGenerator.new()
var shift_seed: int = 0

# Global
var state: int = State.TITLE
var state_prev: int = State.TITLE  # for settings return
var settings: Dictionary = {}
var difficulty_ix: int = 1
var tutorial_mode: bool = false
var best: Dictionary = {}
var first_input_received: bool = false
var controls_fade_t: float = 0.0

# Gameplay
var loads: Array = []
var trucks: Array = []
var selected: int = -1
var money: Dictionary = {"you": 0.0, "ai": 0.0}
var delivered: Dictionary = {"you": 0, "ai": 0}
var miles_logged: Dictionary = {"you": 0.0, "ai": 0.0}
var revenue: Dictionary = {"you": 0.0, "ai": 0.0}
var lost_to_ai: int = 0
var lost_to_expire: int = 0
var time_left: float = SHIFT
var spawn_t: float = 0.0
var ai_t: float = 0.0
var next_id: int = 1
var over: bool = false
var feed: Array[String] = []
var sort_mode: int = 0  # 0 rate, 1 $/mi, 2 miles, 3 life
var sort_dir: int = -1  # -1 desc, 1 asc

# Tutorial scripting
var tutorial_step: int = 0
var tutorial_lane_hint: Dictionary = {}

# XAI card (why the AI picked this)
var xai_card: Dictionary = {}  # { entries: [...], life: 4.0, slide: 0..1 }

# Effects
var hit_stop_t: float = 0.0
var shake_t: float = 0.0
var shake_amp: float = 0.0
var shake_offset: Vector2 = Vector2.ZERO
var pulses: Array = []    # { pos: Vector2, t: float, color: Color }
var particles: Array = [] # { pos, vel, life, max_life, color, size }
var trails: Array = []    # drawn each frame from truck.trail

# Mouse-hover state for load row profit tooltip
var hover_row: int = -1

# Button rects for click-testing (filled during _draw)
var _buttons: Array = []  # { rect: Rect2, id: String }

# Scroll offset for how-to list
var _scroll := 0.0


# ===== lifecycle ============================================================
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rng.randomize()
	font_regular = load("res://inter.otf")
	font_bold = load("res://inter_semibold.otf")
	font_tnum = UI.tabular_variation(font_regular)
	font_bold_tnum = UI.tabular_variation(font_bold)
	settings = UI.load_settings()
	SFX.set_volume(settings.volume)
	SFX.set_muted(settings.mute)
	best = _load_best()
	_set_state(State.TITLE)


func _set_state(s: int) -> void:
	state_prev = state
	state = s
	queue_redraw()


# ===== input ================================================================
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# hover tracking (for load row tooltip)
		var m: Vector2 = event.position
		hover_row = -1
		if state == State.PLAY and not over:
			for i in range(loads.size()):
				if _row_rect(i).has_point(m):
					hover_row = i
					break
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_click(event.position)


func _handle_key(e: InputEventKey) -> void:
	if not first_input_received:
		first_input_received = true
		SFX.unlock_on_first_input()
		controls_fade_t = 3.0
	match state:
		State.TITLE:
			if e.physical_keycode == KEY_ENTER or e.physical_keycode == KEY_SPACE:
				_begin_from_title()
		State.PLAY:
			if over:
				if e.physical_keycode == KEY_ENTER:
					_set_state(State.RESULTS)
				return
			if e.physical_keycode == KEY_ESCAPE or e.physical_keycode == KEY_P:
				SFX.click()
				_set_state(State.PAUSE)
			elif e.physical_keycode in [KEY_1, KEY_2, KEY_3]:
				_try_dispatch(e.physical_keycode - KEY_1 + 1)
			elif e.physical_keycode == KEY_ENTER and tutorial_mode:
				pass
		State.PAUSE:
			if e.physical_keycode == KEY_ESCAPE or e.physical_keycode == KEY_P:
				SFX.click()
				_set_state(State.PLAY)
		State.SETTINGS:
			if e.physical_keycode == KEY_ESCAPE:
				SFX.click()
				_set_state(state_prev)
		State.HOW_TO:
			if e.physical_keycode == KEY_ESCAPE:
				SFX.click()
				_set_state(State.TITLE)
		State.RESULTS:
			if e.physical_keycode == KEY_ENTER or e.physical_keycode == KEY_SPACE:
				_set_state(State.TITLE)


func _handle_click(pos: Vector2) -> void:
	if not first_input_received:
		first_input_received = true
		SFX.unlock_on_first_input()
		controls_fade_t = 3.0
	# Pass through registered button rects for the current frame.
	for b in _buttons:
		if (b.rect as Rect2).has_point(pos):
			SFX.click()
			_on_button(b.id)
			return
	# State-specific hit tests (not button-based).
	if state == State.PLAY and not over:
		# Click load row.
		for i in range(loads.size()):
			if _row_rect(i).has_point(pos):
				var l: Dictionary = loads[i]
				selected = l.id
				SFX.click()
				return
		# Column header click → sort.
		var headers := _col_headers()
		for h in headers:
			if (h.rect as Rect2).has_point(pos):
				if sort_mode == h.mode:
					sort_dir *= -1
				else:
					sort_mode = h.mode
					sort_dir = -1
				SFX.tick()
				return
		# Click your truck.
		for t in trucks:
			if t.owner == "you" and (t.pos + shake_offset).distance_to(pos) < 18.0:
				_try_dispatch(t.num)
				return


func _on_button(id: String) -> void:
	match id:
		"play":           _begin_from_title()
		"how_to":         _set_state(State.HOW_TO)
		"settings":       _set_state(State.SETTINGS)
		"diff_0":         difficulty_ix = 0
		"diff_1":         difficulty_ix = 1
		"diff_2":         difficulty_ix = 2
		"resume":         _set_state(State.PLAY)
		"restart":        _start_shift(difficulty_ix, false, 0); _set_state(State.PLAY)
		"settings_from_pause": _set_state(State.SETTINGS)
		"quit_to_title":  _set_state(State.TITLE)
		"back":           _set_state(state_prev)
		"play_again":     _set_state(State.TITLE)
		"mute_toggle":
			settings.mute = not settings.mute
			SFX.set_muted(settings.mute); UI.save_settings(settings)
		"reduced_motion":
			settings.reduced_motion = not settings.reduced_motion
			UI.save_settings(settings)
		"colorblind":
			settings.colorblind = not settings.colorblind
			UI.save_settings(settings)
		"show_controls":
			settings.show_controls = not settings.show_controls
			UI.save_settings(settings)
		"vol_up":
			settings.volume = clampf(settings.volume + 0.1, 0.0, 1.0)
			SFX.set_volume(settings.volume); UI.save_settings(settings); SFX.click()
		"vol_down":
			settings.volume = clampf(settings.volume - 0.1, 0.0, 1.0)
			SFX.set_volume(settings.volume); UI.save_settings(settings); SFX.click()


func _begin_from_title() -> void:
	var run_tutorial: bool = not bool(best.get("tutorial_done", false))
	_start_shift(difficulty_ix, run_tutorial, 0)
	_set_state(State.PLAY)
	SFX.confirm()


# ===== shift start ==========================================================
func _start_shift(diff: int, tutorial: bool, forced_seed: int) -> void:
	difficulty_ix = diff
	tutorial_mode = tutorial
	time_left = TUTORIAL_SHIFT if tutorial else SHIFT
	loads.clear()
	trucks.clear()
	selected = -1
	money = {"you": 0.0, "ai": 0.0}
	delivered = {"you": 0, "ai": 0}
	miles_logged = {"you": 0.0, "ai": 0.0}
	revenue = {"you": 0.0, "ai": 0.0}
	lost_to_ai = 0
	lost_to_expire = 0
	spawn_t = 0.0
	ai_t = DIFFICULTIES[difficulty_ix].head_start
	next_id = 1
	over = false
	feed.clear()
	xai_card = {}
	hit_stop_t = 0.0
	shake_t = 0.0
	shake_amp = 0.0
	shake_offset = Vector2.ZERO
	pulses.clear()
	particles.clear()
	tutorial_step = 0
	tutorial_lane_hint = {}

	# Seed. In tutorial we use a deterministic one so the hint lines up.
	if forced_seed != 0:
		shift_seed = forced_seed
	else:
		shift_seed = int(Time.get_unix_time_from_system()) & 0xFFFF
	rng.seed = shift_seed

	for i in range(3):
		trucks.append(_make_truck("you", i + 1, ["HOU", "DAL", "CHI"][i]))
		trucks.append(_make_truck("ai", i + 1, ["LRD", "ATL", "DEN"][i]))

	if tutorial_mode:
		# Spawn one hand-picked load: DAL -> MTY (cross-border, high rate).
		_spawn_specific("DAL", "MTY")
		tutorial_lane_hint = loads[0]
		ai_t = 999.0  # AI holds back during tutorial
	else:
		for i in range(4):
			_spawn_load()
	_log("Shift started · %s · seed #%d" % [DIFFICULTIES[difficulty_ix].name, shift_seed])


func _make_truck(owner: String, num: int, city: String) -> Dictionary:
	return {
		"owner": owner, "num": num,
		"pos": CITIES[city], "city": city,
		"state": "idle", "load": {},
		"deadhead": 0.0,
		"trail": [],  # Vector2 points for the dashed trail (bezier samples)
		"anim_t": 0.0,
	}


# ===== load generation ======================================================
func _spawn_load() -> void:
	var names := CITIES.keys()
	var a: String = names[rng.randi() % names.size()]
	var b: String = a
	while b == a:
		b = names[rng.randi() % names.size()]
	_spawn_specific(a, b)


func _spawn_specific(a: String, b: String) -> void:
	var miles: float = CITIES[a].distance_to(CITIES[b]) * MILES_PER_PX
	var rpm: float = rng.randf_range(2.0, 3.6)
	var border: bool = (a in MEXICO) != (b in MEXICO) or (a in CANADA) != (b in CANADA)
	if border:
		rpm *= 1.25
	loads.append({
		"id": next_id,
		"from": a, "to": b,
		"miles": miles,
		"rate": roundf(miles * rpm / 10.0) * 10.0,
		"life": LOAD_LIFE, "max_life": LOAD_LIFE,
		"border": border,
	})
	next_id += 1


func _load_by_id(id: int) -> Dictionary:
	for l in loads:
		if l.id == id:
			return l
	return {}


# ===== dispatch =============================================================
func _dispatch(t: Dictionary, l: Dictionary) -> void:
	t.state = "pickup"
	t.load = l
	t.deadhead = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
	t.trail = []
	t.anim_t = 0.0
	loads.erase(l)
	if selected == l.id:
		selected = -1


func _profit(t: Dictionary, l: Dictionary) -> float:
	var dh: float = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
	return l.rate - (dh + l.miles) * COST_PER_MILE


# ===== AI broker ============================================================
func _ai_think() -> void:
	var scored: Array = []
	for t in trucks:
		if t.owner != "ai" or t.state != "idle":
			continue
		for l in loads:
			var dh: float = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
			if dh > DIFFICULTIES[difficulty_ix].max_dh:
				continue
			var total: float = dh + l.miles
			var profit: float = l.rate - total * COST_PER_MILE
			var score: float = profit / total
			if score <= 0.1:
				continue
			scored.append({"t": t, "l": l, "score": score, "profit": profit, "dh": dh})
	if scored.is_empty():
		return
	scored.sort_custom(func(a, b): return a.score > b.score)
	var best_pick: Dictionary = scored[0]
	var est: float = best_pick.profit
	_log("AI took %s>%s  est. +%s  ($%.2f/mi)" % [best_pick.l.from, best_pick.l.to, UI.money(est), best_pick.score])
	_show_xai_card(scored.slice(0, mini(3, scored.size())))
	_shake(2.0, 0.2)
	_dispatch(best_pick.t, best_pick.l)
	lost_to_ai += 1
	if settings.mute == false:
		SFX.tick()


func _show_xai_card(entries: Array) -> void:
	var out: Array = []
	for e in entries:
		out.append({
			"from": e.l.from, "to": e.l.to,
			"truck": e.t.num, "score": e.score,
			"dh": e.dh, "border": e.l.border,
		})
	xai_card = {"entries": out, "life": 4.0, "slide": 0.0}


# ===== loop =================================================================
func _process(delta: float) -> void:
	# Controls fade
	if controls_fade_t > 0.0:
		controls_fade_t = maxf(0.0, controls_fade_t - delta)

	# Camera shake decay
	if shake_t > 0.0:
		shake_t = maxf(0.0, shake_t - delta)
		var amp: float = shake_amp * (shake_t / 0.2)
		if settings.get("reduced_motion", false):
			amp = 0.0
		shake_offset = Vector2(rng.randf_range(-amp, amp), rng.randf_range(-amp, amp))
	else:
		shake_offset = Vector2.ZERO

	# Hit stop freezes sim
	var sim_delta := delta
	if hit_stop_t > 0.0:
		hit_stop_t = maxf(0.0, hit_stop_t - delta)
		sim_delta = 0.0

	# Pulses
	for i in range(pulses.size() - 1, -1, -1):
		pulses[i].t -= delta
		if pulses[i].t <= 0.0:
			pulses.remove_at(i)

	# Particles
	for i in range(particles.size() - 1, -1, -1):
		var p: Dictionary = particles[i]
		p.life -= delta
		p.pos += p.vel * delta
		p.vel.y += 120.0 * delta  # gravity
		if p.life <= 0.0:
			particles.remove_at(i)

	# XAI card lifetime / slide tween
	if not xai_card.is_empty():
		xai_card.life -= delta
		var motion_scale: float = 0.0 if settings.get("reduced_motion", false) else 1.0
		if xai_card.life > 3.75:
			xai_card.slide = clampf((4.0 - xai_card.life) / 0.25, 0.0, 1.0) * motion_scale + (1.0 - motion_scale)
		elif xai_card.life < 0.3:
			xai_card.slide = clampf(xai_card.life / 0.3, 0.0, 1.0) * motion_scale + (1.0 - motion_scale)
		else:
			xai_card.slide = 1.0
		if xai_card.life <= 0.0:
			xai_card = {}

	if state == State.PLAY and not over:
		_tick_shift(sim_delta)

	queue_redraw()


func _tick_shift(delta: float) -> void:
	time_left -= delta
	if time_left <= 0.0:
		time_left = 0.0
		over = true
		_log("Shift over.")
		if settings.get("mute", false) == false:
			SFX.success() if money.you >= money.ai else SFX.fail()
		# Auto-advance to results after a short beat.
		await get_tree().create_timer(0.9).timeout
		if over:
			_set_state(State.RESULTS)
		return

	# Load spawn (tutorial: don't spawn more)
	spawn_t -= delta
	if not tutorial_mode:
		if spawn_t <= 0.0 and loads.size() < MAX_LOADS:
			_spawn_load()
			spawn_t = rng.randf_range(2.0, 4.0)

	# Load expiry
	for l in loads.duplicate():
		l.life -= delta
		if l.life <= 0.0:
			loads.erase(l)
			lost_to_expire += 1
			if selected == l.id:
				selected = -1

	# AI
	if not tutorial_mode:
		ai_t -= delta
		if ai_t <= 0.0:
			_ai_think()
			ai_t = DIFFICULTIES[difficulty_ix].think

	# Trucks
	for t in trucks:
		_move_truck(t, delta)


func _move_truck(t: Dictionary, delta: float) -> void:
	if t.state == "idle":
		return
	var from_pt: Vector2 = t.pos
	var target: Vector2 = CITIES[t.load.from] if t.state == "pickup" else CITIES[t.load.to]
	t.pos = t.pos.move_toward(target, TRUCK_SPEED * delta)
	t.anim_t += delta
	# Record a dashed trail sample every N frames.
	if t.pos.distance_to(from_pt) > 0.0:
		if t.trail.is_empty() or t.pos.distance_to(t.trail.back()) > 6.0:
			t.trail.append(t.pos)
			if t.trail.size() > 60:
				t.trail.remove_at(0)
	if t.pos.distance_to(target) < 0.5:
		if t.state == "pickup":
			t.state = "loaded"
			t.trail = []
			_pulse(target, Color(ACCENT.r, ACCENT.g, ACCENT.b, 1.0) if t.owner == "you" else _ai_color_opaque())
		else:
			var l: Dictionary = t.load
			var profit: float = l.rate - (t.deadhead + l.miles) * COST_PER_MILE
			money[t.owner] += profit
			delivered[t.owner] += 1
			miles_logged[t.owner] += t.deadhead + l.miles
			revenue[t.owner] += l.rate
			t.city = l.to
			t.state = "idle"
			t.trail = []
			_pulse(target, GOOD if t.owner == "you" else _ai_color_opaque())
			var who := "You" if t.owner == "you" else "AI"
			var sign := "+" if profit >= 0 else "-"
			_log("%s delivered %s>%s  %s%s" % [who, l.from, l.to, sign, UI.money(absf(profit))])
			if t.owner == "you":
				_hit_stop(0.06)
				_shake(1.5, 0.14)
				_cash_burst(target)
				SFX.kaching()
				if tutorial_mode and tutorial_step < 2:
					tutorial_step = 2
			else:
				SFX.tick()
			t.load = {}


# ===== effects helpers ======================================================
func _hit_stop(dur: float) -> void:
	if settings.get("reduced_motion", false):
		return
	hit_stop_t = maxf(hit_stop_t, dur)


func _shake(amp: float, dur: float) -> void:
	if settings.get("reduced_motion", false):
		return
	shake_amp = amp
	shake_t = dur


func _pulse(pos: Vector2, color: Color) -> void:
	pulses.append({"pos": pos, "t": 0.6, "max": 0.6, "color": color})


func _cash_burst(pos: Vector2) -> void:
	if settings.get("reduced_motion", false):
		return
	for i in range(16):
		var a: float = rng.randf_range(-PI, 0.0)
		var sp: float = rng.randf_range(80.0, 180.0)
		particles.append({
			"pos": pos,
			"vel": Vector2(cos(a), sin(a)) * sp,
			"life": rng.randf_range(0.5, 0.9),
			"max_life": 0.9,
			"color": GOOD if (i % 3 != 0) else AMBER,
			"size": rng.randf_range(2.0, 4.0),
		})


func _ai_color() -> Color:
	return AI_PURPLE if settings.get("colorblind", false) else AI_ORANGE


func _ai_color_opaque() -> Color:
	var c := _ai_color()
	return Color(c.r, c.g, c.b, 1.0)


# ===== gameplay actions =====================================================
func _try_dispatch(num: int) -> void:
	if over:
		return
	var l := _load_by_id(selected)
	if l.is_empty():
		_log("Pick a load first.")
		SFX.fail()
		return
	for t in trucks:
		if t.owner == "you" and t.num == num:
			if t.state != "idle":
				_log("Truck %d is busy." % num)
				SFX.fail()
				return
			SFX.confirm()
			_log("You took %s>%s with #%d  est. +%s" % [l.from, l.to, num, UI.money(_profit(t, l))])
			_dispatch(t, l)
			if tutorial_mode and tutorial_step < 1:
				tutorial_step = 1
			return


# ===== helpers ==============================================================
func _row_rect(i: int) -> Rect2:
	return Rect2(MAP_W + 14, 118 + i * 62, VIEW_W - MAP_W - 28, 54)


func _col_headers() -> Array:
	# Four small clickable column headers above the load list.
	var y := 96.0
	var x0 := MAP_W + 14.0
	var defs := [
		{"mode": 0, "label": "RATE", "x": x0 + 180},
		{"mode": 1, "label": "$/MI", "x": x0 + 240},
		{"mode": 2, "label": "MILES", "x": x0 + 300},
		{"mode": 3, "label": "TIME", "x": x0 + 365},
	]
	var out: Array = []
	for d in defs:
		out.append({"mode": d.mode, "label": d.label, "rect": Rect2(d.x, y - 4, 55, 18)})
	return out


func _sorted_loads() -> Array:
	var arr := loads.duplicate()
	arr.sort_custom(func(a, b):
		var av: float
		var bv: float
		match sort_mode:
			0:
				av = a.rate; bv = b.rate
			1:
				av = a.rate / a.miles if a.miles > 0.0 else 0.0
				bv = b.rate / b.miles if b.miles > 0.0 else 0.0
			2:
				av = a.miles; bv = b.miles
			3:
				av = a.life; bv = b.life
			_:
				av = 0.0; bv = 0.0
		if sort_dir > 0:
			return av < bv
		return av > bv
	)
	return arr


func _log(text: String) -> void:
	feed.push_front(text)
	if feed.size() > 6:
		feed.pop_back()


func _text(pos: Vector2, s: String, size: int = UI.TYPE_BODY, color: Color = UI.INK, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, bold: bool = false, tnum: bool = false) -> void:
	var f: Font
	if bold:
		f = font_bold_tnum if tnum else font_bold
	else:
		f = font_tnum if tnum else font_regular
	draw_string(f, pos, s, align, width, size, color)


func _button(id: String, rect: Rect2, label: String, primary: bool = false, size: int = UI.TYPE_BODY) -> void:
	# Draws a translucent button, registers its hit rect for this frame.
	var fill: Color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18) if primary else UI.PANEL_FILL
	var border: Color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9) if primary else UI.PANEL_BORDER
	UI.draw_panel(self, rect, 12.0, fill, border)
	var tx: Vector2 = rect.position + Vector2(0, rect.size.y * 0.5 + size * 0.33)
	_text(tx, label, size, UI.INK, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, primary)
	_buttons.append({"rect": rect, "id": id})


# ===== best / seed ==========================================================
func _load_best() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load("user://best.cfg") != OK:
		return {"best_margin": 0.0, "best_seed": 0, "tutorial_done": false}
	return {
		"best_margin": cfg.get_value("shift", "best_margin", 0.0),
		"best_seed": cfg.get_value("shift", "best_seed", 0),
		"tutorial_done": cfg.get_value("shift", "tutorial_done", false),
	}


func _save_best(margin: float, seed_val: int, tut_done: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("shift", "best_margin", margin)
	cfg.set_value("shift", "best_seed", seed_val)
	cfg.set_value("shift", "tutorial_done", tut_done)
	cfg.save("user://best.cfg")


func _star_grade(margin: float) -> int:
	if margin > 2000.0:
		return 3
	if margin > 0.0:
		return 2
	return 1


# ===== DRAW =================================================================
func _draw() -> void:
	_buttons.clear()
	# Background gradient
	for y in range(0, int(VIEW_H), 4):
		var t: float = float(y) / VIEW_H
		var c: Color = BG_TOP.lerp(BG_BOT, t)
		draw_rect(Rect2(0, y, VIEW_W, 4), c)
	match state:
		State.TITLE:    _draw_map(true); _draw_title()
		State.HOW_TO:   _draw_map(true); _draw_how_to()
		State.PLAY:     _draw_map(false); _draw_right_panel(); _draw_hover_tooltip(); _draw_xai_card(); _draw_controls_hint(); _draw_tutorial_overlay()
		State.PAUSE:    _draw_map(false); _draw_right_panel(); _draw_pause()
		State.SETTINGS: _draw_map(true); _draw_settings()
		State.RESULTS:  _draw_map(true); _draw_results()


# ---- map -------------------------------------------------------------------
func _draw_map(dim: bool) -> void:
	var land := PackedVector2Array([
		Vector2(60, 60), Vector2(820, 50), Vector2(840, 160), Vector2(760, 230), Vector2(760, 330),
		Vector2(700, 440), Vector2(600, 470), Vector2(540, 470), Vector2(520, 560), Vector2(560, 640),
		Vector2(520, 700), Vector2(420, 690), Vector2(380, 580), Vector2(300, 470), Vector2(200, 430),
		Vector2(80, 380), Vector2(60, 240),
	])
	# Shaded land polygon
	draw_colored_polygon(land, LAND)
	var edge := land.duplicate()
	edge.append(land[0])
	draw_polyline(edge, LAND_EDGE, 2)
	# Borders
	draw_dashed_line(Vector2(80, 380), Vector2(540, 470), UI.DIM, 1.5, 8)
	draw_dashed_line(Vector2(560, 160), Vector2(840, 160), UI.DIM, 1.5, 8)

	# City dots
	for name in CITIES:
		var p: Vector2 = CITIES[name]
		draw_circle(p, 7, LAND_EDGE)
		draw_circle(p, 4, UI.INK)
		_text(p + Vector2(10, -8), name, UI.TYPE_CAPTION, UI.MUTED)

	if dim:
		# Darken whole viewport so title/results overlays read cleanly.
		draw_rect(Rect2(0, 0, VIEW_W, VIEW_H), Color(0, 0, 0, 0.55))

	if state != State.PLAY and state != State.PAUSE:
		return

	# Selected load lane preview
	var l_sel := _load_by_id(selected)
	if not l_sel.is_empty():
		_draw_curve(CITIES[l_sel.from], CITIES[l_sel.to], GOOD, 3.5, false)
		for t in trucks:
			if t.owner == "you" and t.state == "idle":
				draw_dashed_line(t.pos + shake_offset, CITIES[l_sel.from], Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.6), 2, 6)
				var mid: Vector2 = (t.pos + CITIES[l_sel.from]) / 2
				var dh_mi: float = t.pos.distance_to(CITIES[l_sel.from]) * MILES_PER_PX
				_text(mid + Vector2(6, -6), "#%d · %s mi dh" % [t.num, UI.money(dh_mi).lstrip("$")], UI.TYPE_CAPTION, ACCENT)

	# Active truck curves
	for t in trucks:
		if t.state == "idle":
			continue
		var c: Color = ACCENT if t.owner == "you" else _ai_color_opaque()
		var target: Vector2 = CITIES[t.load.from] if t.state == "pickup" else CITIES[t.load.to]
		_draw_curve(t.pos, target, Color(c.r, c.g, c.b, 0.4), 2.0, true)
		# Trail (dashed)
		if t.trail.size() > 1:
			var pts := PackedVector2Array(t.trail)
			draw_polyline(pts, Color(c.r, c.g, c.b, 0.55), 2.0, true)

	# Pulses
	for p in pulses:
		var frac: float = 1.0 - (p.t / p.max)
		var r: float = 6.0 + frac * 28.0
		var a: float = 1.0 - frac
		UI.draw_ring_bg(self, p.pos, r, Color(p.color.r, p.color.g, p.color.b, a), 2.0)

	# Trucks
	for t in trucks:
		var c: Color = ACCENT if t.owner == "you" else _ai_color_opaque()
		var off: Vector2 = shake_offset if t.owner == "ai" else Vector2.ZERO
		var pos: Vector2 = t.pos + off
		# Rounded truck rect
		UI.draw_panel(self, Rect2(pos - Vector2(14, 10), Vector2(28, 20)), 5.0, c, Color(c.r, c.g, c.b, 1.0))
		if t.state == "loaded":
			# Container indicator
			draw_rect(Rect2(pos - Vector2(10, 7), Vector2(20, 14)), UI.INK, false, 1.5)
		var label: String = str(t.num) if t.owner == "you" else "AI"
		_text(pos + Vector2(-14, 4), label, UI.TYPE_CAPTION, BG_TOP, HORIZONTAL_ALIGNMENT_CENTER, 28, true, true)

	# Particles
	for p in particles:
		var a: float = clampf(p.life / p.max_life, 0.0, 1.0)
		draw_circle(p.pos, p.size, Color(p.color.r, p.color.g, p.color.b, a))


func _draw_curve(a: Vector2, b: Vector2, color: Color, width: float, dashed: bool) -> void:
	# Quadratic bezier with a slight perpendicular offset for a city-to-city arc.
	var mid: Vector2 = (a + b) * 0.5
	var dir: Vector2 = (b - a)
	var perp: Vector2 = Vector2(-dir.y, dir.x).normalized()
	var arc: float = minf(dir.length() * 0.18, 60.0)
	var ctrl: Vector2 = mid + perp * arc
	var steps := 24
	var pts := PackedVector2Array()
	for i in range(steps + 1):
		var t: float = float(i) / steps
		var p: Vector2 = (1 - t) * (1 - t) * a + 2 * (1 - t) * t * ctrl + t * t * b
		pts.append(p)
	if dashed:
		for i in range(0, pts.size() - 1, 2):
			draw_line(pts[i], pts[i + 1], color, width, true)
	else:
		draw_polyline(pts, color, width, true)


# ---- right panel (gameplay HUD + load board) --------------------------------
func _draw_right_panel() -> void:
	draw_rect(Rect2(MAP_W, 0, VIEW_W - MAP_W, VIEW_H), PANEL_BG)
	# HUD numbers (big)
	var y0 := 20.0
	_text(Vector2(MAP_W + 16, y0 + 36), UI.mmss(time_left), UI.TYPE_HUD, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(MAP_W + 16, y0 + 56), "SHIFT", UI.TYPE_CAPTION, UI.MUTED)
	# You / AI
	var x1 := MAP_W + 160.0
	_text(Vector2(x1, y0 + 14), "YOU", UI.TYPE_CAPTION, ACCENT, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(x1, y0 + 36), UI.money(money.you), UI.TYPE_HEADLINE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(x1, y0 + 56), "%d loads" % delivered.you, UI.TYPE_CAPTION, UI.MUTED)
	var x2 := MAP_W + 280.0
	_text(Vector2(x2, y0 + 14), "AI", UI.TYPE_CAPTION, _ai_color(), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(x2, y0 + 36), UI.money(money.ai), UI.TYPE_HEADLINE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(x2, y0 + 56), "%d loads" % delivered.ai, UI.TYPE_CAPTION, UI.MUTED)

	# Column headers
	_text(Vector2(MAP_W + 16, 96), "LOAD BOARD", UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for h in _col_headers():
		var active: bool = sort_mode == h.mode
		var col: Color = ACCENT if active else UI.MUTED
		_text(h.rect.position + Vector2(0, 12), h.label + ("↓" if active and sort_dir < 0 else "↑" if active else ""), UI.TYPE_CAPTION, col, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		_buttons.append({"rect": h.rect, "id": "sort_%d" % h.mode})  # not routed through _on_button; click handler reads sort_mode directly

	# Rows (sorted view)
	var sorted := _sorted_loads()
	for i in range(sorted.size()):
		var l: Dictionary = sorted[i]
		var r: Rect2 = _row_rect(i)
		var is_sel: bool = l.id == selected
		var is_hover: bool = hover_row == i
		var fill: Color = UI.PANEL_FILL
		if is_sel:
			fill = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18)
		elif is_hover:
			fill = Color(1, 1, 1, 0.10)
		UI.draw_panel(self, r, 10.0, fill, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9) if is_sel else UI.PANEL_BORDER)
		# Lane + badges
		_text(r.position + Vector2(14, 20), "%s > %s" % [l.from, l.to], UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		var bx: float = r.position.x + 14 + 110
		if l.border:
			_badge(Rect2(bx, r.position.y + 7, 92, 15), "CROSS-BORDER", GOOD)
			bx += 100
		if l.life < LOAD_LIFE * 0.30:
			_badge(Rect2(bx, r.position.y + 7, 44, 15), "HOT", BAD)
			bx += 50
		# $/mi color-graded
		var dpm: float = l.rate / l.miles if l.miles > 0.0 else 0.0
		var dpm_color: Color = BAD
		if dpm >= 2.6:
			dpm_color = GOOD
		elif dpm >= 2.0:
			dpm_color = AMBER
		_text(r.position + Vector2(14, 42), "%s · %s mi" % [UI.money(l.rate), str(int(round(l.miles)))], UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)
		_text(r.position + Vector2(170, 42), "$%.2f/mi" % dpm, UI.TYPE_CAPTION, dpm_color, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
		# Timer ring at the right edge
		var center: Vector2 = r.position + Vector2(r.size.x - 24, r.size.y * 0.5)
		var frac: float = clampf(l.life / l.max_life, 0.0, 1.0)
		UI.draw_ring_bg(self, center, 12.0, Color(1, 1, 1, 0.10), 2.5)
		var ring_col: Color = GOOD
		if frac < 0.3:
			ring_col = BAD
		elif frac < 0.6:
			ring_col = AMBER
		UI.draw_ring(self, center, 12.0, frac, ring_col, 2.5)
		_text(center + Vector2(-7, 4), str(int(ceil(l.life))), UI.TYPE_CAPTION, ring_col, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
		# Long-deadhead badge for your nearest idle truck
		var nearest_dh: float = _nearest_your_truck_dh(l)
		if nearest_dh > 400.0:
			_badge(Rect2(bx, r.position.y + 7, 88, 15), "LONG DEADHEAD", AMBER)

	# Activity feed
	var y := 540.0
	_text(Vector2(MAP_W + 16, y), "ACTIVITY", UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(feed.size()):
		var c: Color = UI.INK
		if feed[i].begins_with("AI"):
			c = _ai_color()
		elif feed[i].begins_with("You"):
			c = ACCENT
		_text(Vector2(MAP_W + 16, y + 22 + i * 20), feed[i], UI.TYPE_CAPTION, Color(c.r, c.g, c.b, 1.0 - i * 0.14), HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)


func _nearest_your_truck_dh(l: Dictionary) -> float:
	var best_dh: float = INF
	for t in trucks:
		if t.owner == "you" and t.state == "idle":
			var dh: float = t.pos.distance_to(CITIES[l.from]) * MILES_PER_PX
			if dh < best_dh:
				best_dh = dh
	return 0.0 if best_dh == INF else best_dh


func _badge(rect: Rect2, text: String, color: Color) -> void:
	UI.draw_panel(self, rect, 4.0, Color(color.r, color.g, color.b, 0.18), Color(color.r, color.g, color.b, 0.9))
	_text(rect.position + Vector2(0, rect.size.y - 3), text, UI.TYPE_CAPTION - 1, color, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, true)


# ---- hover tooltip ---------------------------------------------------------
func _draw_hover_tooltip() -> void:
	if hover_row < 0 or hover_row >= loads.size():
		return
	var sorted := _sorted_loads()
	if hover_row >= sorted.size():
		return
	var l: Dictionary = sorted[hover_row]
	var r := Rect2(MAP_W - 220, _row_rect(hover_row).position.y + 4, 200, 90)
	UI.draw_panel(self, r)
	_text(r.position + Vector2(12, 22), "Profit per truck", UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var row_y: float = r.position.y + 42
	for t in trucks:
		if t.owner != "you":
			continue
		var busy: bool = t.state != "idle"
		var pr: float = _profit(t, l)
		var col: Color = UI.MUTED if busy else (GOOD if pr >= 0 else BAD)
		var label: String = "#%d busy" % t.num if busy else "#%d  %s" % [t.num, UI.money(pr)]
		_text(Vector2(r.position.x + 12, row_y), label, UI.TYPE_CAPTION, col, HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)
		row_y += 16


# ---- XAI card --------------------------------------------------------------
func _draw_xai_card() -> void:
	if xai_card.is_empty():
		return
	var w := 300.0
	var h := 150.0
	var x_target := MAP_W - w - 20
	var x: float = MAP_W + 20
	if settings.get("reduced_motion", false):
		x = x_target
	else:
		x = lerp(float(MAP_W + 20), float(x_target), xai_card.slide)
	var y := VIEW_H - h - 24
	var r := Rect2(x, y, w, h)
	UI.draw_card(self, r, _ai_color())
	_text(r.position + Vector2(16, 22), "WHY THE AI PICKED THIS", UI.TYPE_CAPTION, _ai_color(), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var yy: float = r.position.y + 44
	for i in range(xai_card.entries.size()):
		var e: Dictionary = xai_card.entries[i]
		var tag := "#%d  %s>%s" % [e.truck, e.from, e.to]
		_text(Vector2(r.position.x + 16, yy), tag, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, (i == 0), true)
		var reasons := "profit/mi %.2f · deadhead %s mi" % [e.score, str(int(round(e.dh)))]
		if e.border:
			reasons += " · cross-border +25%"
		_text(Vector2(r.position.x + 16, yy + 16), reasons, UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)
		yy += 34


# ---- controls hint chips ---------------------------------------------------
func _draw_controls_hint() -> void:
	if not settings.get("show_controls", true):
		return
	var alpha := 1.0
	if first_input_received:
		alpha = clampf(controls_fade_t / 3.0, 0.0, 1.0)
	if alpha <= 0.0:
		return
	var y := VIEW_H - 36
	var chips := [
		"Click load",
		"1 / 2 / 3 dispatch",
		"Esc pause",
	]
	var x: float = 20.0
	for c in chips:
		var w: float = font_regular.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.TYPE_CAPTION).x + 20
		var r := Rect2(x, y, w, 22)
		UI.draw_panel(self, r, 10.0, Color(1, 1, 1, 0.08 * alpha), Color(1, 1, 1, 0.15 * alpha))
		_text(Vector2(x + 10, y + 15), c, UI.TYPE_CAPTION, Color(UI.INK.r, UI.INK.g, UI.INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		x += w + 8


# ---- tutorial overlay ------------------------------------------------------
func _draw_tutorial_overlay() -> void:
	if not tutorial_mode:
		return
	# Prompt chips depending on step.
	var msg := ""
	match tutorial_step:
		0:
			msg = "Click the %s>%s load on the right." % [tutorial_lane_hint.from, tutorial_lane_hint.to]
		1:
			msg = "Dispatch a truck. Click one of your blue trucks, or press 1, 2, or 3."
		2:
			msg = "Nice. Full shift unlocks when the timer runs out."
	if msg == "":
		return
	var w := 480.0
	var r := Rect2(VIEW_W * 0.5 - w * 0.5, 40, w, 40)
	UI.draw_panel(self, r, 10.0, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9))
	_text(Vector2(r.position.x, r.position.y + 26), msg, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_CENTER, w, true)
	# Highlight the hinted row with a halo ring.
	if tutorial_step == 0:
		for i in range(loads.size()):
			if loads[i].id == tutorial_lane_hint.id:
				var row := _row_rect(i)
				var cx: float = row.position.x + row.size.x * 0.5
				var cy: float = row.position.y + row.size.y * 0.5
				var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() / 300.0)
				UI.draw_panel(self, row.grow(4), 12.0, Color(1, 1, 1, 0.0), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.4 + 0.5 * pulse))
	elif tutorial_step == 1:
		for t in trucks:
			if t.owner == "you" and t.state == "idle":
				var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() / 240.0)
				UI.draw_ring_bg(self, t.pos, 20.0 + 4.0 * pulse, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.5 + 0.3 * pulse), 2.0)


# ---- title ----------------------------------------------------------------
func _draw_title() -> void:
	# Hero card
	var card := Rect2(80, 90, 540, 420)
	UI.draw_card(self, card, ACCENT)
	_text(card.position + Vector2(24, 56), "DISPATCH", UI.TYPE_TITLE + 10, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(card.position + Vector2(24, 86), "Beat the utility-AI broker in a 3-min shift.", UI.TYPE_BODY, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, false, false)

	# Difficulty select
	_text(card.position + Vector2(24, 130), "DIFFICULTY", UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(DIFFICULTIES.size()):
		var r := Rect2(card.position.x + 24 + i * 160, card.position.y + 150, 150, 50)
		var fill: Color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18) if i == difficulty_ix else UI.PANEL_FILL
		var bor: Color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9) if i == difficulty_ix else UI.PANEL_BORDER
		UI.draw_panel(self, r, 10.0, fill, bor)
		_text(r.position + Vector2(0, 22), DIFFICULTIES[i].name, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, i == difficulty_ix)
		_text(r.position + Vector2(0, 40), "think %.1fs" % DIFFICULTIES[i].think, UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		_buttons.append({"rect": r, "id": "diff_%d" % i})

	# Primary buttons
	var by: float = card.position.y + 230
	_button("play", Rect2(card.position.x + 24, by, 220, 54), "Play Shift", true, UI.TYPE_HEADLINE)
	_button("how_to", Rect2(card.position.x + 260, by, 160, 54), "How to play")
	_button("settings", Rect2(card.position.x + 24, by + 72, 160, 44), "Settings")

	# Best shift line
	if best.get("best_margin", 0.0) > 0.0:
		_text(card.position + Vector2(24, 380), "Best shift margin · %s · seed #%d" % [UI.money(best.best_margin), best.best_seed], UI.TYPE_CAPTION, UI.MUTED)

	# Right-side info card
	var info := Rect2(680, 90, 520, 420)
	UI.draw_panel(self, info)
	_text(info.position + Vector2(24, 36), "WHAT THIS SHOWS", UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var bullets := [
		"Utility-AI broker scoring every (truck, load) pair in real time.",
		"XAI card: top 3 scores with reasons on every AI pick.",
		"TMS load board: sortable rows, timer rings, graded $/mi.",
		"Procedural audio and particles. No imported assets.",
	]
	var yy: float = info.position.y + 70
	for b in bullets:
		_text(Vector2(info.position.x + 24, yy), "·  " + b, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, info.size.x - 48)
		yy += 28


# ---- how to ----------------------------------------------------------------
func _draw_how_to() -> void:
	var r := Rect2(240, 100, 800, 500)
	UI.draw_card(self, r, ACCENT)
	_text(r.position + Vector2(28, 50), "HOW TO PLAY", UI.TYPE_TITLE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	var lines := [
		"Loads pop onto the board. Each shows rate, miles and $/mi.",
		"Click a load, then click one of your blue trucks (or press 1, 2, 3).",
		"The AI broker is scoring the same loads. Veteran AI thinks every 0.9s.",
		"Cross-border loads pay 25% more. Deadhead miles eat profit.",
		"Shift lasts 3 minutes. Most money wins. Loss gets 1 star, +$2k gets 3.",
		"Esc or P pauses. Settings include reduced motion and colorblind palette.",
	]
	var yy: float = r.position.y + 100
	for l in lines:
		_text(Vector2(r.position.x + 28, yy), "·  " + l, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 56)
		yy += 32
	_button("back", Rect2(r.position.x + r.size.x - 180, r.position.y + r.size.y - 70, 140, 44), "Back")


# ---- pause -----------------------------------------------------------------
func _draw_pause() -> void:
	draw_rect(Rect2(0, 0, VIEW_W, VIEW_H), Color(0, 0, 0, 0.45))
	var r := Rect2(VIEW_W * 0.5 - 180, 180, 360, 340)
	UI.draw_card(self, r, ACCENT)
	_text(r.position + Vector2(0, 60), "PAUSED", UI.TYPE_TITLE, UI.INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_button("resume",   Rect2(r.position.x + 40, r.position.y + 100, r.size.x - 80, 44), "Resume", true)
	_button("restart",  Rect2(r.position.x + 40, r.position.y + 150, r.size.x - 80, 44), "Restart shift")
	_button("settings_from_pause", Rect2(r.position.x + 40, r.position.y + 200, r.size.x - 80, 44), "Settings")
	_button("quit_to_title", Rect2(r.position.x + 40, r.position.y + 250, r.size.x - 80, 44), "Quit to title")


# ---- settings --------------------------------------------------------------
func _draw_settings() -> void:
	var r := Rect2(360, 110, 560, 480)
	UI.draw_card(self, r, ACCENT)
	_text(r.position + Vector2(28, 50), "SETTINGS", UI.TYPE_TITLE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	# Volume slider (buttons + bar)
	_text(r.position + Vector2(28, 110), "Volume", UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_button("vol_down", Rect2(r.position.x + 28, r.position.y + 125, 34, 32), "−")
	_button("vol_up",   Rect2(r.position.x + 68, r.position.y + 125, 34, 32), "+")
	var bar := Rect2(r.position.x + 118, r.position.y + 136, 300, 10)
	UI.draw_panel(self, bar, 5.0, Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.14))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * settings.volume, bar.size.y)), ACCENT)
	_text(Vector2(r.position.x + 428, r.position.y + 148), "%d%%" % int(settings.volume * 100), UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_toggle_button("mute_toggle",     r.position + Vector2(28, 180), "Mute all audio", settings.mute)
	_toggle_button("reduced_motion",  r.position + Vector2(28, 230), "Reduced motion", settings.reduced_motion)
	_toggle_button("colorblind",      r.position + Vector2(28, 280), "Colorblind palette (AI → purple)", settings.colorblind)
	_toggle_button("show_controls",   r.position + Vector2(28, 330), "Show on-screen controls", settings.show_controls)

	_button("back", Rect2(r.position.x + r.size.x - 150, r.position.y + r.size.y - 70, 120, 44), "Back")


func _toggle_button(id: String, pos: Vector2, label: String, on: bool) -> void:
	var r := Rect2(pos, Vector2(500, 36))
	UI.draw_panel(self, r, 10.0, UI.PANEL_FILL, UI.PANEL_BORDER)
	var knob := Rect2(r.position + Vector2(r.size.x - 56, 6), Vector2(42, 24))
	UI.draw_panel(self, knob, 12.0, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9) if on else Color(1, 1, 1, 0.10), UI.PANEL_BORDER)
	draw_circle(knob.position + Vector2(30 if on else 12, 12), 9, UI.INK)
	_text(r.position + Vector2(16, 23), label, UI.TYPE_BODY, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, false)
	_buttons.append({"rect": r, "id": id})


# ---- results ---------------------------------------------------------------
func _draw_results() -> void:
	var won: bool = money.you > money.ai
	var margin: float = money.you - money.ai
	var stars: int = _star_grade(margin)
	# Persist best if we beat it (full shifts only).
	if not tutorial_mode and margin > best.get("best_margin", 0.0):
		best.best_margin = margin
		best.best_seed = shift_seed
		_save_best(best.best_margin, best.best_seed, true)
	# Mark tutorial done.
	if tutorial_mode and not best.get("tutorial_done", false):
		best.tutorial_done = true
		_save_best(best.get("best_margin", 0.0), best.get("best_seed", 0), true)

	var r := Rect2(260, 80, 760, 560)
	UI.draw_card(self, r, GOOD if won else _ai_color())
	var title: String = "YOU BEAT THE AI BROKER" if won else "AI BROKER WINS THIS SHIFT"
	if margin == 0.0:
		title = "DEAD HEAT"
	_text(r.position + Vector2(0, 72), title, UI.TYPE_TITLE + 6, UI.INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	# Stars
	var sx: float = r.position.x + r.size.x * 0.5 - 60
	for i in range(3):
		var filled: bool = i < stars
		var col: Color = AMBER if filled else UI.DIM
		_draw_star(Vector2(sx + i * 50, r.position.y + 110), 18.0, col, filled)
	# Two columns: you / ai
	var your_dpm: float = revenue.you / miles_logged.you if miles_logged.you > 0.0 else 0.0
	var ai_dpm: float = revenue.ai / miles_logged.ai if miles_logged.ai > 0.0 else 0.0
	var cy := r.position.y + 160
	_text(Vector2(r.position.x + 60, cy), "YOU", UI.TYPE_HEADLINE, ACCENT, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(r.position.x + 60, cy + 32), UI.money(money.you), UI.TYPE_TITLE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(r.position.x + 60, cy + 58), "%d loads · $%.2f/mi" % [delivered.you, your_dpm], UI.TYPE_BODY, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)
	_text(Vector2(r.position.x + 60, cy + 80), "lost %d to AI · %d expired" % [lost_to_ai, lost_to_expire], UI.TYPE_CAPTION, UI.MUTED)

	_text(Vector2(r.position.x + 420, cy), "AI", UI.TYPE_HEADLINE, _ai_color(), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(r.position.x + 420, cy + 32), UI.money(money.ai), UI.TYPE_TITLE, UI.INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(r.position.x + 420, cy + 58), "%d loads · $%.2f/mi" % [delivered.ai, ai_dpm], UI.TYPE_BODY, UI.MUTED, HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)

	# Margin
	_text(Vector2(r.position.x, cy + 150), "Margin  " + (("+" if margin > 0 else "") + UI.money(margin)), UI.TYPE_HEADLINE, GOOD if margin > 0 else BAD, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_text(Vector2(r.position.x, cy + 190), "Shift #%d · share this seed" % shift_seed, UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	if best.get("best_margin", 0.0) > 0.0:
		_text(Vector2(r.position.x, cy + 212), "Best so far · %s · seed #%d" % [UI.money(best.best_margin), best.best_seed], UI.TYPE_CAPTION, UI.MUTED, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# Buttons
	_button("restart", Rect2(r.position.x + r.size.x * 0.5 - 230, r.position.y + r.size.y - 86, 200, 50), "Run another shift", true)
	_button("play_again", Rect2(r.position.x + r.size.x * 0.5 + 30, r.position.y + r.size.y - 86, 200, 50), "Back to title")


func _draw_star(center: Vector2, r: float, color: Color, filled: bool) -> void:
	var pts := PackedVector2Array()
	for i in range(10):
		var a: float = -PI / 2.0 + i * PI / 5.0
		var rr: float = r if i % 2 == 0 else r * 0.45
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	if filled:
		draw_colored_polygon(pts, color)
	else:
		pts.append(pts[0])
		draw_polyline(pts, color, 1.5, true)
