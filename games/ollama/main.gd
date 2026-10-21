extends Node2D
## ŌLLAMALIZTLI — the Mesoamerican ballgame.
## Keep the rubber ball in the air using only your hips. Thread it through the
## stone ring for a legendary score. Three floor touches and the game is over.
##
## A/D move · W or SPACE jump · J (or SHIFT) hip strike for a power hit · ENTER restart
## Everything is drawn procedurally — no imported art.

const W := 1280.0
const H := 720.0
const FLOOR_Y := 640.0
const RING_POS := Vector2(640, 300)
const RING_GAP := 52.0        # distance from ring center to each rim
const BALL_R := 16.0

const MOVE_SPEED := 400.0
const JUMP_V := -640.0
const GRAVITY := 1600.0

# Palette — dusk over the court
const SKY_TOP := Color("1d1b3a")
const SKY_BOTTOM := Color("e0794a")
const SUN := Color("ffcf5c")
const STONE := Color("b9a07e")
const STONE_DARK := Color("7d6650")
const PLASTER := Color("d8c3a0")
const JADE := Color("2fb38a")
const GOLD := Color("f2b632")
const SKIN := Color("8a5a3c")
const RUBBER := Color("2a2220")

var player: CharacterBody2D
var hip: Area2D
var ball: RigidBody2D
var floor_body: StaticBody2D
var cam: Camera2D
var hud: Label
var banner: Label

var facing := 1.0
var swing_t := 0.0
var hit_cooldown := 0.0
var shake := 0.0
var lives := 3
var rally := 0
var score := 0
var best := 0
var ring_cooldown := 0.0
var game_over := false
var ball_trail: Array[Vector2] = []
var stars: Array[Vector2] = []


func _ready() -> void:
	_setup_input()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	for i in range(80):
		stars.append(Vector2(rng.randf() * W, rng.randf() * 260))
	_build_court()
	_build_player()
	_build_ball()
	_build_ui()
	cam = Camera2D.new()
	cam.position = Vector2(W / 2, H / 2)
	add_child(cam)


func _setup_input() -> void:
	var map := {
		"left": [KEY_A, KEY_LEFT],
		"right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_W, KEY_UP, KEY_SPACE],
		"strike": [KEY_J, KEY_SHIFT],
		"restart": [KEY_ENTER],
	}
	for action in map:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


# ------------------------------------------------------------------ build
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


func _build_court() -> void:
	floor_body = _static_poly(PackedVector2Array([Vector2(-200, FLOOR_Y), Vector2(W + 200, FLOOR_Y), Vector2(W + 200, H + 200), Vector2(-200, H + 200)]))
	_static_poly(_left_wall())
	_static_poly(_right_wall())
	# Ceiling well above the screen so big hits can fly but never escape
	_static_poly(PackedVector2Array([Vector2(-200, -420), Vector2(W + 200, -420), Vector2(W + 200, -400), Vector2(-200, -400)]))
	# The ring hangs from a stone post; the post and both rims are solid
	_static_poly(PackedVector2Array([Vector2(632, -400), Vector2(648, -400), Vector2(648, RING_POS.y - RING_GAP - 12), Vector2(632, RING_POS.y - RING_GAP - 12)]))
	for dy in [-RING_GAP, RING_GAP]:
		var rim := StaticBody2D.new()
		var cs := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 11
		cs.shape = circle
		rim.add_child(cs)
		rim.position = RING_POS + Vector2(0, dy)
		add_child(rim)
	# Scoring zone — the hole in the ring
	var zone := Area2D.new()
	var zs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(10, RING_GAP * 2 - 26)
	zs.shape = rect
	zone.add_child(zs)
	zone.position = RING_POS
	zone.collision_mask = 4
	zone.body_entered.connect(_on_ring)
	add_child(zone)


func _build_player() -> void:
	player = CharacterBody2D.new()
	player.collision_layer = 2
	player.collision_mask = 1
	var cs := CollisionShape2D.new()
	var cap := CapsuleShape2D.new()
	cap.radius = 18
	cap.height = 84
	cs.shape = cap
	player.add_child(cs)
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


func _build_ball() -> void:
	ball = RigidBody2D.new()
	ball.collision_layer = 4
	ball.collision_mask = 1     # the ball only bounces off stone; hips are handled by hand
	ball.mass = 1.0
	ball.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.72
	pm.friction = 0.2
	ball.physics_material_override = pm
	var cs := CollisionShape2D.new()
	var c := CircleShape2D.new()
	c.radius = BALL_R
	cs.shape = c
	ball.add_child(cs)
	ball.position = Vector2(380, 360)
	ball.freeze = true  # waits for the player's first input
	ball.body_entered.connect(_on_ball_touch)
	add_child(ball)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(84, 18)
	hud.add_theme_font_size_override("font_size", 24)
	hud.add_theme_color_override("font_color", Color("fff3d6"))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 44)
	banner.add_theme_color_override("font_color", Color("fff3d6"))
	banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	banner.add_theme_constant_override("outline_size", 12)
	banner.text = "ŌLLAMALIZTLI\nHips only. Thread the ring.\nA/D move · W jump · J hip strike\nPress any key to serve"
	layer.add_child(banner)
	get_tree().create_timer(3.5).timeout.connect(func(): if not game_over: banner.text = "")


# ------------------------------------------------------------------ gameplay
func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
		return

	hit_cooldown = maxf(0.0, hit_cooldown - delta)
	ring_cooldown = maxf(0.0, ring_cooldown - delta)
	swing_t = maxf(0.0, swing_t - delta)

	# Movement
	var dir := Input.get_axis("left", "right")
	if ball.freeze and (dir != 0.0 or Input.is_action_just_pressed("jump") or Input.is_action_just_pressed("strike")):
		ball.freeze = false
	if game_over:
		dir = 0.0
	if dir != 0.0:
		facing = signf(dir)
	player.velocity.x = move_toward(player.velocity.x, dir * MOVE_SPEED, 3200 * delta)
	player.velocity.y += GRAVITY * delta
	if player.is_on_floor() and Input.is_action_just_pressed("jump") and not game_over:
		player.velocity.y = JUMP_V
	if Input.is_action_just_pressed("strike") and swing_t <= 0.0 and not game_over:
		swing_t = 0.28
	player.move_and_slide()

	# Hip contact
	(hip.get_node("Shape").shape as CircleShape2D).radius = 44.0 if swing_t > 0.0 else 34.0
	if hit_cooldown <= 0.0 and not game_over and hip.overlaps_body(ball):
		_hip_hit()

	# Keep the ball lively but sane
	if ball.linear_velocity.length() > 1300.0:
		ball.linear_velocity = ball.linear_velocity.limit_length(1300.0)

	ball_trail.push_front(ball.position)
	if ball_trail.size() > 14:
		ball_trail.pop_back()


func _hip_hit() -> void:
	var power := 1.45 if swing_t > 0.0 else 1.0
	var side := signf(ball.position.x - player.position.x)
	if side == 0.0:
		side = facing
	var vx := clampf(side * 160.0 + player.velocity.x * 0.75, -650.0, 650.0) * power
	var vy := (-720.0 - maxf(0.0, -player.velocity.y) * 0.35) * power
	ball.linear_velocity = Vector2(vx, vy)
	hit_cooldown = 0.22
	rally += 1
	score += 1
	shake = 5.0 if power > 1.0 else 2.0
	_burst(ball.position, GOLD if power > 1.0 else Color("fff3d6"), 14 if power > 1.0 else 8)


func _on_ball_touch(body: Node) -> void:
	if body != floor_body or game_over:
		return
	lives -= 1
	rally = 0
	shake = 7.0
	_burst(ball.position, PLASTER, 18)
	if lives <= 0:
		game_over = true
		best = maxi(best, score)
		banner.text = "THE BALL HAS FALLEN\nScore %d\n\nENTER to play again" % score
	else:
		_flash("Floor touch — %d left" % lives)


func _on_ring(body: Node) -> void:
	if body != ball or ring_cooldown > 0.0 or game_over:
		return
	ring_cooldown = 1.0
	score += 25 + rally * 2
	shake = 16.0
	_burst(RING_POS, JADE, 60)
	_burst(RING_POS, GOLD, 40)
	_flash("THROUGH THE RING!  +%d" % (25 + rally * 2))


func _flash(text: String) -> void:
	banner.text = text
	get_tree().create_timer(1.4).timeout.connect(func(): if not game_over and banner.text == text: banner.text = "")


func _burst(pos: Vector2, color: Color, amount: int) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = 0.7
	p.spread = 180.0
	p.initial_velocity_min = 120.0
	p.initial_velocity_max = 380.0
	p.gravity = Vector2(0, 600)
	p.scale_amount_min = 3.0
	p.scale_amount_max = 6.0
	p.color = color
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)


func _process(delta: float) -> void:
	shake = move_toward(shake, 0.0, delta * 30.0)
	cam.offset = Vector2(randf_range(-shake, shake), randf_range(-shake, shake))
	hud.text = "SCORE %d    RALLY %d    BEST %d" % [score, rally, best]
	queue_redraw()


# ------------------------------------------------------------------ drawing
func _draw() -> void:
	# Sky gradient
	var bands := 24
	for i in range(bands):
		var t := float(i) / bands
		draw_rect(Rect2(0, t * FLOOR_Y, W, FLOOR_Y / bands + 1), SKY_TOP.lerp(SKY_BOTTOM, t * t))
	for s in stars:
		draw_circle(s, 1.2, Color(1, 1, 1, 0.5))
	# Sun sinking behind the pyramid
	draw_circle(Vector2(900, 420), 90, SUN.darkened(0.1))
	draw_circle(Vector2(900, 420), 70, SUN)
	# Distant mountains
	draw_colored_polygon(PackedVector2Array([Vector2(0, 520), Vector2(180, 400), Vector2(330, 480), Vector2(520, 380), Vector2(700, 470), Vector2(900, 360), Vector2(1100, 460), Vector2(1280, 400), Vector2(1280, 640), Vector2(0, 640)]), Color("4a2f3f"))
	# Stepped pyramid silhouette
	var base_y := 560.0
	for step in range(6):
		var w := 420.0 - step * 62.0
		draw_rect(Rect2(640 - w / 2, base_y - (step + 1) * 34.0, w, 34.0), Color("5b3a40").darkened(step * 0.03))
	draw_rect(Rect2(615, base_y - 6 * 34.0 - 40, 50, 40), Color("5b3a40"))

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

	# Ring post + ring (seen nearly edge-on)
	draw_rect(Rect2(632, 0, 16, RING_POS.y - RING_GAP - 12), STONE_DARK)
	_draw_ellipse(RING_POS, Vector2(20, RING_GAP + 12), STONE)
	_draw_ellipse(RING_POS, Vector2(9, RING_GAP - 10), SKY_BOTTOM.darkened(0.25))
	_draw_ellipse_outline(RING_POS, Vector2(20, RING_GAP + 12), STONE_DARK, 3)

	# Ball trail + ball
	for i in range(ball_trail.size()):
		var a := 0.35 * (1.0 - float(i) / ball_trail.size())
		draw_circle(ball_trail[i], BALL_R * (1.0 - i * 0.04), Color(RUBBER, a))
	draw_circle(ball.position, BALL_R, RUBBER)
	draw_circle(ball.position + Vector2(-5, -5), 5, Color(1, 1, 1, 0.25))

	_draw_player()


func _draw_player() -> void:
	var p := player.position
	var lean := (0.35 if swing_t > 0.0 else 0.0) * facing
	var xf := Transform2D(lean, p)
	draw_set_transform_matrix(xf)
	# legs
	draw_line(Vector2(-7, 20), Vector2(-10 + sin(Time.get_ticks_msec() * 0.02) * absf(player.velocity.x) * 0.02, 60), SKIN, 8)
	draw_line(Vector2(7, 20), Vector2(10 - sin(Time.get_ticks_msec() * 0.02) * absf(player.velocity.x) * 0.02, 60), SKIN, 8)
	# torso
	draw_rect(Rect2(-14, -28, 28, 44), SKIN)
	# the yoke — protective hip belt, the only thing allowed to touch the ball
	draw_rect(Rect2(-20, 0, 40, 16), GOLD if swing_t > 0.0 else Color("c9932a"))
	draw_rect(Rect2(-20, 0, 40, 16), STONE_DARK, false, 2)
	# head
	draw_circle(Vector2(0, -42), 13, SKIN)
	draw_circle(Vector2(5 * facing, -44), 2, Color.BLACK)
	# feather headdress
	for i in range(5):
		var ang := -PI / 2 + (i - 2) * 0.32 - facing * 0.25
		var tip := Vector2(cos(ang), sin(ang)) * 34 + Vector2(0, -50)
		draw_line(Vector2(0, -50), tip, JADE if i % 2 == 0 else Color("1f7f9e"), 5)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _glyph(c: Vector2) -> void:
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
