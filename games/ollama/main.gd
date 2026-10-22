extends Node2D
## ŌLLAMALIZTLI — flagship demo.
## Hips only. Thread the stone ring. Perfect-timing rhythm layer, combo multiplier,
## ring slow-mo, three difficulty modes. Everything drawn in code.

const UI = preload("res://ui_kit.gd")

enum State { TITLE, HOW_TO, PLAY, PAUSE, SETTINGS, RESULTS }

const W := 1280.0
const H := 720.0
const FLOOR_Y := 640.0
const RING_POS_HOME := Vector2(640, 300)
const RING_GAP := 52.0
const BALL_R := 16.0

const MOVE_SPEED := 400.0
const JUMP_V := -640.0

const JUMP_BUFFER := 0.08
const COYOTE := 0.10
const STRIKE_WINDOW := 0.09
const HIT_STOP := 0.05
const SLOW_MO_PERFECT := 0.18
const SLOW_MO_RING := 0.30

const MODES := [
	{"name": "Ritual",  "gravity": 1400.0, "ring_cd": 1.0, "lives": 5, "shift": 0.0,  "ring_moves": false, "subtitle": "5 lives · no clock"},
	{"name": "Match",   "gravity": 1600.0, "ring_cd": 1.0, "lives": 3, "shift": 90.0, "ring_moves": false, "subtitle": "3 lives · 90s"},
	{"name": "Legend",  "gravity": 1800.0, "ring_cd": 2.0, "lives": 3, "shift": 90.0, "ring_moves": true,  "subtitle": "3 lives · ring drifts"},
]

# Palette — dusk over the court (softer than before)
const SKY_TOP := Color("1a1a38")
const SKY_BOTTOM := Color("c86b48")
const SUN := Color("ffcf5c")
const STONE := Color("b9a07e")
const STONE_DARK := Color("6a5540")
const PLASTER := Color("c9b494")
const JADE := Color("2fb38a")
const JADE_CB := Color("5cc8ff")       # colorblind alt
const GOLD := Color("f2b632")
const SKIN := Color("8a5a3c")
const RUBBER := Color("2a2220")
const INK := Color("fff3d6")

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
var best_cfg: Dictionary = {}  # per-mode best
var first_input_received: bool = false
var controls_fade_t: float = 0.0
var _buttons: Array = []

# Scene nodes
var player: CharacterBody2D
var hip: Area2D
var ball: RigidBody2D
var floor_body: StaticBody2D
var ring_zone: Area2D
var ring_rims: Array = []  # [StaticBody2D]
var ring_post: StaticBody2D
var cam: Camera2D
var ui_layer: CanvasLayer

# Gameplay
var rng := RandomNumberGenerator.new()
var facing := 1.0
var hit_cooldown := 0.0
var ring_cooldown := 0.0
var shake := 0.0
var shake_t := 0.0
var lives := 3
var rally := 0
var best_rally := 0
var rings_threaded := 0
var score := 0
var combo := 0
var game_over := false
var time_left := 0.0
var ring_pos := RING_POS_HOME
var ring_target := RING_POS_HOME
var ring_drift_t := 0.0
var ball_trail: Array = []  # Array of Vector2
var stars_near: Array = []
var stars_far: Array = []
var star_drift := 0.0
var ball_served := false
var banner_text := ""
var banner_t := 0.0

# Strike / perfect timing
var strike_t := 0.0            # time remaining in window
var strike_pending := false    # pressed and not yet consumed
var last_hit_was_perfect := false

# Slow-mo / hit-stop
var slow_mo_t := 0.0
var slow_mo_dur := 0.0
var hit_stop_t := 0.0
var cam_zoom_t := 1.0
var cam_zoom_target := 1.0

# Jump buffer / coyote
var jump_buffer_t := 0.0
var coyote_t := 0.0
var was_on_floor := false

# Particles / bursts (lightweight)
var bursts: Array = []  # {pos, vel, life, max_life, color, size}

# Torch flicker seeds
var torch_seed := [0.0, 0.0]

# Grade thresholds / results
var grade := 1


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

	# Starfield two depths
	var r := RandomNumberGenerator.new()
	r.seed = 2026
	for i in range(60):
		stars_far.append(Vector2(r.randf() * W, r.randf() * 240))
	for i in range(40):
		stars_near.append(Vector2(r.randf() * W, r.randf() * 260))

	torch_seed = [r.randf() * 100.0, r.randf() * 100.0]

	_build_world()
	_set_state(State.TITLE)


func _setup_input() -> void:
	var map := {
		"left":    [KEY_A, KEY_LEFT],
		"right":   [KEY_D, KEY_RIGHT],
		"jump":    [KEY_W, KEY_UP, KEY_SPACE],
		"strike":  [KEY_J, KEY_SHIFT],
		"restart": [KEY_ENTER],
		"pause":   [KEY_ESCAPE, KEY_P],
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
	# Pause physics when not playing.
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
	add_child(body)
	return body


func _left_wall() -> PackedVector2Array:
	return PackedVector2Array([Vector2(-200, -400), Vector2(60, -400), Vector2(60, 430), Vector2(190, FLOOR_Y), Vector2(-200, FLOOR_Y)])


func _right_wall() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _left_wall():
		out.append(Vector2(W - p.x, p.y))
	return out


func _build_world() -> void:
	floor_body = _static_poly(PackedVector2Array([Vector2(-200, FLOOR_Y), Vector2(W + 200, FLOOR_Y), Vector2(W + 200, H + 200), Vector2(-200, H + 200)]))
	_static_poly(_left_wall())
	_static_poly(_right_wall())
	_static_poly(PackedVector2Array([Vector2(-200, -420), Vector2(W + 200, -420), Vector2(W + 200, -400), Vector2(-200, -400)]))
	# Ring post + two rims. Position dynamically updated in _process via Transform2D offsets.
	# (We use fixed stone bodies; the ring can only drift a few px, so static bodies at the base position are fine.)
	for dy in [-RING_GAP, RING_GAP]:
		var rim := StaticBody2D.new()
		var cs := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 11
		cs.shape = circle
		rim.add_child(cs)
		rim.position = ring_pos + Vector2(0, dy)
		rim.set_meta("rim_dy", dy)
		add_child(rim)
		ring_rims.append(rim)

	ring_zone = Area2D.new()
	var zs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(10, RING_GAP * 2 - 26)
	zs.shape = rect
	ring_zone.add_child(zs)
	ring_zone.position = ring_pos
	ring_zone.collision_mask = 4
	ring_zone.body_entered.connect(_on_ring)
	add_child(ring_zone)

	# Player
	player = CharacterBody2D.new()
	player.collision_layer = 2
	player.collision_mask = 1
	var pcs := CollisionShape2D.new()
	var cap := CapsuleShape2D.new()
	cap.radius = 18
	cap.height = 84
	pcs.shape = cap
	player.add_child(pcs)
	player.position = Vector2(360, FLOOR_Y - 42)
	add_child(player)

	hip = Area2D.new()
	hip.collision_layer = 0
	hip.collision_mask = 4
	var hs := CollisionShape2D.new()
	var hc := CircleShape2D.new()
	hc.radius = 34
	hs.shape = hc
	hs.name = "Shape"
	hip.add_child(hs)
	hip.position = Vector2(0, 6)
	player.add_child(hip)

	# Ball
	ball = RigidBody2D.new()
	ball.collision_layer = 4
	ball.collision_mask = 1
	ball.mass = 1.0
	ball.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	var bpm := PhysicsMaterial.new()
	bpm.bounce = 0.72
	bpm.friction = 0.2
	ball.physics_material_override = bpm
	var bcs := CollisionShape2D.new()
	var bc := CircleShape2D.new()
	bc.radius = BALL_R
	bcs.shape = bc
	ball.add_child(bcs)
	ball.position = Vector2(380, 360)
	ball.freeze = true
	ball.body_entered.connect(_on_ball_touch)
	add_child(ball)

	# Camera
	cam = Camera2D.new()
	cam.position = Vector2(W / 2, H / 2)
	cam.zoom = Vector2.ONE
	add_child(cam)

	# UI canvas layer (procedural; nothing but click targets)
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)


func _reset_match() -> void:
	var m: Dictionary = MODES[mode_ix]
	lives = m.lives
	rally = 0
	best_rally = 0
	rings_threaded = 0
	score = 0
	combo = 0
	game_over = false
	time_left = m.shift
	ring_pos = RING_POS_HOME
	ring_target = RING_POS_HOME
	ring_drift_t = 0.0
	ball_trail.clear()
	bursts.clear()
	strike_t = 0.0
	strike_pending = false
	slow_mo_t = 0.0
	hit_stop_t = 0.0
	cam_zoom_t = 1.0
	cam_zoom_target = 1.0
	Engine.time_scale = 1.0
	ball_served = false
	player.position = Vector2(360, FLOOR_Y - 42)
	player.velocity = Vector2.ZERO
	ball.freeze = true
	ball.linear_velocity = Vector2.ZERO
	ball.position = Vector2(380, 360)
	# Default project gravity is 980; scale so each mode hits its target.
	ball.gravity_scale = m.gravity / 980.0
	ring_cooldown = 0.0
	hit_cooldown = 0.0
	shake = 0.0
	shake_t = 0.0
	banner_text = ""
	banner_t = 0.0


# ===== input ================================================================
func _unhandled_input(event: InputEvent) -> void:
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
			State.PLAY:
				if game_over:
					if event.physical_keycode == KEY_ENTER:
						_set_state(State.RESULTS)
				elif event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
					SFX.click()
					_set_state(State.PAUSE)
				elif event.physical_keycode == KEY_ENTER:
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
		"mode_0": mode_ix = 0
		"mode_1": mode_ix = 1
		"mode_2": mode_ix = 2
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


func _begin_match() -> void:
	_reset_match()
	_set_state(State.PLAY)
	SFX.confirm()
	best_cfg["last_mode"] = mode_ix
	_save_best()


func _restart_match() -> void:
	_reset_match()
	_set_state(State.PLAY)


# ===== loop =================================================================
func _physics_process(delta: float) -> void:
	if state != State.PLAY or game_over:
		return

	# Hit-stop: freeze simulation for a few frames by scaling delta locally.
	if hit_stop_t > 0.0:
		hit_stop_t = maxf(0.0, hit_stop_t - get_physics_process_delta_time())
		return

	# Timers (always decay in real time so the strike window stays 90ms wall clock).
	var real_dt := get_physics_process_delta_time()
	hit_cooldown = maxf(0.0, hit_cooldown - real_dt)
	ring_cooldown = maxf(0.0, ring_cooldown - real_dt)
	strike_t = maxf(0.0, strike_t - real_dt)
	jump_buffer_t = maxf(0.0, jump_buffer_t - real_dt)
	coyote_t = maxf(0.0, coyote_t - real_dt)

	if strike_pending and strike_t <= 0.0:
		# Window closed without a hit → whiff.
		_whiff()

	# Movement + input
	var dir := Input.get_axis("left", "right")
	# Serve the ball on first move.
	if ball.freeze and (dir != 0.0 or Input.is_action_just_pressed("jump") or Input.is_action_just_pressed("strike")):
		ball.freeze = false
		ball_served = true
	if dir != 0.0:
		facing = signf(dir)
	player.velocity.x = move_toward(player.velocity.x, dir * MOVE_SPEED, 3200 * delta)
	# Apply mode gravity to player.
	var m: Dictionary = MODES[mode_ix]
	player.velocity.y += m.gravity * delta

	# Jump buffer + coyote
	if Input.is_action_just_pressed("jump"):
		jump_buffer_t = JUMP_BUFFER
	if player.is_on_floor():
		coyote_t = COYOTE
	if jump_buffer_t > 0.0 and coyote_t > 0.0:
		player.velocity.y = JUMP_V
		jump_buffer_t = 0.0
		coyote_t = 0.0

	# Strike window
	if Input.is_action_just_pressed("strike") and strike_t <= 0.0 and not strike_pending:
		strike_t = STRIKE_WINDOW
		strike_pending = true

	player.move_and_slide()
	was_on_floor = player.is_on_floor()

	# Hip radius grows a touch during the window to signal activity.
	(hip.get_node("Shape").shape as CircleShape2D).radius = 42.0 if strike_pending else 34.0

	# Hip contact
	if hit_cooldown <= 0.0 and hip.overlaps_body(ball):
		_hip_hit()

	# Ring approach slow-mo (not during ring cooldown so it only fires on fresh approaches)
	if slow_mo_t <= 0.0 and ring_cooldown <= 0.5 and ball_served:
		var to_ring := ring_pos - ball.position
		var d := to_ring.length()
		if d < 120.0 and ball.linear_velocity.length() > 400.0 and ball.linear_velocity.dot(to_ring) > 0.0:
			_start_slow_mo(SLOW_MO_RING, 1.2)

	# Ball sanity
	if ball.linear_velocity.length() > 1400.0:
		ball.linear_velocity = ball.linear_velocity.limit_length(1400.0)

	# Trail sample
	ball_trail.push_front(ball.position)
	if ball_trail.size() > 22:
		ball_trail.pop_back()

	# Ring drift (Legend mode)
	if m.ring_moves:
		ring_drift_t -= real_dt
		if ring_drift_t <= 0.0:
			ring_target = RING_POS_HOME + Vector2(rng.randf_range(-80.0, 80.0), rng.randf_range(-40.0, 20.0))
			ring_drift_t = rng.randf_range(3.0, 5.0)
		ring_pos = ring_pos.move_toward(ring_target, 40.0 * real_dt)
		ring_zone.position = ring_pos
		for i in range(ring_rims.size()):
			var dy: float = ring_rims[i].get_meta("rim_dy")
			ring_rims[i].position = ring_pos + Vector2(0, dy)


func _hip_hit() -> void:
	var perfect := strike_pending and strike_t > 0.0
	var power := 1.9 if perfect else 1.0
	var side := signf(ball.position.x - player.position.x)
	if side == 0.0:
		side = facing
	var vx := clampf(side * 180.0 + player.velocity.x * 0.75, -700.0, 700.0) * power
	var vy := (-740.0 - maxf(0.0, -player.velocity.y) * 0.35) * power
	ball.linear_velocity = Vector2(vx, vy)
	hit_cooldown = 0.22

	if perfect:
		combo = mini(combo + 3, 99)
		_start_slow_mo(SLOW_MO_PERFECT, 1.0)
		shake = 7.0
		shake_t = 0.4
		_burst(ball.position, GOLD, 28)
		_burst(ball.position, INK, 10)
		_hit_stop(HIT_STOP)
		_banner("PERFECT  +%d" % (3 * _mult()), 0.8)
		SFX.success()
		last_hit_was_perfect = true
	else:
		combo = mini(combo + 1, 99)
		shake = 3.0
		shake_t = 0.2
		_burst(ball.position, INK, 10)
		_hit_stop(HIT_STOP)
		SFX.tick()
		last_hit_was_perfect = false

	rally += 1
	best_rally = maxi(best_rally, rally)
	score += 1 * _mult()
	strike_pending = false
	strike_t = 0.0

	# Ball squash (visual only; drawn with scale lerp)
	_ball_squash = 1.0


func _whiff() -> void:
	strike_pending = false
	combo = int(combo / 2)
	shake = 4.0
	shake_t = 0.15
	SFX.fail()


func _mult() -> int:
	if combo >= 20:
		return 5
	if combo >= 12:
		return 4
	if combo >= 6:
		return 3
	if combo >= 3:
		return 2
	return 1


func _on_ball_touch(body: Node) -> void:
	if state != State.PLAY or body != floor_body or game_over:
		return
	lives -= 1
	combo = 0
	rally = 0
	shake = 7.0
	shake_t = 0.4
	_burst(ball.position, PLASTER, 18)
	SFX.fail()
	if lives <= 0:
		game_over = true
		_grade_and_banner()
		await get_tree().create_timer(1.1).timeout
		if game_over:
			_set_state(State.RESULTS)
	else:
		_banner("BALL DOWN · %d left" % lives, 1.2)


func _on_ring(body: Node) -> void:
	if state != State.PLAY or body != ball or ring_cooldown > 0.0 or game_over:
		return
	ring_cooldown = MODES[mode_ix].ring_cd
	rings_threaded += 1
	var mult := _mult()
	var add := (25 + rally * 2) * mult
	score += add
	shake = 14.0
	shake_t = 0.5
	_burst(ring_pos, _jade(), 90)
	_burst(ring_pos, GOLD, 50)
	_banner("THROUGH!  +%d  (×%d)" % [add, mult], 1.3)
	SFX.kaching()
	_start_slow_mo(SLOW_MO_PERFECT, 1.15)


var _ball_squash := 0.0  # 1.0 at impact, decays


func _process(delta: float) -> void:
	# Decay the ball squash in real time so a hit-stop still shows it.
	_ball_squash = maxf(0.0, _ball_squash - delta * 6.0)

	# Slow-mo decay
	if slow_mo_t > 0.0:
		slow_mo_t = maxf(0.0, slow_mo_t - delta)
		if slow_mo_t <= 0.0:
			Engine.time_scale = 1.0
			cam_zoom_target = 1.0

	# Camera zoom lerp
	cam_zoom_t = lerp(cam_zoom_t, cam_zoom_target, clampf(delta * 6.0, 0.0, 1.0))
	cam.zoom = Vector2.ONE * cam_zoom_t

	# Camera shake (decay curve)
	if shake_t > 0.0:
		shake_t = maxf(0.0, shake_t - delta)
		var k := shake_t / 0.5
		var amp := shake * k * k
		if settings.get("reduced_motion", false):
			amp = 0.0
		cam.offset = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	else:
		cam.offset = Vector2.ZERO

	# Banner timer
	if banner_t > 0.0:
		banner_t = maxf(0.0, banner_t - delta)
		if banner_t <= 0.0:
			banner_text = ""

	# Star drift
	star_drift += delta * 6.0

	# Bursts
	for i in range(bursts.size() - 1, -1, -1):
		var p: Dictionary = bursts[i]
		p.life -= delta
		p.pos += p.vel * delta
		p.vel.y += 600.0 * delta
		if p.life <= 0.0:
			bursts.remove_at(i)

	# Time
	if state == State.PLAY and not game_over:
		var m: Dictionary = MODES[mode_ix]
		if m.shift > 0.0:
			time_left -= delta / Engine.time_scale  # time ticks in real seconds
			if time_left <= 0.0:
				time_left = 0.0
				game_over = true
				_grade_and_banner()
				await get_tree().create_timer(1.0).timeout
				if game_over:
					_set_state(State.RESULTS)

	# Controls fade
	if controls_fade_t > 0.0:
		controls_fade_t = maxf(0.0, controls_fade_t - delta)

	queue_redraw()


func _hit_stop(dur: float) -> void:
	if settings.get("reduced_motion", false):
		return
	hit_stop_t = maxf(hit_stop_t, dur)


func _start_slow_mo(dur: float, zoom: float) -> void:
	if settings.get("reduced_motion", false):
		# A brief tint via banner would be noise; just skip.
		return
	slow_mo_t = dur
	slow_mo_dur = dur
	Engine.time_scale = 0.4
	cam_zoom_target = zoom


func _banner(text: String, t: float) -> void:
	banner_text = text
	banner_t = t


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


# ===== grade + save =========================================================
func _grade_and_banner() -> void:
	grade = 1
	if rings_threaded >= 1:
		grade = 2
	if rings_threaded >= 1 and combo >= 6:  # ×3+ at some point implied by threading with combo
		grade = 3
	# Record best per mode.
	var key := "mode_%d" % mode_ix
	var row: Dictionary = best_cfg.get(key, {"score": 0, "rally": 0, "rings": 0, "grade": 1})
	row.score = maxi(int(row.score), score)
	row.rally = maxi(int(row.rally), best_rally)
	row.rings = maxi(int(row.rings), rings_threaded)
	row.grade = maxi(int(row.grade), grade)
	best_cfg[key] = row
	_save_best()


func _load_best() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {"last_mode": 1}
	if cfg.load("user://ollama_best.cfg") != OK:
		return out
	out["last_mode"] = cfg.get_value("meta", "last_mode", 1)
	for i in range(MODES.size()):
		var key := "mode_%d" % i
		if cfg.has_section(key):
			out[key] = {
				"score": cfg.get_value(key, "score", 0),
				"rally": cfg.get_value(key, "rally", 0),
				"rings": cfg.get_value(key, "rings", 0),
				"grade": cfg.get_value(key, "grade", 1),
			}
	return out


func _save_best() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "last_mode", int(best_cfg.get("last_mode", 1)))
	for i in range(MODES.size()):
		var key := "mode_%d" % i
		if best_cfg.has(key):
			var row: Dictionary = best_cfg[key]
			cfg.set_value(key, "score", row.score)
			cfg.set_value(key, "rally", row.rally)
			cfg.set_value(key, "rings", row.rings)
			cfg.set_value(key, "grade", row.grade)
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
	# Sky gradient (softer)
	var bands := 30
	for i in range(bands):
		var t := float(i) / bands
		draw_rect(Rect2(0, t * FLOOR_Y, W, FLOOR_Y / bands + 1), SKY_TOP.lerp(SKY_BOTTOM, pow(t, 1.6)))
	# Parallax stars (two depths)
	var drift_far := fmod(star_drift * 0.4, W)
	var drift_near := fmod(star_drift * 1.2, W)
	for s in stars_far:
		var p := Vector2(fmod(s.x + drift_far, W), s.y)
		draw_circle(p, 1.0, Color(1, 1, 1, 0.35))
	for s in stars_near:
		var p := Vector2(fmod(s.x + drift_near, W), s.y)
		draw_circle(p, 1.4, Color(1, 1, 1, 0.65))

	# Sun sinking behind the pyramid
	draw_circle(Vector2(900, 420), 90, SUN.darkened(0.1))
	draw_circle(Vector2(900, 420), 70, SUN)

	# Distant mountains
	draw_colored_polygon(PackedVector2Array([Vector2(0, 520), Vector2(180, 400), Vector2(330, 480), Vector2(520, 380), Vector2(700, 470), Vector2(900, 360), Vector2(1100, 460), Vector2(1280, 400), Vector2(1280, 640), Vector2(0, 640)]), Color("3b2437"))

	# Stepped pyramid silhouette
	var base_y := 560.0
	for step in range(6):
		var w := 420.0 - step * 62.0
		draw_rect(Rect2(640 - w / 2, base_y - (step + 1) * 34.0, w, 34.0), Color("4e323a").darkened(step * 0.03))
	draw_rect(Rect2(615, base_y - 6 * 34.0 - 40, 50, 40), Color("4e323a"))

	# Torches on pyramid base (procedural flicker, respect reduced-motion)
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

	# Sloped stone walls with glyph carvings
	for poly in [_left_wall(), _right_wall()]:
		draw_colored_polygon(poly, STONE)
		draw_polyline(poly, STONE_DARK, 3)
	for y in range(80, 420, 60):
		_glyph(Vector2(30, y))
		_glyph(Vector2(W - 30, y))

	# Ring post + ring at current drift position
	draw_rect(Rect2(ring_pos.x - 8, 0, 16, ring_pos.y - RING_GAP - 12), STONE_DARK)
	_draw_ellipse(ring_pos, Vector2(20, RING_GAP + 12), STONE)
	_draw_ellipse(ring_pos, Vector2(9, RING_GAP - 10), SKY_BOTTOM.darkened(0.25))
	_draw_ellipse_outline(ring_pos, Vector2(20, RING_GAP + 12), STONE_DARK, 3)

	# Ball trail as polyline with alpha fade
	if ball_trail.size() >= 2:
		for i in range(ball_trail.size() - 1):
			var a := 0.55 * (1.0 - float(i) / ball_trail.size())
			var width := BALL_R * (1.0 - float(i) * 0.04)
			draw_line(ball_trail[i], ball_trail[i + 1], Color(RUBBER.r, RUBBER.g, RUBBER.b, a), maxf(2.0, width))

	# Ball with squash + sheen that rotates with velocity
	var sq := _ball_squash
	var sx := 1.0 + sq * 0.4
	var sy := 1.0 - sq * 0.4
	var ball_scale := Vector2(sx, sy)
	draw_set_transform(ball.position, 0.0, ball_scale)
	draw_circle(Vector2.ZERO, BALL_R, RUBBER)
	# Sheen rotates with velocity angle
	var va: float = ball.linear_velocity.angle() if ball.linear_velocity.length() > 10.0 else 0.0
	var sheen := Vector2(cos(va - PI * 0.7), sin(va - PI * 0.7)) * (BALL_R - 7.0)
	draw_circle(sheen, 5, Color(1, 1, 1, 0.3))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Bursts
	for p in bursts:
		var a: float = clampf(p.life / p.max_life, 0.0, 1.0)
		draw_circle(p.pos, p.size, Color(p.color.r, p.color.g, p.color.b, a))

	_draw_player()

	# Perfect-timing arc gauge above head during window
	if strike_pending and strike_t > 0.0 and not game_over:
		var frac: float = strike_t / STRIKE_WINDOW
		var center := player.position + Vector2(0, -92)
		UI.draw_ring_bg(self, center, 18.0, Color(1, 1, 1, 0.15), 3.0)
		UI.draw_ring(self, center, 18.0, frac, GOLD, 3.0)


func _draw_player() -> void:
	var p := player.position
	var lean := (0.35 if strike_pending else 0.0) * facing
	var xf := Transform2D(lean, p)
	draw_set_transform_matrix(xf)
	# Gold aura at ×3+ combo (respect reduced-motion)
	var mult := _mult()
	if mult >= 3 and not settings.get("reduced_motion", false):
		var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
		var aura_a := 0.10 + 0.08 * pulse + (mult - 3) * 0.04
		draw_circle(Vector2(0, 0), 56.0 + 4.0 * pulse, Color(GOLD.r, GOLD.g, GOLD.b, aura_a))
	# legs
	draw_line(Vector2(-7, 20), Vector2(-10 + sin(Time.get_ticks_msec() * 0.02) * absf(player.velocity.x) * 0.02, 60), SKIN, 8)
	draw_line(Vector2(7, 20), Vector2(10 - sin(Time.get_ticks_msec() * 0.02) * absf(player.velocity.x) * 0.02, 60), SKIN, 8)
	# torso
	draw_rect(Rect2(-14, -28, 28, 44), SKIN)
	# the yoke
	draw_rect(Rect2(-20, 0, 40, 16), GOLD if strike_pending else Color("c9932a"))
	draw_rect(Rect2(-20, 0, 40, 16), STONE_DARK, false, 2)
	# head
	draw_circle(Vector2(0, -42), 13, SKIN)
	draw_circle(Vector2(5 * facing, -44), 2, Color.BLACK)
	# feather headdress (jade + a secondary tone)
	for i in range(5):
		var ang := -PI / 2 + (i - 2) * 0.32 - facing * 0.25
		var tip := Vector2(cos(ang), sin(ang)) * 34 + Vector2(0, -50)
		draw_line(Vector2(0, -50), tip, _jade() if i % 2 == 0 else Color("1f7f9e"), 5)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _glyph(c: Vector2) -> void:
	# Minimal, generic geometry. Not representational.
	draw_rect(Rect2(c - Vector2(14, 14), Vector2(28, 28)), STONE_DARK, false, 2)
	draw_circle(c, 5, STONE_DARK)
	draw_line(c + Vector2(-10, 10), c + Vector2(10, -10), STONE_DARK, 2)


func _ellipse_points(c: Vector2, r: Vector2, n := 40) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return pts


func _draw_ellipse(c: Vector2, r: Vector2, color: Color) -> void:
	draw_colored_polygon(_ellipse_points(c, r), color)


func _draw_ellipse_outline(c: Vector2, r: Vector2, color: Color, width: float) -> void:
	var pts := _ellipse_points(c, r)
	pts.append(pts[0])
	draw_polyline(pts, color, width)


# ---- HUD -------------------------------------------------------------------
func _draw_hud() -> void:
	# Top-left: score / lives / rally
	_text(Vector2(28, 44), "SCORE", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(28, 76), str(score), UI.TYPE_HUD - 8, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(Vector2(28, 108), "RALLY %d · BEST %d · LIVES %d" % [rally, best_rally, lives], UI.TYPE_CAPTION, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_LEFT, -1, false, true)

	# Top-right: clock (if timed)
	var m: Dictionary = MODES[mode_ix]
	if m.shift > 0.0:
		var mm := int(time_left) / 60
		var ss := int(time_left) % 60
		_text(Vector2(W - 28, 76), "%d:%02d" % [mm, ss], UI.TYPE_HUD - 8, INK, HORIZONTAL_ALIGNMENT_RIGHT, -1, true, true)
		_text(Vector2(W - 28, 44), "CLOCK", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_RIGHT, -1, true)

	# Combo chip (top-center)
	var mult := _mult()
	var chip_w := 220.0
	var chip := Rect2(W * 0.5 - chip_w * 0.5, 20, chip_w, 56)
	var chip_fill := Color(0, 0, 0, 0.35)
	var chip_border := Color(GOLD.r, GOLD.g, GOLD.b, 0.5 + 0.1 * mult)
	UI.draw_panel(self, chip, 14.0, chip_fill, chip_border)
	_text(chip.position + Vector2(16, 22), "COMBO", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(chip.position + Vector2(16, 44), str(combo), UI.TYPE_HEADLINE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(chip.position + Vector2(chip.size.x - 16, 44), "×%d" % mult, UI.TYPE_HEADLINE + 4, GOLD if mult > 1 else Color(INK, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, -1, true, true)

	# Mode name small
	_text(Vector2(W * 0.5, 92), "%s · %s" % [MODES[mode_ix].name, "ring +25" if ring_cooldown <= 0.0 else "ring cooldown"], UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_CENTER)

	# Banner (big center text)
	if banner_text != "":
		var a: float = clampf(banner_t / 0.4, 0.0, 1.0)
		var size: int = UI.TYPE_TITLE + 10
		_text(Vector2(0, H * 0.4), banner_text, size, Color(INK.r, INK.g, INK.b, 0.65 + 0.35 * a), HORIZONTAL_ALIGNMENT_CENTER, W, true, true)

	# Game over overlay
	if game_over:
		_dim(0.4)
		_text(Vector2(0, H * 0.5 - 10), "FINAL SCORE  %d" % score, UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, W, true, true)
		_text(Vector2(0, H * 0.5 + 24), "ENTER for results", UI.TYPE_BODY, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, W)

	# Controls hint chips (fade after first input)
	_draw_controls_hint()


func _draw_controls_hint() -> void:
	if not settings.get("show_controls", true):
		return
	var alpha := 1.0
	if first_input_received:
		alpha = clampf(controls_fade_t / 3.0, 0.0, 1.0)
	if alpha <= 0.0:
		return
	var chips := [
		"A / D move",
		"W or SPACE jump",
		"J or SHIFT  strike (perfect = big hit)",
		"ESC pause",
	]
	var x := 20.0
	var y := H - 32.0
	for c in chips:
		var w: float = font_regular.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.TYPE_CAPTION).x + 20
		var r := Rect2(x, y, w, 22)
		UI.draw_panel(self, r, 10.0, Color(1, 1, 1, 0.08 * alpha), Color(1, 1, 1, 0.15 * alpha))
		_text(Vector2(x + 10, y + 15), c, UI.TYPE_CAPTION, Color(INK.r, INK.g, INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		x += w + 8


# ---- title -----------------------------------------------------------------
func _draw_title() -> void:
	var card := Rect2(80, 90, 560, 460)
	UI.draw_card(self, card, GOLD)
	_text(card.position + Vector2(28, 60), "ŌLLAMALIZTLI", UI.TYPE_TITLE + 10, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(card.position + Vector2(28, 94), "Hips only. Thread the ring.", UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_LEFT, -1, false)

	# Mode select
	_text(card.position + Vector2(28, 140), "MODE", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(MODES.size()):
		var r := Rect2(card.position.x + 28 + i * 170, card.position.y + 160, 160, 68)
		var sel: bool = i == mode_ix
		var fill: Color = Color(GOLD.r, GOLD.g, GOLD.b, 0.18) if sel else UI.PANEL_FILL
		var bor: Color = Color(GOLD.r, GOLD.g, GOLD.b, 0.9) if sel else UI.PANEL_BORDER
		UI.draw_panel(self, r, 10.0, fill, bor)
		_text(r.position + Vector2(0, 24), MODES[i].name, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, sel)
		_text(r.position + Vector2(8, 46), MODES[i].subtitle, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16)
		_buttons.append({"rect": r, "id": "mode_%d" % i})

	# Buttons
	var by: float = card.position.y + 254
	_button("play",     Rect2(card.position.x + 28,  by, 220, 54), "Play", true, UI.TYPE_HEADLINE)
	_button("how_to",   Rect2(card.position.x + 264, by, 160, 54), "How to play")
	_button("settings", Rect2(card.position.x + 28,  by + 72, 160, 44), "Settings")

	# Best line
	var row: Dictionary = best_cfg.get("mode_%d" % mode_ix, {})
	if not row.is_empty():
		_text(card.position + Vector2(28, 400), "Best · %d  ·  longest rally %d  ·  rings %d" % [row.score, row.rally, row.rings], UI.TYPE_CAPTION, Color(INK, 0.7))

	# Right info card
	var info := Rect2(680, 90, 520, 390)
	UI.draw_panel(self, info)
	_text(info.position + Vector2(24, 36), "WHAT THIS SHOWS", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var bullets := [
		"90ms perfect-timing window.",
		"Tap strike as the ball meets your hip.",
		"Combo multiplier up to ×5. Whiff halves it.",
		"Ring approach triggers slow-mo and a push-in.",
		"Three modes: Ritual teaches, Legend drifts the ring.",
		"Procedural audio, particles and fonts.",
	]
	var yy: float = info.position.y + 70
	for b in bullets:
		_text(Vector2(info.position.x + 24, yy), "·  " + b, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, info.size.x - 48)
		yy += 28

	# Historical note (respectful, factual)
	var note := Rect2(80, H - 86, W - 160, 56)
	UI.draw_panel(self, note, 10.0, Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.10))
	_text(note.position + Vector2(0, 32), "Tribute to the ballgame played by the Maya, Mexica and other Mesoamerican peoples for about 3000 years.", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, note.size.x)


# ---- how to ----------------------------------------------------------------
func _draw_how_to() -> void:
	var r := Rect2(220, 90, 840, 540)
	UI.draw_card(self, r, GOLD)
	_text(r.position + Vector2(28, 54), "HOW TO PLAY", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	var lines := [
		"A or D move. W or SPACE jump. J or SHIFT strike.",
		"A plain hip touch returns the ball and adds +1 to the combo.",
		"Press strike as the ball meets your hip for a PERFECT: bigger hit, slow-mo, +3 combo.",
		"Combo multiplies points up to ×5. Threading the ring pays 25 + rally bonus, multiplied.",
		"A floor touch costs a life and resets the combo. A whiff halves it.",
		"ESC or P pauses. Reduced motion and colorblind palette are in Settings.",
	]
	var yy: float = r.position.y + 110
	for l in lines:
		_text(Vector2(r.position.x + 28, yy), "·  " + l, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 56)
		yy += 32
	_button("back", Rect2(r.position.x + r.size.x - 180, r.position.y + r.size.y - 70, 140, 44), "Back")


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
	_button("vol_down", Rect2(r.position.x + 28, r.position.y + 125, 34, 32), "−")
	_button("vol_up",   Rect2(r.position.x + 68, r.position.y + 125, 34, 32), "+")
	var bar := Rect2(r.position.x + 118, r.position.y + 136, 300, 10)
	UI.draw_panel(self, bar, 5.0, Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.14))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * settings.volume, bar.size.y)), GOLD)
	_text(Vector2(r.position.x + 428, r.position.y + 148), "%d%%" % int(settings.volume * 100), UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_toggle("mute_toggle",     r.position + Vector2(28, 180), "Mute all audio", settings.mute)
	_toggle("reduced_motion",  r.position + Vector2(28, 230), "Reduced motion", settings.reduced_motion)
	_toggle("colorblind",      r.position + Vector2(28, 280), "Colorblind palette (jade → blue)", settings.colorblind)
	_toggle("show_controls",   r.position + Vector2(28, 330), "Show on-screen controls", settings.show_controls)

	_button("back", Rect2(r.position.x + r.size.x - 150, r.position.y + r.size.y - 70, 120, 44), "Back")


func _toggle(id: String, pos: Vector2, label: String, on: bool) -> void:
	var r := Rect2(pos, Vector2(500, 36))
	UI.draw_panel(self, r, 10.0, UI.PANEL_FILL, UI.PANEL_BORDER)
	var knob := Rect2(r.position + Vector2(r.size.x - 56, 6), Vector2(42, 24))
	UI.draw_panel(self, knob, 12.0, Color(GOLD.r, GOLD.g, GOLD.b, 0.9) if on else Color(1, 1, 1, 0.10), UI.PANEL_BORDER)
	draw_circle(knob.position + Vector2(30 if on else 12, 12), 9, INK)
	_text(r.position + Vector2(16, 23), label, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, false)
	_buttons.append({"rect": r, "id": id})


# ---- results ---------------------------------------------------------------
func _draw_results() -> void:
	var r := Rect2(260, 80, 760, 560)
	UI.draw_card(self, r, GOLD)
	var title: String
	match grade:
		3: title = "LEGENDARY"
		2: title = "GOOD HUNT"
		_: title = "KEEP GOING"
	_text(r.position + Vector2(0, 72), title, UI.TYPE_TITLE + 6, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Stars
	var sx: float = r.position.x + r.size.x * 0.5 - 60
	for i in range(3):
		var filled: bool = i < grade
		var col: Color = GOLD if filled else Color(INK, 0.3)
		_draw_star(Vector2(sx + i * 50, r.position.y + 120), 18.0, col, filled)

	var cy: float = r.position.y + 180
	_text(Vector2(r.position.x, cy),      "SCORE %d" % score,                 UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_text(Vector2(r.position.x, cy + 50), "Best rally %d" % best_rally,       UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 76), "Rings threaded %d" % rings_threaded, UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 110), "Mode · %s" % MODES[mode_ix].name, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# Mode best line
	var row: Dictionary = best_cfg.get("mode_%d" % mode_ix, {})
	if not row.is_empty():
		_text(Vector2(r.position.x, cy + 140), "Best in %s · %d  ·  rally %d  ·  rings %d" % [MODES[mode_ix].name, row.score, row.rally, row.rings], UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	_button("restart",    Rect2(r.position.x + r.size.x * 0.5 - 230, r.position.y + r.size.y - 86, 200, 50), "Play again", true)
	_button("play_again", Rect2(r.position.x + r.size.x * 0.5 + 30,  r.position.y + r.size.y - 86, 200, 50), "Back to title")


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


# ---- primitives ------------------------------------------------------------
func _text(pos: Vector2, s: String, size: int = UI.TYPE_BODY, color: Color = INK, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, bold: bool = false, tnum: bool = false) -> void:
	var f: Font
	if bold:
		f = font_bold_tnum if tnum else font_bold
	else:
		f = font_tnum if tnum else font_regular
	draw_string(f, pos, s, align, width, size, color)


func _button(id: String, rect: Rect2, label: String, primary: bool = false, size: int = UI.TYPE_BODY) -> void:
	var fill: Color = Color(GOLD.r, GOLD.g, GOLD.b, 0.20) if primary else UI.PANEL_FILL
	var border: Color = Color(GOLD.r, GOLD.g, GOLD.b, 0.9) if primary else UI.PANEL_BORDER
	UI.draw_panel(self, rect, 12.0, fill, border)
	var tx: Vector2 = rect.position + Vector2(0, rect.size.y * 0.5 + size * 0.33)
	_text(tx, label, size, INK, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, primary)
	_buttons.append({"rect": rect, "id": id})
