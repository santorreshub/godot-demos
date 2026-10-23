extends Node2D
## ŌLLAMALIZTLI — 1v1 arena.
## Two Mesoamerican ball players, one rubber ball, two goals. Hip strikes,
## head bumps, air dashes. First to N scores. 1P vs AI or 2P local.

const UI = preload("res://ui_kit.gd")

enum State { TITLE, HOW_TO, PLAY, PAUSE, SETTINGS, RESULTS }
enum Phase { SERVE, PLAY, GOAL, MATCH_END }

const W := 1280.0
const H := 720.0
const FLOOR_Y := 640.0
const BALL_R := 18.0

const MOVE_SPEED := 420.0
const JUMP_V := -660.0
const DASH_SPEED := 920.0
const DASH_DURATION := 0.16
const DASH_CD := 0.35
const DASH_MAX_CHARGES := 3
const DASH_REGEN := 1.6  # seconds per charge
const STRIKE_WINDOW := 0.11
const HIP_COOLDOWN := 0.22
const HIT_STOP := 0.045
const SLOW_MO_GOAL := 0.6

const GOAL_LEFT_X := 70.0     # ball x < this inside the mouth = P2 scores
const GOAL_RIGHT_X := W - 70.0
const GOAL_TOP_Y := FLOOR_Y - 220.0
const GOAL_BOTTOM_Y := FLOOR_Y - 10.0

const MODES := [
	{"name": "Pickup", "goals": 3, "ball_g": 1500.0, "subtitle": "first to 3"},
	{"name": "Match",  "goals": 5, "ball_g": 1700.0, "subtitle": "first to 5"},
	{"name": "Legend", "goals": 7, "ball_g": 1900.0, "subtitle": "first to 7 · fast ball"},
]

# Palette — dusk over the court
const SKY_TOP := Color("1a1a38")
const SKY_BOTTOM := Color("c86b48")
const SUN := Color("ffcf5c")
const STONE := Color("b9a07e")
const STONE_DARK := Color("6a5540")
const PLASTER := Color("c9b494")
const JADE := Color("2fb38a")
const JADE_CB := Color("5cc8ff")
const GOLD := Color("f2b632")
const SKIN := Color("8a5a3c")
const RUBBER := Color("2a2220")
const INK := Color("fff3d6")

# P1 jaguar warrior, P2 eagle warrior — primary + accent per player.
const P1_PRIMARY := Color("2fb38a")   # jade
const P1_ACCENT  := Color("f2b632")   # gold
const P2_PRIMARY := Color("c43b3b")   # red
const P2_ACCENT  := Color("f0e3b8")   # bone

# Fonts
var font_regular: FontFile
var font_bold: FontFile
var font_tnum: FontVariation
var font_bold_tnum: FontVariation

# Settings + state
var settings: Dictionary = {}
var state: int = State.TITLE
var state_prev: int = State.TITLE
var mode_ix: int = 1
var two_player: bool = true
var best_cfg: Dictionary = {}
var first_input_received: bool = false
var controls_fade_t: float = 0.0
var _buttons: Array = []
var mouse_pos: Vector2 = Vector2(-1000, -1000)

# Scene nodes
var floor_body: StaticBody2D
var ball: RigidBody2D
var cam: Camera2D
var ui_layer: CanvasLayer
var goal_left_zone: Area2D
var goal_right_zone: Area2D

# Players: Array of Dictionaries. See _make_player().
var players: Array = []

# Match
var scores: Array[int] = [0, 0]
var phase: int = Phase.SERVE
var phase_t: float = 0.0
var match_time: float = 0.0
var winner_ix: int = -1
var round_number: int = 1
var longest_rally: int = 0
var rally: int = 0

# Visuals + juice
var rng := RandomNumberGenerator.new()
var shake := 0.0
var shake_t := 0.0
var slow_mo_t := 0.0
var hit_stop_t := 0.0
var cam_zoom_t := 1.0
var cam_zoom_target := 1.0
var ball_trail: Array = []  # Array[Vector2]
var _ball_squash := 0.0
var bursts: Array = []  # {pos, vel, life, max_life, color, size}
var stars_near: Array = []
var stars_far: Array = []
var star_drift := 0.0
var torch_seed := [0.0, 0.0]
var banner_text := ""
var banner_t := 0.0
var banner_color := INK

# Cancelable finish
var finish_timer_id := 0


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
	_setup_input()
	best_cfg = _load_best()
	mode_ix = int(best_cfg.get("last_mode", 1))
	two_player = bool(best_cfg.get("two_player", true))

	# Starfield two depths
	var r := RandomNumberGenerator.new()
	r.seed = 2026
	for i in range(60):
		stars_far.append(Vector2(r.randf() * W, r.randf() * 240))
	for i in range(40):
		stars_near.append(Vector2(r.randf() * W, r.randf() * 260))
	torch_seed = [r.randf() * 100.0, r.randf() * 100.0]

	_build_world()
	_build_players()
	_set_state(State.TITLE)


func _setup_input() -> void:
	# P1 — left side (jaguar). P2 — right side (eagle).
	var map := {
		"p1_left":   [KEY_A],
		"p1_right":  [KEY_D],
		"p1_jump":   [KEY_W],
		"p1_dash":   [KEY_S],
		"p1_strike": [KEY_SPACE],
		"p2_left":   [KEY_LEFT],
		"p2_right":  [KEY_RIGHT],
		"p2_jump":   [KEY_UP],
		"p2_dash":   [KEY_DOWN],
		"p2_strike": [KEY_ENTER, KEY_KP_ENTER],
		"pause":     [KEY_ESCAPE, KEY_P],
		"ui_restart":[KEY_R],
	}
	for action in map:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


func _set_state(s: int) -> void:
	state_prev = state
	state = s
	get_tree().paused = (s != State.PLAY)
	queue_redraw()


# ===== build ================================================================
func _static_poly(points: PackedVector2Array) -> StaticBody2D:
	var body := StaticBody2D.new()
	var cp := CollisionPolygon2D.new()
	cp.polygon = points
	body.add_child(cp)
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.5
	pm.friction = 0.3
	body.physics_material_override = pm
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	return body


# Wall shape — a slope that rises from the goal mouth to the top.
# Keeps the goal opening clear at the bottom and seals the top.
func _left_wall_shape() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(-200, -400),
		Vector2(60, -400),
		Vector2(60, GOAL_TOP_Y),
		Vector2(10, GOAL_TOP_Y + 20),
		Vector2(-200, GOAL_TOP_Y + 20),
	])


func _right_wall_shape() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _left_wall_shape():
		out.append(Vector2(W - p.x, p.y))
	return out


# Short posts under each goal mouth so the ball doesn't just roll out onto the
# floor and sit in the mouth — it has to actually enter.
func _left_post_shape() -> PackedVector2Array:
	# A small lip at the goal line to the floor
	return PackedVector2Array([
		Vector2(60, FLOOR_Y - 8),
		Vector2(72, FLOOR_Y - 8),
		Vector2(72, FLOOR_Y),
		Vector2(60, FLOOR_Y),
	])


func _right_post_shape() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _left_post_shape():
		out.append(Vector2(W - p.x, p.y))
	return out


func _build_world() -> void:
	floor_body = _static_poly(PackedVector2Array([
		Vector2(-200, FLOOR_Y), Vector2(W + 200, FLOOR_Y),
		Vector2(W + 200, H + 200), Vector2(-200, H + 200),
	]))
	_static_poly(_left_wall_shape())
	_static_poly(_right_wall_shape())
	# Ceiling
	_static_poly(PackedVector2Array([
		Vector2(-200, -420), Vector2(W + 200, -420),
		Vector2(W + 200, -400), Vector2(-200, -400),
	]))
	# Little floor lips at the goal mouths
	_static_poly(_left_post_shape())
	_static_poly(_right_post_shape())

	# Goal detect zones — invisible areas inside each goal mouth
	goal_left_zone = Area2D.new()
	var lgs := CollisionShape2D.new()
	var lgr := RectangleShape2D.new()
	lgr.size = Vector2(44, GOAL_BOTTOM_Y - GOAL_TOP_Y - 10)
	lgs.shape = lgr
	goal_left_zone.add_child(lgs)
	goal_left_zone.position = Vector2(30, (GOAL_TOP_Y + GOAL_BOTTOM_Y) * 0.5)
	goal_left_zone.collision_layer = 0
	goal_left_zone.collision_mask = 4
	goal_left_zone.body_entered.connect(func(b): _on_goal(b, 1))
	add_child(goal_left_zone)

	goal_right_zone = Area2D.new()
	var rgs := CollisionShape2D.new()
	var rgr := RectangleShape2D.new()
	rgr.size = Vector2(44, GOAL_BOTTOM_Y - GOAL_TOP_Y - 10)
	rgs.shape = rgr
	goal_right_zone.add_child(rgs)
	goal_right_zone.position = Vector2(W - 30, (GOAL_TOP_Y + GOAL_BOTTOM_Y) * 0.5)
	goal_right_zone.collision_layer = 0
	goal_right_zone.collision_mask = 4
	goal_right_zone.body_entered.connect(func(b): _on_goal(b, 0))
	add_child(goal_right_zone)

	# Ball
	ball = RigidBody2D.new()
	ball.collision_layer = 4
	ball.collision_mask = 1  # walls/floor only; players use Area2D hip, not body collision
	ball.mass = 1.0
	ball.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	var bpm := PhysicsMaterial.new()
	bpm.bounce = 0.74
	bpm.friction = 0.2
	ball.physics_material_override = bpm
	var bcs := CollisionShape2D.new()
	var bc := CircleShape2D.new()
	bc.radius = BALL_R
	bcs.shape = bc
	ball.add_child(bcs)
	ball.position = Vector2(W * 0.5, 320)
	ball.freeze = true
	add_child(ball)

	# Camera
	cam = Camera2D.new()
	cam.position = Vector2(W / 2, H / 2)
	cam.zoom = Vector2.ONE
	add_child(cam)

	ui_layer = CanvasLayer.new()
	add_child(ui_layer)


func _build_players() -> void:
	players.clear()
	players.append(_make_player(0, Vector2(360, FLOOR_Y - 48), 1.0))
	players.append(_make_player(1, Vector2(W - 360, FLOOR_Y - 48), -1.0))


func _make_player(ix: int, start_pos: Vector2, facing: float) -> Dictionary:
	# CharacterBody2D — one per player. Players don't collide with each other;
	# their collision_mask is 1 (walls/floor only).
	var body := CharacterBody2D.new()
	body.collision_layer = 2 if ix == 0 else 8
	body.collision_mask = 1
	var cs := CollisionShape2D.new()
	var cap := CapsuleShape2D.new()
	cap.radius = 20
	cap.height = 88
	cs.shape = cap
	body.add_child(cs)
	body.position = start_pos
	add_child(body)

	# Hip strike area — direction-sensitive, offset in facing direction.
	var hip := Area2D.new()
	hip.collision_layer = 0
	hip.collision_mask = 4
	var hs := CollisionShape2D.new()
	var hc := CircleShape2D.new()
	hc.radius = 36
	hs.shape = hc
	hs.name = "Shape"
	hip.add_child(hs)
	hip.position = Vector2(facing * 18, 6)
	body.add_child(hip)

	# Head area — triggers extra kick when ball hits the head during a jump.
	var head := Area2D.new()
	head.collision_layer = 0
	head.collision_mask = 4
	var headcs := CollisionShape2D.new()
	var headc := CircleShape2D.new()
	headc.radius = 20
	headcs.shape = headc
	head.add_child(headcs)
	head.position = Vector2(0, -46)
	body.add_child(head)

	return {
		"ix": ix,
		"body": body,
		"hip": hip,
		"head": head,
		"start_pos": start_pos,
		"home_facing": facing,
		"facing": facing,
		"primary": P1_PRIMARY if ix == 0 else P2_PRIMARY,
		"accent": P1_ACCENT if ix == 0 else P2_ACCENT,
		"name": "P1" if ix == 0 else "P2",
		"long": "JAGUAR" if ix == 0 else "EAGLE",
		"prefix": "p1_" if ix == 0 else "p2_",
		"dash_charges": DASH_MAX_CHARGES,
		"dash_regen_t": 0.0,
		"dash_t": 0.0,
		"dash_dir": 0.0,
		"dash_cd_t": 0.0,
		"hip_cd_t": 0.0,
		"strike_pending": false,
		"strike_t": 0.0,
		"jump_buffer_t": 0.0,
		"coyote_t": 0.0,
		"flash_t": 0.0,     # bright outline on hit
		"bot": false,
		"ai_jump_t": 0.0,   # AI next-jump reservation
		"ai_strike_t": 0.0,
	}


func _reset_match() -> void:
	finish_timer_id += 1
	scores = [0, 0]
	phase = Phase.SERVE
	phase_t = 1.0
	match_time = 0.0
	winner_ix = -1
	round_number = 1
	longest_rally = 0
	rally = 0
	ball_trail.clear()
	bursts.clear()
	shake = 0.0; shake_t = 0.0
	slow_mo_t = 0.0; hit_stop_t = 0.0
	Engine.time_scale = 1.0
	cam_zoom_t = 1.0; cam_zoom_target = 1.0
	banner_text = ""
	banner_t = 0.0

	# Player 2 = bot in 1P mode.
	players[0].bot = false
	players[1].bot = not two_player

	for p in players:
		_reset_player(p)
	_serve_ball()


func _reset_player(p: Dictionary) -> void:
	var body: CharacterBody2D = p.body
	body.position = p.start_pos
	body.velocity = Vector2.ZERO
	p.facing = p.home_facing
	p.dash_charges = DASH_MAX_CHARGES
	p.dash_regen_t = 0.0
	p.dash_t = 0.0
	p.dash_dir = 0.0
	p.dash_cd_t = 0.0
	p.hip_cd_t = 0.0
	p.strike_pending = false
	p.strike_t = 0.0
	p.jump_buffer_t = 0.0
	p.coyote_t = 0.0
	p.flash_t = 0.0


func _serve_ball(dir := 0.0) -> void:
	ball.freeze = true
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.position = Vector2(W * 0.5, 300)
	# Mode gravity for ball
	var m: Dictionary = MODES[mode_ix]
	ball.gravity_scale = m.ball_g / 980.0


func _begin_match() -> void:
	_reset_match()
	_set_state(State.PLAY)
	SFX.confirm()
	best_cfg["last_mode"] = mode_ix
	best_cfg["two_player"] = two_player
	_save_best()


func _restart_match() -> void:
	_reset_match()
	_set_state(State.PLAY)


# ===== input ================================================================
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = (event as InputEventMouseMotion).position
		queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_click(event.position)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if not first_input_received:
			first_input_received = true
			SFX.unlock_on_first_input()
			controls_fade_t = 3.0
		match state:
			State.TITLE:
				if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_SPACE:
					_begin_match()
				elif event.physical_keycode in [KEY_1, KEY_2, KEY_3]:
					mode_ix = event.physical_keycode - KEY_1
					queue_redraw()
				elif event.physical_keycode == KEY_T:
					two_player = not two_player
					SFX.click()
					queue_redraw()
			State.PLAY:
				if phase == Phase.MATCH_END:
					if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_SPACE:
						_set_state(State.RESULTS)
				elif event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
					SFX.click()
					_set_state(State.PAUSE)
				elif event.physical_keycode == KEY_R:
					_restart_match()
			State.PAUSE:
				if event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
					SFX.click()
					_set_state(State.PLAY)
			State.SETTINGS:
				if event.physical_keycode == KEY_ESCAPE:
					SFX.click()
					_set_state(state_prev)
			State.HOW_TO:
				if event.physical_keycode == KEY_ESCAPE:
					SFX.click()
					_set_state(State.TITLE)
			State.RESULTS:
				if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_SPACE:
					_set_state(State.TITLE)


func _handle_click(pos: Vector2) -> void:
	if not first_input_received:
		first_input_received = true
		SFX.unlock_on_first_input()
		controls_fade_t = 3.0
	for b in _buttons:
		if (b.rect as Rect2).has_point(pos):
			SFX.click()
			_on_button(b.id)
			return


func _on_button(id: String) -> void:
	match id:
		"play":   _begin_match()
		"how_to": _set_state(State.HOW_TO)
		"settings": _set_state(State.SETTINGS)
		"mode_0": mode_ix = 0; _save_best(); queue_redraw()
		"mode_1": mode_ix = 1; _save_best(); queue_redraw()
		"mode_2": mode_ix = 2; _save_best(); queue_redraw()
		"players_1":
			if two_player: two_player = false; _save_best(); queue_redraw()
		"players_2":
			if not two_player: two_player = true; _save_best(); queue_redraw()
		"resume": _set_state(State.PLAY)
		"restart": _restart_match()
		"settings_from_pause": _set_state(State.SETTINGS)
		"quit_to_title": _set_state(State.TITLE)
		"back": _set_state(state_prev)
		"play_again": _set_state(State.TITLE)
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


# ===== loop =================================================================
func _physics_process(delta: float) -> void:
	if state != State.PLAY:
		return
	if hit_stop_t > 0.0:
		hit_stop_t = maxf(0.0, hit_stop_t - get_physics_process_delta_time())
		return

	var real_dt := get_physics_process_delta_time()

	# Phase timing — timing uses real_dt so SERVE countdown doesn't drift with slow-mo.
	match phase:
		Phase.SERVE:
			phase_t -= real_dt
			if phase_t <= 0.0:
				_begin_round()
		Phase.PLAY:
			match_time += real_dt
			rally = rally  # tracked on hip hits
		Phase.GOAL:
			phase_t -= real_dt
			if phase_t <= 0.0:
				_setup_serve()
		Phase.MATCH_END:
			pass

	# Update players (bots + humans).
	for p in players:
		if p.bot and phase == Phase.PLAY:
			_update_bot(p, delta, real_dt)
		_update_player(p, delta, real_dt)

	# Ball sanity + trail
	if ball.linear_velocity.length() > 1500.0:
		ball.linear_velocity = ball.linear_velocity.limit_length(1500.0)
	ball_trail.push_front(ball.position)
	if ball_trail.size() > 22:
		ball_trail.pop_back()


# Called before a round starts: ball unfreezes and gameplay resumes.
func _begin_round() -> void:
	phase = Phase.PLAY
	phase_t = 0.0
	rally = 0
	ball.freeze = false
	# Give the ball a tiny nudge downward so it falls into play rather than
	# sitting at zero velocity above the center line.
	ball.linear_velocity = Vector2(rng.randf_range(-80, 80), 60)


func _setup_serve() -> void:
	phase = Phase.SERVE
	phase_t = 1.0
	for p in players:
		_reset_player(p)
	_serve_ball()


func _update_player(p: Dictionary, delta: float, real_dt: float) -> void:
	var body: CharacterBody2D = p.body
	var prefix: String = p.prefix

	# Timers (real time so windows don't warp during slow-mo).
	p.strike_t = maxf(0.0, p.strike_t - real_dt)
	p.hip_cd_t = maxf(0.0, p.hip_cd_t - real_dt)
	p.dash_cd_t = maxf(0.0, p.dash_cd_t - real_dt)
	p.jump_buffer_t = maxf(0.0, p.jump_buffer_t - real_dt)
	p.coyote_t = maxf(0.0, p.coyote_t - real_dt)
	p.flash_t = maxf(0.0, p.flash_t - real_dt)
	if p.dash_t > 0.0:
		p.dash_t = maxf(0.0, p.dash_t - real_dt)
	else:
		# Charge regen when not dashing
		if p.dash_charges < DASH_MAX_CHARGES:
			p.dash_regen_t += real_dt
			if p.dash_regen_t >= DASH_REGEN:
				p.dash_regen_t = 0.0
				p.dash_charges = mini(DASH_MAX_CHARGES, p.dash_charges + 1)

	# Whiff: window closed without a hit.
	if p.strike_pending and p.strike_t <= 0.0:
		p.strike_pending = false

	var m: Dictionary = MODES[mode_ix]
	var g: float = m.ball_g * 0.8   # player gravity slightly lower than ball
	var dir := 0.0
	var want_jump := false
	var want_dash := false
	var want_strike := false

	if phase == Phase.PLAY:
		dir = Input.get_action_strength(prefix + "right") - Input.get_action_strength(prefix + "left")
		want_jump = Input.is_action_just_pressed(prefix + "jump")
		want_dash = Input.is_action_just_pressed(prefix + "dash")
		want_strike = Input.is_action_just_pressed(prefix + "strike")
	# During SERVE we still let gravity + idle motion apply but no inputs.

	if dir != 0.0:
		p.facing = signf(dir)

	# Dash — spends a charge, overrides horizontal velocity for its duration.
	if want_dash and p.dash_t <= 0.0 and p.dash_cd_t <= 0.0 and p.dash_charges > 0:
		p.dash_charges -= 1
		p.dash_t = DASH_DURATION
		p.dash_cd_t = DASH_CD
		p.dash_dir = p.facing if dir == 0.0 else signf(dir)
		p.flash_t = DASH_DURATION
		if not settings.get("reduced_motion", false):
			_burst(body.position + Vector2(0, 8), p.accent, 10)
		SFX.tick()

	if p.dash_t > 0.0:
		body.velocity.x = p.dash_dir * DASH_SPEED
	else:
		body.velocity.x = move_toward(body.velocity.x, dir * MOVE_SPEED, 3400 * delta)

	body.velocity.y += g * delta

	# Jump buffer + coyote
	if want_jump:
		p.jump_buffer_t = 0.09
	if body.is_on_floor():
		p.coyote_t = 0.11
	if p.jump_buffer_t > 0.0 and p.coyote_t > 0.0:
		body.velocity.y = JUMP_V
		p.jump_buffer_t = 0.0
		p.coyote_t = 0.0
		if not settings.get("reduced_motion", false):
			_burst(body.position + Vector2(0, 42), PLASTER, 6)

	# Strike window
	if want_strike and p.strike_t <= 0.0 and not p.strike_pending and p.hip_cd_t <= 0.0:
		p.strike_t = STRIKE_WINDOW
		p.strike_pending = true

	body.move_and_slide()

	# Hip shape grows during window
	var shape: CircleShape2D = p.hip.get_node("Shape").shape
	shape.radius = 44.0 if p.strike_pending else 36.0
	# Follow facing with the hip offset
	p.hip.position = Vector2(p.facing * 18, 6)

	# Hip + head contact
	if phase == Phase.PLAY and p.hip_cd_t <= 0.0 and p.hip.overlaps_body(ball):
		_hip_hit(p)
	elif phase == Phase.PLAY and p.hip_cd_t <= 0.0 and p.head.overlaps_body(ball) and not body.is_on_floor():
		_head_bump(p)


func _hip_hit(p: Dictionary) -> void:
	var perfect: bool = p.strike_pending and p.strike_t > 0.0
	var dashing: bool = p.dash_t > 0.0
	var power: float = 1.0
	if perfect:
		power *= 1.8
	if dashing:
		power *= 1.35
	var side := signf(ball.position.x - p.body.position.x)
	if side == 0.0:
		side = p.facing
	var body_vel: Vector2 = p.body.velocity
	var vx := clampf(side * 220.0 + body_vel.x * 0.8, -820.0, 820.0) * power
	var vy := (-680.0 - maxf(0.0, -body_vel.y) * 0.35) * power
	ball.linear_velocity = Vector2(vx, vy)
	p.hip_cd_t = HIP_COOLDOWN
	p.flash_t = 0.16
	rally += 1
	longest_rally = maxi(longest_rally, rally)
	if perfect:
		shake = 7.0; shake_t = 0.35
		_burst(ball.position, GOLD, 24)
		_burst(ball.position, p.primary, 10)
		_hit_stop(HIT_STOP)
		_banner("PERFECT", 0.6, GOLD)
		SFX.success()
	elif dashing:
		shake = 5.0; shake_t = 0.25
		_burst(ball.position, p.accent, 14)
		_hit_stop(HIT_STOP)
		SFX.tick()
	else:
		shake = 3.0; shake_t = 0.2
		_burst(ball.position, INK, 8)
		SFX.tick()
	p.strike_pending = false
	p.strike_t = 0.0
	_ball_squash = 1.0


func _head_bump(p: Dictionary) -> void:
	# A head bump sends the ball opposite your facing and up; makes jumping into
	# the ball useful for lobbing a long shot.
	var side := signf(ball.position.x - p.body.position.x)
	if side == 0.0:
		side = p.facing
	var vx: float = clampf(side * 320.0 + p.body.velocity.x * 0.6, -720.0, 720.0)
	var vy: float = -560.0 + p.body.velocity.y * 0.2
	ball.linear_velocity = Vector2(vx, vy)
	p.hip_cd_t = HIP_COOLDOWN
	p.flash_t = 0.14
	_burst(ball.position, p.primary, 10)
	_banner("HEADER", 0.5, p.primary)
	SFX.tick()
	_ball_squash = 0.7
	rally += 1
	longest_rally = maxi(longest_rally, rally)


func _on_goal(body: Node, scorer_ix: int) -> void:
	if phase != Phase.PLAY or body != ball:
		return
	scores[scorer_ix] += 1
	phase = Phase.GOAL
	phase_t = 1.4
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.freeze = true
	var scorer: Dictionary = players[scorer_ix]
	_banner("GOAL  %s" % scorer.long, 1.2, scorer.primary)
	shake = 12.0; shake_t = 0.6
	_burst(ball.position, scorer.primary, 70)
	_burst(ball.position, GOLD, 30)
	SFX.kaching()
	_start_slow_mo(SLOW_MO_GOAL, 1.1)

	var goals_needed: int = MODES[mode_ix].goals
	if scores[scorer_ix] >= goals_needed:
		winner_ix = scorer_ix
		phase = Phase.MATCH_END
		phase_t = 0.0
		var tid := finish_timer_id
		get_tree().create_timer(1.6).timeout.connect(
			func(): if tid == finish_timer_id and state == State.PLAY and phase == Phase.MATCH_END: _grade_and_results()
		)


func _grade_and_results() -> void:
	# Save best per mode (per 2P/1P)
	var key := "mode_%d_%s" % [mode_ix, "2p" if two_player else "1p"]
	var row: Dictionary = best_cfg.get(key, {"wins_p1": 0, "wins_p2": 0, "longest_rally": 0})
	if winner_ix == 0:
		row.wins_p1 = int(row.wins_p1) + 1
	elif winner_ix == 1:
		row.wins_p2 = int(row.wins_p2) + 1
	row.longest_rally = maxi(int(row.longest_rally), longest_rally)
	best_cfg[key] = row
	_save_best()
	_set_state(State.RESULTS)


# ===== AI ===================================================================
func _update_bot(p: Dictionary, delta: float, real_dt: float) -> void:
	# Tiny soccer bot — chase ball x, jump when ball is close + above, strike
	# when ball is right in front, dash occasionally when far behind.
	var body: CharacterBody2D = p.body
	var bx: float = ball.position.x
	var by: float = ball.position.y
	var dx: float = bx - body.position.x
	var dy: float = by - body.position.y

	# Horizontal — bias to stay on own half when ball is on opponent half
	var own_x: float = p.start_pos.x
	var want_x: float = bx + (signf(own_x - W * 0.5) * 60.0 if signf(bx - W * 0.5) != signf(own_x - W * 0.5) else 0.0)
	var target_dir: float = signf(want_x - body.position.x)
	if absf(want_x - body.position.x) < 20.0:
		target_dir = 0.0

	# Press/release the input actions so the normal _update_player path handles
	# it. For AI simplicity: set bot_dir on p and have _update_player read it.
	# Simpler: just override velocity here before move_and_slide happens in
	# _update_player. But _update_player runs after this; we flip inputs via
	# Input.action_press/release.
	_action_set(p.prefix + "left", target_dir < 0.0)
	_action_set(p.prefix + "right", target_dir > 0.0)

	# Jump when ball close and above
	p.ai_jump_t = maxf(0.0, p.ai_jump_t - real_dt)
	var should_jump := false
	if body.is_on_floor() and p.ai_jump_t <= 0.0:
		if absf(dx) < 110.0 and dy < -40.0:
			should_jump = true
	_action_set(p.prefix + "jump", should_jump)
	if should_jump:
		p.ai_jump_t = 0.6

	# Dash when ball far on own side moving toward own goal
	var own_goal_x: float = (W if p.ix == 1 else 0.0)
	var ball_toward_own: bool = signf(ball.linear_velocity.x) == signf(own_goal_x - bx)
	var want_dash: bool = absf(dx) > 220.0 and ball_toward_own and int(p.dash_charges) > 0 and float(p.dash_t) <= 0.0 and float(p.dash_cd_t) <= 0.0 and rng.randf() < 0.015
	_action_set(p.prefix + "dash", want_dash)

	# Strike when ball is practically on us
	p.ai_strike_t = maxf(0.0, p.ai_strike_t - real_dt)
	var should_strike := false
	if absf(dx) < 50.0 and absf(dy) < 60.0 and p.hip_cd_t <= 0.0 and p.ai_strike_t <= 0.0:
		should_strike = true
	_action_set(p.prefix + "strike", should_strike)
	if should_strike:
		p.ai_strike_t = 0.35


# Press or release a virtual action for the next frame. Called from AI.
func _action_set(action: String, down: bool) -> void:
	if down:
		if not Input.is_action_pressed(action):
			Input.action_press(action)
	else:
		if Input.is_action_pressed(action):
			Input.action_release(action)


# ===== juice ================================================================
func _hit_stop(dur: float) -> void:
	if settings.get("reduced_motion", false):
		return
	hit_stop_t = maxf(hit_stop_t, dur)


func _start_slow_mo(dur: float, zoom: float) -> void:
	if settings.get("reduced_motion", false):
		return
	slow_mo_t = dur
	Engine.time_scale = 0.4
	cam_zoom_target = zoom


func _banner(text: String, t: float, c: Color = INK) -> void:
	banner_text = text
	banner_t = t
	banner_color = c


func _burst(pos: Vector2, color: Color, amount: int) -> void:
	for i in range(amount):
		var a := rng.randf_range(-PI, PI)
		var sp := rng.randf_range(100.0, 420.0)
		bursts.append({
			"pos": pos,
			"vel": Vector2(cos(a), sin(a)) * sp,
			"life": rng.randf_range(0.4, 0.9),
			"max_life": 0.9,
			"color": color,
			"size": rng.randf_range(2.0, 5.0),
		})


func _jade() -> Color:
	return JADE_CB if settings.get("colorblind", false) else JADE


# ===== per-frame ============================================================
func _process(delta: float) -> void:
	_ball_squash = maxf(0.0, _ball_squash - delta * 6.0)

	if slow_mo_t > 0.0:
		slow_mo_t = maxf(0.0, slow_mo_t - delta)
		if slow_mo_t <= 0.0:
			Engine.time_scale = 1.0
			cam_zoom_target = 1.0

	cam_zoom_t = lerp(cam_zoom_t, cam_zoom_target, clampf(delta * 6.0, 0.0, 1.0))
	cam.zoom = Vector2.ONE * cam_zoom_t

	if shake_t > 0.0:
		shake_t = maxf(0.0, shake_t - delta)
		var k := shake_t / 0.6
		var amp := shake * k * k
		if settings.get("reduced_motion", false):
			amp = 0.0
		cam.offset = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	else:
		cam.offset = Vector2.ZERO

	if banner_t > 0.0:
		banner_t = maxf(0.0, banner_t - delta)
		if banner_t <= 0.0:
			banner_text = ""

	star_drift += delta * 6.0

	for i in range(bursts.size() - 1, -1, -1):
		var p: Dictionary = bursts[i]
		p.life -= delta
		p.pos += p.vel * delta
		p.vel.y += 600.0 * delta
		if p.life <= 0.0:
			bursts.remove_at(i)

	if controls_fade_t > 0.0:
		controls_fade_t = maxf(0.0, controls_fade_t - delta)

	queue_redraw()


# ===== save / load ==========================================================
func _load_best() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {"last_mode": 1, "two_player": true}
	if cfg.load("user://ollama_best.cfg") != OK:
		return out
	out["last_mode"] = cfg.get_value("meta", "last_mode", 1)
	out["two_player"] = cfg.get_value("meta", "two_player", true)
	for i in range(MODES.size()):
		for mode in ["1p", "2p"]:
			var key := "mode_%d_%s" % [i, mode]
			if cfg.has_section(key):
				out[key] = {
					"wins_p1": cfg.get_value(key, "wins_p1", 0),
					"wins_p2": cfg.get_value(key, "wins_p2", 0),
					"longest_rally": cfg.get_value(key, "longest_rally", 0),
				}
	return out


func _save_best() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "last_mode", int(best_cfg.get("last_mode", 1)))
	cfg.set_value("meta", "two_player", bool(best_cfg.get("two_player", true)))
	for k in best_cfg.keys():
		if typeof(best_cfg[k]) == TYPE_DICTIONARY:
			var row: Dictionary = best_cfg[k]
			cfg.set_value(k, "wins_p1", int(row.get("wins_p1", 0)))
			cfg.set_value(k, "wins_p2", int(row.get("wins_p2", 0)))
			cfg.set_value(k, "longest_rally", int(row.get("longest_rally", 0)))
	cfg.save("user://ollama_best.cfg")


# ===== drawing ==============================================================
func _draw() -> void:
	_buttons.clear()
	_draw_scene()
	match state:
		State.TITLE:    _dim(0.55); _draw_title()
		State.HOW_TO:   _dim(0.6);  _draw_how_to()
		State.PLAY:     _draw_hud()
		State.PAUSE:    _dim(0.5);  _draw_pause()
		State.SETTINGS: _dim(0.6);  _draw_settings()
		State.RESULTS:  _dim(0.6);  _draw_results()


func _dim(a: float) -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, a))


# ---- world scene -----------------------------------------------------------
func _draw_scene() -> void:
	# Sky gradient
	var bands := 30
	for i in range(bands):
		var t := float(i) / bands
		draw_rect(Rect2(0, t * FLOOR_Y, W, FLOOR_Y / bands + 1), SKY_TOP.lerp(SKY_BOTTOM, pow(t, 1.6)))
	# Parallax stars
	var drift_far := fmod(star_drift * 0.4, W)
	var drift_near := fmod(star_drift * 1.2, W)
	for s in stars_far:
		var p := Vector2(fmod(s.x + drift_far, W), s.y)
		draw_circle(p, 1.0, Color(1, 1, 1, 0.35))
	for s in stars_near:
		var p := Vector2(fmod(s.x + drift_near, W), s.y)
		draw_circle(p, 1.4, Color(1, 1, 1, 0.65))

	# Sun + pyramid
	draw_circle(Vector2(900, 420), 90, SUN.darkened(0.1))
	draw_circle(Vector2(900, 420), 70, SUN)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 520), Vector2(180, 400), Vector2(330, 480),
		Vector2(520, 380), Vector2(700, 470), Vector2(900, 360),
		Vector2(1100, 460), Vector2(1280, 400), Vector2(1280, 640), Vector2(0, 640),
	]), Color("3b2437"))
	var base_y := 560.0
	for step in range(6):
		var w := 420.0 - step * 62.0
		draw_rect(Rect2(640 - w / 2, base_y - (step + 1) * 34.0, w, 34.0), Color("4e323a").darkened(step * 0.03))
	draw_rect(Rect2(615, base_y - 6 * 34.0 - 40, 50, 40), Color("4e323a"))

	# Torches
	var rm: bool = settings.get("reduced_motion", false)
	for i in range(2):
		var tx := 640.0 - 160.0 + i * 320.0
		var ty := base_y - 20.0
		draw_rect(Rect2(tx - 2, ty, 4, 24), STONE_DARK)
		var flick := 0.0 if rm else sin(Time.get_ticks_msec() * 0.012 + torch_seed[i]) * 0.3 + cos(Time.get_ticks_msec() * 0.021 + torch_seed[i]) * 0.2
		var r := 14.0 + flick * 3.0
		var col := GOLD.lerp(Color("ff7a3a"), 0.35 + flick * 0.1)
		draw_circle(Vector2(tx, ty - 2), r * 1.6, Color(col.r, col.g, col.b, 0.18))
		draw_circle(Vector2(tx, ty - 4), r, col)
		draw_circle(Vector2(tx, ty - 7), r * 0.5, INK)

	# Court floor
	draw_rect(Rect2(0, FLOOR_Y, W, H - FLOOR_Y), PLASTER)
	draw_line(Vector2(0, FLOOR_Y), Vector2(W, FLOOR_Y), STONE_DARK, 3)
	draw_line(Vector2(W / 2, FLOOR_Y + 4), Vector2(W / 2, H), Color(STONE_DARK, 0.5), 2)

	# Walls
	for poly in [_left_wall_shape(), _right_wall_shape()]:
		draw_colored_polygon(poly, STONE)
		draw_polyline(poly, STONE_DARK, 3)

	# Glyphs on upper walls
	for y in range(90, int(GOAL_TOP_Y) - 40, 70):
		_glyph(Vector2(30, y))
		_glyph(Vector2(W - 30, y))

	# Goal mouths — thick stone frame + rope-net lines inside, color-coded per side
	_draw_goal(Vector2(10, (GOAL_TOP_Y + GOAL_BOTTOM_Y) * 0.5), true, players[1].primary if players.size() > 1 else P2_PRIMARY)
	_draw_goal(Vector2(W - 10, (GOAL_TOP_Y + GOAL_BOTTOM_Y) * 0.5), false, players[0].primary if players.size() > 0 else P1_PRIMARY)

	# Ball trail
	if ball_trail.size() >= 2:
		for i in range(ball_trail.size() - 1):
			var a := 0.55 * (1.0 - float(i) / ball_trail.size())
			var width := BALL_R * (1.0 - float(i) * 0.04)
			draw_line(ball_trail[i], ball_trail[i + 1], Color(RUBBER.r, RUBBER.g, RUBBER.b, a), maxf(2.0, width))

	# Ball
	var sq := _ball_squash
	var sx := 1.0 + sq * 0.4
	var sy := 1.0 - sq * 0.4
	draw_set_transform(ball.position, 0.0, Vector2(sx, sy))
	draw_circle(Vector2.ZERO, BALL_R, RUBBER)
	var va: float = ball.linear_velocity.angle() if ball.linear_velocity.length() > 10.0 else 0.0
	var sheen := Vector2(cos(va - PI * 0.7), sin(va - PI * 0.7)) * (BALL_R - 7.0)
	draw_circle(sheen, 5, Color(1, 1, 1, 0.3))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Bursts
	for p in bursts:
		var a: float = clampf(p.life / p.max_life, 0.0, 1.0)
		draw_circle(p.pos, p.size, Color(p.color.r, p.color.g, p.color.b, a))

	# Players
	for p in players:
		_draw_player(p)

	# Strike window ring over active player
	for p in players:
		if p.strike_pending and p.strike_t > 0.0:
			var frac: float = p.strike_t / STRIKE_WINDOW
			var center: Vector2 = p.body.position + Vector2(0, -96)
			UI.draw_ring_bg(self, center, 16.0, Color(1, 1, 1, 0.15), 3.0)
			UI.draw_ring(self, center, 16.0, frac, GOLD, 3.0)


func _draw_goal(center: Vector2, is_left: bool, owner_color: Color) -> void:
	# Draw the goal mouth frame (top + back lip) and translucent rope net.
	var h := GOAL_BOTTOM_Y - GOAL_TOP_Y
	var depth := 54.0
	var dir: float = 1.0 if is_left else -1.0
	# Back wall tint of the goal mouth
	draw_rect(Rect2(Vector2(center.x + (-depth if is_left else 0), GOAL_TOP_Y), Vector2(depth, h)), Color(0, 0, 0, 0.28))
	# Top crossbar
	draw_rect(Rect2(Vector2(center.x + (-depth if is_left else 0), GOAL_TOP_Y - 10), Vector2(depth + 20, 10)), STONE_DARK)
	# Side jamb (near the court-facing side of the mouth)
	draw_rect(Rect2(Vector2(center.x + (depth - 6 if is_left else -depth), GOAL_TOP_Y), Vector2(6, h)), STONE_DARK)
	# Rope-net lines
	var net_c := Color(owner_color.r, owner_color.g, owner_color.b, 0.42)
	for i in range(5):
		var frac := float(i + 1) / 6.0
		var y := GOAL_TOP_Y + h * frac
		draw_line(Vector2(center.x + dir * 2, y), Vector2(center.x + dir * (depth - 2), y), net_c, 1.5)
	for i in range(4):
		var frac2 := float(i + 1) / 5.0
		var x := center.x + dir * depth * frac2
		draw_line(Vector2(x, GOAL_TOP_Y + 4), Vector2(x, GOAL_BOTTOM_Y - 4), net_c, 1.5)


func _draw_player(p: Dictionary) -> void:
	var body: CharacterBody2D = p.body
	var pos: Vector2 = body.position
	var strike_lean: float = 0.35 if p.strike_pending else 0.0
	var lean: float = strike_lean * p.facing
	var xf := Transform2D(lean, pos)
	draw_set_transform_matrix(xf)

	# Dash flash aura
	var flash: float = p.flash_t
	if flash > 0.0 and not settings.get("reduced_motion", false):
		var a: float = clampf(flash / 0.16, 0.0, 1.0)
		draw_circle(Vector2.ZERO, 56.0 + 6.0 * a, Color(p.accent.r, p.accent.g, p.accent.b, 0.18 * a))

	# Legs — small swinging animation driven by horizontal speed
	var vx: float = body.velocity.x
	var sway: float = sin(Time.get_ticks_msec() * 0.02) * clampf(absf(vx) * 0.02, 0.0, 6.0)
	draw_line(Vector2(-7, 20), Vector2(-10 + sway, 60), SKIN, 8)
	draw_line(Vector2(7, 20), Vector2(10 - sway, 60), SKIN, 8)
	# Torso
	draw_rect(Rect2(-14, -28, 28, 44), SKIN)
	# Yoke (team color sash)
	draw_rect(Rect2(-22, 0, 44, 16), p.primary if p.strike_pending else p.primary.darkened(0.15))
	draw_rect(Rect2(-22, 0, 44, 16), STONE_DARK, false, 2)
	# Head
	draw_circle(Vector2(0, -46), 20, SKIN)
	# Eye
	draw_circle(Vector2(6 * p.facing, -48), 2.5, Color.BLACK)
	# Headgear — jaguar spots for P1, eagle feathers for P2
	if p.ix == 0:
		# Jaguar hood: half-circle on top of head + spots
		var hood_pts := PackedVector2Array()
		for i in range(13):
			var ang: float = PI + i * PI / 12.0
			hood_pts.append(Vector2(cos(ang), sin(ang)) * 22 + Vector2(0, -46))
		draw_colored_polygon(hood_pts, p.primary.darkened(0.1))
		# Spots
		for sp in [Vector2(-10, -58), Vector2(8, -62), Vector2(-2, -54), Vector2(12, -50)]:
			draw_circle(sp, 2.2, Color(0, 0, 0, 0.5))
		# Ears
		draw_colored_polygon(PackedVector2Array([Vector2(-18, -58), Vector2(-10, -74), Vector2(-6, -60)]), p.primary.darkened(0.2))
		draw_colored_polygon(PackedVector2Array([Vector2(18, -58), Vector2(10, -74), Vector2(6, -60)]), p.primary.darkened(0.2))
	else:
		# Eagle beak + feathers
		# Feather crest
		for i in range(5):
			var ang: float = -PI / 2 + (i - 2) * 0.3 - p.facing * 0.22
			var tip := Vector2(cos(ang), sin(ang)) * 32 + Vector2(0, -54)
			draw_line(Vector2(0, -56), tip, p.primary if i % 2 == 0 else p.primary.darkened(0.2), 5)
		# Beak
		var beak_pts := PackedVector2Array([
			Vector2(0, -42), Vector2(p.facing * 18, -40), Vector2(0, -36),
		])
		draw_colored_polygon(beak_pts, p.accent)
	# Player tag (tiny label above head) for 2P clarity
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var tag_y := pos.y - 90.0
	draw_rect(Rect2(pos.x - 14, tag_y - 10, 28, 16), Color(p.primary.r, p.primary.g, p.primary.b, 0.85))
	draw_string(font_bold_tnum, Vector2(pos.x - 14, tag_y + 3), "P%d" % (p.ix + 1), HORIZONTAL_ALIGNMENT_CENTER, 28, 12, INK)


func _glyph(c: Vector2) -> void:
	draw_rect(Rect2(c - Vector2(14, 14), Vector2(28, 28)), STONE_DARK, false, 2)
	draw_circle(c, 5, STONE_DARK)
	draw_line(c + Vector2(-10, 10), c + Vector2(10, -10), STONE_DARK, 2)


# ---- HUD -------------------------------------------------------------------
func _draw_hud() -> void:
	# Scoreboard: [P1 head] [score] : [score] [P2 head] with timer below
	var sb_w := 440.0
	var sb := Rect2(W * 0.5 - sb_w * 0.5, 14, sb_w, 86)
	UI.draw_panel(self, sb, 14.0, Color(0, 0, 0, 0.5), UI.PANEL_BORDER)
	# Heads
	var head_r := 24.0
	var p1_center := sb.position + Vector2(32, sb.size.y * 0.5)
	var p2_center := sb.position + Vector2(sb.size.x - 32, sb.size.y * 0.5)
	_draw_scoreboard_head(p1_center, head_r, players[0])
	_draw_scoreboard_head(p2_center, head_r, players[1])
	# Scores
	_text(sb.position + Vector2(sb.size.x * 0.5 - 70, 56), "%d" % scores[0], UI.TYPE_HUD, players[0].primary, HORIZONTAL_ALIGNMENT_CENTER, 60, true, true)
	_text(sb.position + Vector2(sb.size.x * 0.5, 56), ":", UI.TYPE_HUD, Color(INK, 0.65), HORIZONTAL_ALIGNMENT_CENTER, 20, true, true)
	_text(sb.position + Vector2(sb.size.x * 0.5 + 10, 56), "%d" % scores[1], UI.TYPE_HUD, players[1].primary, HORIZONTAL_ALIGNMENT_CENTER, 60, true, true)
	# Mode caption
	_text(sb.position + Vector2(0, 22), "%s · FIRST TO %d" % [MODES[mode_ix].name.to_upper(), int(MODES[mode_ix].goals)], UI.TYPE_CAPTION, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, sb.size.x, true)

	# Dash charges strip under each side
	_draw_dash_strip(Vector2(28, 28), players[0], true)
	_draw_dash_strip(Vector2(W - 28, 28), players[1], false)

	# Serve countdown big number
	if phase == Phase.SERVE and phase_t > 0.0:
		var n := int(ceil(phase_t))
		_text(Vector2(0, H * 0.5 - 10), "%d" % maxi(1, n), UI.TYPE_TITLE + 32, GOLD, HORIZONTAL_ALIGNMENT_CENTER, W, true, true)

	# Goal banner / match end
	if banner_text != "":
		var a: float = clampf(banner_t * 2.0, 0.0, 1.0)
		var bg_h := 86.0
		var bg_y := H * 0.36
		draw_rect(Rect2(0, bg_y, W, bg_h), Color(0, 0, 0, 0.4 * a))
		_text(Vector2(0, bg_y + 58), banner_text, UI.TYPE_TITLE + 10, Color(banner_color.r, banner_color.g, banner_color.b, 0.75 + 0.25 * a), HORIZONTAL_ALIGNMENT_CENTER, W, true, true)

	if phase == Phase.MATCH_END:
		_dim(0.4)
		var winner_name: String = players[winner_ix].long if winner_ix >= 0 else "?"
		var winner_color: Color = players[winner_ix].primary if winner_ix >= 0 else INK
		_text(Vector2(0, H * 0.5 - 20), "%s WINS" % winner_name, UI.TYPE_TITLE + 8, winner_color, HORIZONTAL_ALIGNMENT_CENTER, W, true, true)
		_text(Vector2(0, H * 0.5 + 24), "%d · %d" % [scores[0], scores[1]], UI.TYPE_HEADLINE, INK, HORIZONTAL_ALIGNMENT_CENTER, W, true, true)
		_text(Vector2(0, H * 0.5 + 56), "ENTER for results", UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, W)

	_draw_controls_hint()


func _draw_scoreboard_head(center: Vector2, r: float, p: Dictionary) -> void:
	# Little round head icon in team color.
	draw_circle(center, r, SKIN)
	draw_circle(center + Vector2(0, -r * 0.3), r * 1.0, p.primary.darkened(0.1))
	# Simple feature stripe to differentiate
	if p.ix == 0:
		draw_circle(center + Vector2(-r * 0.3, -r * 0.3), 2.2, Color(0, 0, 0, 0.5))
		draw_circle(center + Vector2(r * 0.3, -r * 0.4), 2.2, Color(0, 0, 0, 0.5))
	else:
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(0, -r * 0.1),
			center + Vector2(-r * 0.6, r * 0.1),
			center + Vector2(0, r * 0.3),
		]), p.accent)


func _draw_dash_strip(origin: Vector2, p: Dictionary, left_align: bool) -> void:
	var sign_x: float = 1.0 if left_align else -1.0
	for i in range(DASH_MAX_CHARGES):
		var cx := origin.x + sign_x * (i * 16.0 + 10.0 if left_align else -(i * 16.0 + 10.0))
		var filled: bool = i < int(p.dash_charges)
		var col: Color = p.accent if filled else Color(INK, 0.25)
		draw_circle(Vector2(cx, origin.y), 5.0, col)


func _draw_controls_hint() -> void:
	if not settings.get("show_controls", true):
		return
	var alpha := 1.0
	if first_input_received:
		alpha = clampf(controls_fade_t / 3.0, 0.0, 1.0)
	if alpha <= 0.0:
		return
	# P1 chip (bottom left) + P2 chip (bottom right if 2P, else "AI")
	_draw_chip_row(Vector2(20, H - 30), ["P1  A/D move", "W jump", "S dash", "SPACE strike"], alpha, true, players[0].primary)
	if two_player:
		_draw_chip_row(Vector2(W - 20, H - 30), ["ENTER strike", "↓ dash", "↑ jump", "P2  ←/→ move"], alpha, false, players[1].primary)
	else:
		var text := "P2  AI"
		var w: float = font_bold.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.TYPE_CAPTION).x + 20
		var r := Rect2(W - 20 - w, H - 30, w, 22)
		UI.draw_panel(self, r, 10.0, Color(players[1].primary.r, players[1].primary.g, players[1].primary.b, 0.22 * alpha), Color(players[1].primary.r, players[1].primary.g, players[1].primary.b, 0.6 * alpha))
		_text(Vector2(r.position.x + 10, r.position.y + 15), text, UI.TYPE_CAPTION, Color(INK.r, INK.g, INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)


func _draw_chip_row(origin: Vector2, chips: Array, alpha: float, left_align: bool, team: Color) -> void:
	var x: float = origin.x
	for i in range(chips.size()):
		var c: String = chips[i]
		var w: float = font_regular.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.TYPE_CAPTION).x + 20
		var r: Rect2
		if left_align:
			r = Rect2(x, origin.y, w, 22)
			x += w + 8
		else:
			r = Rect2(x - w, origin.y, w, 22)
			x -= w + 8
		var is_team := (left_align and i == 0) or (not left_align and i == chips.size() - 1)
		var fill: Color = Color(team.r, team.g, team.b, 0.22 * alpha) if is_team else Color(0, 0, 0, 0.35 * alpha)
		var border: Color = Color(team.r, team.g, team.b, 0.6 * alpha) if is_team else Color(1, 1, 1, 0.2 * alpha)
		UI.draw_panel(self, r, 10.0, fill, border)
		_text(Vector2(r.position.x + 10, r.position.y + 15), c, UI.TYPE_CAPTION, Color(INK.r, INK.g, INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)


# ---- title -----------------------------------------------------------------
func _draw_title() -> void:
	var card := Rect2(80, 70, 560, 580)
	UI.draw_card(self, card, GOLD)
	_text(card.position + Vector2(28, 56), "ŌLLAMALIZTLI", UI.TYPE_TITLE + 6, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(card.position + Vector2(28, 86), "Jaguar vs eagle. First to score.", UI.TYPE_BODY, Color(INK, 0.85))

	# Mode
	_text(card.position + Vector2(28, 126), "MODE", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(MODES.size()):
		var r := Rect2(card.position.x + 28 + i * 170, card.position.y + 146, 160, 68)
		var sel: bool = i == mode_ix
		var hover: bool = r.has_point(mouse_pos)
		var fill: Color = Color(GOLD.r, GOLD.g, GOLD.b, 0.26 if sel else (0.14 if hover else 0.06))
		var bor: Color = Color(GOLD.r, GOLD.g, GOLD.b, 1.0 if sel else (0.5 if hover else 0.2))
		UI.draw_panel(self, r, 10.0, fill, bor)
		_text(r.position + Vector2(0, 24), MODES[i].name, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, sel or hover)
		_text(r.position + Vector2(10, 46), MODES[i].subtitle, UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20)
		_buttons.append({"rect": r, "id": "mode_%d" % i})

	# Player count
	_text(card.position + Vector2(28, 232), "PLAYERS", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var opts := [[1, "1 PLAYER", "vs AI eagle"], [2, "2 PLAYERS", "local versus"]]
	for i in range(opts.size()):
		var cnt: int = opts[i][0]
		var r2 := Rect2(card.position.x + 28 + i * 250, card.position.y + 252, 240, 60)
		var sel: bool = (cnt == 2 and two_player) or (cnt == 1 and not two_player)
		var hover: bool = r2.has_point(mouse_pos)
		var tcol: Color = P1_PRIMARY if cnt == 1 else P2_PRIMARY
		var fill: Color = Color(tcol.r, tcol.g, tcol.b, 0.3 if sel else (0.14 if hover else 0.06))
		var bor: Color = Color(tcol.r, tcol.g, tcol.b, 1.0 if sel else (0.5 if hover else 0.22))
		UI.draw_panel(self, r2, 10.0, fill, bor)
		_text(r2.position + Vector2(0, 24), opts[i][1], UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, r2.size.x, sel or hover)
		_text(r2.position + Vector2(10, 44), opts[i][2], UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, r2.size.x - 20)
		_buttons.append({"rect": r2, "id": "players_1" if cnt == 1 else "players_2"})

	# Buttons
	var by: float = card.position.y + 338
	_button("play",     Rect2(card.position.x + 28,  by, 220, 54), "Play", true, UI.TYPE_HEADLINE)
	_button("how_to",   Rect2(card.position.x + 264, by, 220, 54), "How to play")
	_button("settings", Rect2(card.position.x + 28,  by + 72, 220, 44), "Settings")
	# Plain hint — not a button
	_text(Vector2(card.position.x + 264, by + 72 + 30), "T toggles players", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, 220)

	# Best vs AI/local
	var key := "mode_%d_%s" % [mode_ix, "2p" if two_player else "1p"]
	var row: Dictionary = best_cfg.get(key, {})
	if not row.is_empty():
		_text(card.position + Vector2(28, 500), "Best · P1 %d  ·  P2 %d  ·  longest rally %d" % [int(row.get("wins_p1", 0)), int(row.get("wins_p2", 0)), int(row.get("longest_rally", 0))], UI.TYPE_CAPTION, Color(INK, 0.8))

	# Info card
	var info := Rect2(680, 70, 520, 440)
	UI.draw_panel(self, info)
	_text(info.position + Vector2(24, 36), "WHAT THIS SHOWS", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var bullets := [
		"1v1 arena. Hip strike, head bump, air dash.",
		"PERFECT timing on the strike for a big hit.",
		"Three dashes per player, regen over time.",
		"Ball crosses your goal line, opponent scores.",
		"Pickup, Match, Legend — first to 3, 5, 7.",
		"Procedural art, audio, fonts. Everything in code.",
	]
	var yy: float = info.position.y + 70
	for b in bullets:
		_text(Vector2(info.position.x + 24, yy), "·  " + b, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, info.size.x - 48)
		yy += 28

	var note := Rect2(680, 530, 520, 110)
	UI.draw_panel(self, note, 10.0, Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.14))
	_text(note.position + Vector2(0, 44), "Tribute to the ballgame played across Mesoamerica", UI.TYPE_CAPTION, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, note.size.x)
	_text(note.position + Vector2(0, 66), "for about 3000 years.", UI.TYPE_CAPTION, Color(INK, 0.65), HORIZONTAL_ALIGNMENT_CENTER, note.size.x)


# ---- how to ----------------------------------------------------------------
func _draw_how_to() -> void:
	var r := Rect2(180, 70, 920, 580)
	UI.draw_card(self, r, GOLD)
	_text(r.position + Vector2(28, 54), "HOW TO PLAY", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	# Two columns: P1 (jade) + P2 (red)
	var col_w := (r.size.x - 112) * 0.5
	var cx1 := r.position.x + 28
	var cx2 := r.position.x + 28 + col_w + 56
	var cy := r.position.y + 110

	_text(Vector2(cx1, cy), "P1 · JAGUAR", UI.TYPE_HEADLINE, P1_PRIMARY, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(cx2, cy), "P2 · EAGLE",  UI.TYPE_HEADLINE, P2_PRIMARY, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	cy += 36
	var p1_lines := ["A / D move", "W jump", "S dash", "SPACE hip strike"]
	var p2_lines := ["← / → move", "↑ jump", "↓ dash", "ENTER hip strike"]
	for i in range(p1_lines.size()):
		_text(Vector2(cx1, cy + i * 26), "·  " + p1_lines[i], UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, col_w)
		_text(Vector2(cx2, cy + i * 26), "·  " + p2_lines[i], UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, col_w)
	cy += 4 * 26 + 20

	_text(Vector2(r.position.x + 28, cy), "RULES", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	cy += 22
	var rules := [
		"Hit the ball with your HIP to kick it toward your opponent's goal.",
		"Tap strike just as the ball meets your hip for a PERFECT: big hit, slow-mo.",
		"Jump into the ball to HEADER it over the opponent.",
		"Dash during a hip strike for extra kick power. 3 charges, regen slow.",
		"First to the mode's goal count wins. ESC pauses. R restarts.",
	]
	for l in rules:
		_text(Vector2(r.position.x + 28, cy), "·  " + l, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 56)
		cy += 26

	_button("back", Rect2(r.position.x + r.size.x - 160, r.position.y + r.size.y - 70, 140, 44), "Back")


# ---- pause -----------------------------------------------------------------
func _draw_pause() -> void:
	var r := Rect2(W * 0.5 - 180, 180, 360, 320)
	UI.draw_card(self, r, GOLD)
	_text(r.position + Vector2(0, 60), "PAUSED", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_button("resume",   Rect2(r.position.x + 40, r.position.y + 100, r.size.x - 80, 44), "Resume", true)
	_button("restart",  Rect2(r.position.x + 40, r.position.y + 150, r.size.x - 80, 44), "Restart match")
	_button("settings_from_pause", Rect2(r.position.x + 40, r.position.y + 200, r.size.x - 80, 44), "Settings")
	_button("quit_to_title", Rect2(r.position.x + 40, r.position.y + 250, r.size.x - 80, 44), "Quit to title")


# ---- settings --------------------------------------------------------------
func _draw_settings() -> void:
	var r := Rect2(360, 110, 560, 480)
	UI.draw_card(self, r, GOLD)
	_text(r.position + Vector2(28, 50), "SETTINGS", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_text(r.position + Vector2(28, 110), "Volume", UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_button("vol_down", Rect2(r.position.x + 28, r.position.y + 125, 34, 32), "-")
	_button("vol_up",   Rect2(r.position.x + 68, r.position.y + 125, 34, 32), "+")
	var bar := Rect2(r.position.x + 118, r.position.y + 136, 300, 10)
	UI.draw_panel(self, bar, 5.0, Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.14))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * settings.volume, bar.size.y)), GOLD)
	_text(Vector2(r.position.x + 428, r.position.y + 148), "%d%%" % int(settings.volume * 100), UI.TYPE_CAPTION, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_toggle("mute_toggle",     r.position + Vector2(28, 180), "Mute all audio", settings.mute)
	_toggle("reduced_motion",  r.position + Vector2(28, 230), "Reduced motion", settings.reduced_motion)
	_toggle("colorblind",      r.position + Vector2(28, 280), "Colorblind palette (jade to blue)", settings.colorblind)
	_toggle("show_controls",   r.position + Vector2(28, 330), "Show on-screen controls", settings.show_controls)

	_button("back", Rect2(r.position.x + r.size.x - 150, r.position.y + r.size.y - 70, 120, 44), "Back")


func _toggle(id: String, pos: Vector2, label: String, on: bool) -> void:
	var r := Rect2(pos, Vector2(500, 36))
	var hover: bool = r.has_point(mouse_pos)
	UI.draw_panel(self, r, 10.0, Color(1, 1, 1, 0.14 if hover else 0.06), Color(1, 1, 1, 0.26 if hover else 0.14))
	var knob := Rect2(r.position + Vector2(r.size.x - 56, 6), Vector2(42, 24))
	UI.draw_panel(self, knob, 12.0, Color(GOLD.r, GOLD.g, GOLD.b, 0.9) if on else Color(1, 1, 1, 0.10), UI.PANEL_BORDER)
	draw_circle(knob.position + Vector2(30 if on else 12, 12), 9, INK)
	_text(r.position + Vector2(16, 23), label, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, false)
	_buttons.append({"rect": r, "id": id})


# ---- results ---------------------------------------------------------------
func _draw_results() -> void:
	var r := Rect2(260, 70, 760, 580)
	UI.draw_card(self, r, GOLD)
	var title: String = "DRAW"
	var title_color: Color = INK
	if winner_ix == 0:
		title = "P1 WINS · JAGUAR"
		title_color = P1_PRIMARY
	elif winner_ix == 1:
		title = "P2 WINS · EAGLE" if two_player else "AI WINS · EAGLE"
		title_color = P2_PRIMARY
	_text(r.position + Vector2(0, 72), title, UI.TYPE_TITLE + 4, title_color, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Big scoreline
	var cy: float = r.position.y + 148
	_text(Vector2(r.position.x, cy), "%d · %d" % [scores[0], scores[1]], UI.TYPE_HUD, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Head icons left/right of scoreline
	_draw_scoreboard_head(Vector2(r.position.x + r.size.x * 0.5 - 110, cy + 20), 26, players[0])
	_draw_scoreboard_head(Vector2(r.position.x + r.size.x * 0.5 + 110, cy + 20), 26, players[1])

	cy += 100
	_text(Vector2(r.position.x, cy),     "Mode · %s · first to %d" % [MODES[mode_ix].name, int(MODES[mode_ix].goals)], UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 28), "Players · %s" % ("2 local" if two_player else "1 vs AI"), UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 56), "Longest rally · %d touches" % longest_rally, UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 84), "Match time · %s" % UI.mmss(match_time), UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)

	var key := "mode_%d_%s" % [mode_ix, "2p" if two_player else "1p"]
	var row: Dictionary = best_cfg.get(key, {})
	if not row.is_empty():
		_text(Vector2(r.position.x, cy + 118), "All time · P1 wins %d · P2 wins %d · rally %d" % [int(row.get("wins_p1", 0)), int(row.get("wins_p2", 0)), int(row.get("longest_rally", 0))], UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	_button("restart",    Rect2(r.position.x + r.size.x * 0.5 - 230, r.position.y + r.size.y - 86, 200, 50), "Rematch", true)
	_button("play_again", Rect2(r.position.x + r.size.x * 0.5 + 30,  r.position.y + r.size.y - 86, 200, 50), "Back to title")


# ---- primitives ------------------------------------------------------------
func _text(pos: Vector2, s: String, size: int = UI.TYPE_BODY, color: Color = INK, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, bold: bool = false, tnum: bool = false) -> void:
	var f: Font
	if bold:
		f = font_bold_tnum if tnum else font_bold
	else:
		f = font_tnum if tnum else font_regular
	draw_string(f, pos, s, align, width, size, color)


func _button(id: String, rect: Rect2, label: String, primary: bool = false, size: int = UI.TYPE_BODY) -> void:
	var hover: bool = rect.has_point(mouse_pos)
	var fill: Color
	var border: Color
	if primary:
		fill = Color(GOLD.r, GOLD.g, GOLD.b, 0.32 if hover else 0.22)
		border = Color(GOLD.r, GOLD.g, GOLD.b, 1.0 if hover else 0.9)
	else:
		fill = Color(1, 1, 1, 0.14 if hover else 0.06)
		border = Color(1, 1, 1, 0.28 if hover else 0.14)
	UI.draw_panel(self, rect, 12.0, fill, border)
	var tx: Vector2 = rect.position + Vector2(0, rect.size.y * 0.5 + size * 0.33)
	_text(tx, label, size, INK, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, primary or hover)
	_buttons.append({"rect": rect, "id": id})
