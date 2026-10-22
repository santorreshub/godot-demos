extends Node3D
## FLATBED HAULER — supporting portfolio demo.
## Four steel coils from the mill to the dock. Rolling physics, coil racks,
## headboard. Reuses the shared ui_kit + sfx autoload + Inter fonts.

const UI = preload("res://ui_kit.gd")

enum State { TITLE, HOW_TO, PLAY, PAUSE, SETTINGS, RESULTS }

const COIL_Z := [1.2, -0.4, -2.0, -3.6]
const DOCK_POS := Vector3(0, 0, -260)
const ENGINE_FORCE := 5000.0
const BRAKE_FORCE := 40.0
const MAX_SPEED := 24.0
const MAX_STEER := 0.45
const BRAKE_COYOTE := 0.06
const DELIVERY_TIME := 1.2
const CLEAN_STOP_DECEL := 8.0

const MODES := [
	{"name": "Yard",     "time": 180.0, "par": 90.0, "friction": 2.5, "chicane": false, "wind": 0.0, "subtitle": "180s · teaches"},
	{"name": "Haul",     "time": 120.0, "par": 70.0, "friction": 2.5, "chicane": true,  "wind": 0.0, "subtitle": "120s · the shift"},
	{"name": "Night Run","time": 120.0, "par": 70.0, "friction": 1.8, "chicane": true,  "wind": 7.0, "subtitle": "120s · low grip, crosswind"},
]

# Palette
const INK := Color("e6edf6")
const STEEL := Color(0.62, 0.65, 0.7)
const LOST_RED := Color(0.85, 0.2, 0.15)
const DOCK_GREEN := Color("47d18c")
const AMBER := Color("ffb64d")
const SKY := Color("5cc8ff")

# Scene nodes
var truck: VehicleBody3D
var coils: Array[RigidBody3D] = []
var coil_mats: Array[StandardMaterial3D] = []
var lost: Dictionary = {}
var delivered: Dictionary = {}
var chock_shapes: Array[CollisionShape3D] = []
var chock_meshes: Array[MeshInstance3D] = []
var racks_on := false
var cam: Camera3D
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var chicane_bodies: Array[StaticBody3D] = []
var wheels: Array[VehicleWheel3D] = []
var headlights: Array[SpotLight3D] = []
var marker_lights: Array[MeshInstance3D] = []
var dust_l: CPUParticles3D
var dust_r: CPUParticles3D
var dock_ring: MeshInstance3D
var mill_sign: Label3D
var dock_sign: Label3D
var delivered_label: Label3D

# UI
var font_regular: FontFile
var font_bold: FontFile
var font_tnum: FontVariation
var font_bold_tnum: FontVariation
var ui_layer: CanvasLayer
var ui: Control

# State
var state: int = State.TITLE
var state_prev: int = State.TITLE
var settings: Dictionary = {}
var best_cfg: Dictionary = {}
var mode_ix: int = 1
var _buttons: Array = []
var first_input_received := false
var controls_fade_t := 0.0

# Match
var time_left := 0.0
var finished := false
var game_over := false
var grade := 1
var par_hit := false
var start_time := 0.0
var elapsed := 0.0
var clean_stops := 0
var delivery_t := 0.0
var in_dock := false

# Game-feel
var shake := 0.0
var shake_t := 0.0
var fov_t := 65.0
var vignette_t := 0.0
var banner_text := ""
var banner_t := 0.0
var cam_lead := Vector3.ZERO
var prev_speed := 0.0
var brake_coyote_t := 0.0
var prev_racks_on := false
var rng := RandomNumberGenerator.new()

# View
const VIEW := Vector2(1280, 720)


# ============================================================= lifecycle
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
	_build_environment()
	_build_world()
	truck = _build_truck()
	_spawn_coils()
	_set_racks(false)
	_build_camera()
	_build_hud()
	_apply_mode()
	_set_state(State.TITLE)


func _setup_input() -> void:
	var map := {
		"accelerate": [KEY_W, KEY_UP],
		"reverse":    [KEY_S, KEY_DOWN],
		"left":       [KEY_A, KEY_LEFT],
		"right":      [KEY_D, KEY_RIGHT],
		"brake":      [KEY_SPACE],
		"racks":      [KEY_R],
		"horn":       [KEY_H],
		"restart":    [KEY_ENTER],
		"pause":      [KEY_ESCAPE, KEY_P],
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
	if ui:
		ui.queue_redraw()


# ============================================================= helpers
func _mat(c: Color, metal := 0.0, emissive := false, e_energy := 1.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = 0.35 if metal > 0.0 else 0.85
	if emissive:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = e_energy
	return m


func _box_mesh(size: Vector3, pos: Vector3, color: Color, parent: Node, metal := 0.0, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(color, metal, emissive)
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
	return mi


func _static_box(size: Vector3, pos: Vector3, color: Color, rot_deg := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_box_mesh(size, Vector3.ZERO, color, body)
	body.position = pos
	body.rotation_degrees = rot_deg
	add_child(body)
	return body


func _sign_label(text: String, pos: Vector3, size := 160, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = font_bold
	l.font_size = size
	l.modulate = color
	l.outline_size = 16
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	add_child(l)
	return l


# ============================================================= world
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.18, 0.22, 0.42)
	sm.sky_horizon_color = Color(0.95, 0.55, 0.35)
	sm.ground_horizon_color = Color(0.75, 0.42, 0.3)
	sm.ground_bottom_color = Color(0.14, 0.11, 0.1)
	sm.sun_angle_max = 20.0
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.8
	env.ambient_light_energy = 0.45
	env.fog_enabled = true
	env.fog_light_color = Color(0.95, 0.6, 0.42)
	env.fog_density = 0.004
	env.fog_sun_scatter = 0.3
	env.glow_enabled = true
	env.glow_intensity = 0.5
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-18, 35, 0)
	sun.light_color = Color(1.0, 0.78, 0.58)
	sun.light_energy = 0.8
	sun.shadow_enabled = true
	add_child(sun)


func _build_world() -> void:
	# Ground + road
	_static_box(Vector3(400, 1, 700), Vector3(0, -0.5, -200), Color(0.26, 0.22, 0.18))
	_box_mesh(Vector3(14, 0.02, 290), Vector3(0, 0.01, -125), Color(0.12, 0.12, 0.14), self)
	for i in range(28):
		_box_mesh(Vector3(0.25, 0.03, 4), Vector3(0, 0.02, 5 - i * 10.0), Color(0.95, 0.75, 0.2), self)

	# Steel mill at the start
	_static_box(Vector3(40, 18, 14), Vector3(0, 9, 26), Color(0.3, 0.28, 0.28))
	_static_box(Vector3(3, 30, 3), Vector3(-14, 15, 30), Color(0.4, 0.3, 0.26))
	_static_box(Vector3(3, 26, 3), Vector3(-8, 13, 30), Color(0.4, 0.3, 0.26))
	# Mill marker lamp
	_box_mesh(Vector3(2.5, 0.5, 2.5), Vector3(-14, 30.3, 30), AMBER, self, 0.0, true)
	mill_sign = _sign_label("STEEL MILL", Vector3(0, 20, 18), 160, AMBER)

	# Speed bumps
	for z in [-35.0, -80.0, -170.0, -215.0]:
		_static_box(Vector3(14, 0.35, 1.2), Vector3(0, 0.1, z), Color(0.95, 0.75, 0.15))

	# Jersey-barrier chicane
	var side := 1.0
	for z in range(-105, -150, -12):
		var b := _static_box(Vector3(8, 1.2, 0.8), Vector3(3.2 * side, 0.6, z), Color(0.82, 0.82, 0.8))
		chicane_bodies.append(b)
		side = -side

	# Scenery
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in range(60):
		var x := r.randf_range(14, 120) * (1 if r.randf() > 0.5 else -1)
		var z := r.randf_range(-320, 10)
		var h := r.randf_range(2, 9)
		_box_mesh(Vector3(r.randf_range(2, 6), h, r.randf_range(2, 6)), Vector3(x, h / 2, z), Color(0.22, 0.19, 0.17).lerp(Color(0.4, 0.28, 0.22), r.randf()), self)

	# Delivery dock pad (solid)
	var pad := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 8
	cyl.bottom_radius = 8
	cyl.height = 0.05
	cyl.material = _mat(DOCK_GREEN, 0.0, true, 1.8)
	pad.mesh = cyl
	pad.position = DOCK_POS + Vector3(0, 0.03, 0)
	add_child(pad)

	# Pulsing ring (torus) at the dock
	dock_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 7.5
	torus.outer_radius = 8.3
	torus.material = _mat(DOCK_GREEN, 0.0, true, 2.2)
	dock_ring.mesh = torus
	dock_ring.position = DOCK_POS + Vector3(0, 0.08, 0)
	add_child(dock_ring)

	# Dock warehouse behind the pad
	_static_box(Vector3(24, 6, 6), DOCK_POS + Vector3(0, 3, -14), Color(0.22, 0.26, 0.34))
	# Side marker lamps around the dock
	for sx in [-9.0, 9.0]:
		_box_mesh(Vector3(0.6, 0.6, 0.6), DOCK_POS + Vector3(sx, 1.0, 0), DOCK_GREEN, self, 0.0, true)
	dock_sign = _sign_label("DOCK", DOCK_POS + Vector3(0, 9, -10), 160, DOCK_GREEN)

	# "DELIVERED" burst label (hidden until delivery)
	delivered_label = Label3D.new()
	delivered_label.text = "DELIVERED"
	delivered_label.font = font_bold
	delivered_label.font_size = 220
	delivered_label.modulate = DOCK_GREEN
	delivered_label.outline_size = 20
	delivered_label.outline_modulate = Color(0, 0, 0, 0.9)
	delivered_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	delivered_label.position = DOCK_POS + Vector3(0, 5, 0)
	delivered_label.visible = false
	add_child(delivered_label)


# ============================================================= truck
func _build_truck() -> VehicleBody3D:
	var v := VehicleBody3D.new()
	v.mass = 2500
	v.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	v.center_of_mass = Vector3(0, 0.3, 0.5)
	v.position = Vector3(0, 0.7, 0)
	v.rotation_degrees = Vector3(0, 180, 0)

	# Chassis / deck
	var deck := CollisionShape3D.new()
	var deck_box := BoxShape3D.new()
	deck_box.size = Vector3(2.5, 0.5, 9.0)
	deck.shape = deck_box
	deck.position = Vector3(0, 0.6, 0)
	v.add_child(deck)
	_box_mesh(Vector3(2.5, 0.5, 9.0), Vector3(0, 0.6, 0), Color(0.17, 0.18, 0.2), v, 0.4)
	_box_mesh(Vector3(2.52, 0.08, 6.8), Vector3(0, 0.86, -1.1), Color(0.38, 0.26, 0.17), v)

	# Cab
	var cab := CollisionShape3D.new()
	var cab_box := BoxShape3D.new()
	cab_box.size = Vector3(2.5, 2.1, 2.2)
	cab.shape = cab_box
	cab.position = Vector3(0, 1.9, 3.4)
	v.add_child(cab)
	_box_mesh(Vector3(2.5, 2.1, 2.2), Vector3(0, 1.9, 3.4), Color(0.7, 0.11, 0.09), v, 0.3)
	_box_mesh(Vector3(2.3, 0.8, 0.05), Vector3(0, 2.3, 4.51), Color(0.12, 0.2, 0.3), v, 0.6)

	# Headboard
	var head := CollisionShape3D.new()
	var head_box := BoxShape3D.new()
	head_box.size = Vector3(2.5, 1.8, 0.2)
	head.shape = head_box
	head.position = Vector3(0, 1.75, 2.2)
	v.add_child(head)
	_box_mesh(Vector3(2.5, 1.8, 0.2), Vector3(0, 1.75, 2.2), Color(0.25, 0.26, 0.3), v, 0.5)
	# Amber marker lights on the headboard top
	for mx in [-1.0, 1.0]:
		var m := _box_mesh(Vector3(0.3, 0.15, 0.3), Vector3(mx, 2.7, 2.2), AMBER, v, 0.0, true)
		marker_lights.append(m)

	# Red tail marker lights on deck rear
	for mx in [-1.1, 1.1]:
		_box_mesh(Vector3(0.3, 0.2, 0.1), Vector3(mx, 0.85, -4.6), LOST_RED, v, 0.0, true)

	# Permanent low cradles
	for z in COIL_Z:
		for dz in [0.42, -0.42]:
			var lip := CollisionShape3D.new()
			var lb := BoxShape3D.new()
			lb.size = Vector3(2.0, 0.1, 0.1)
			lip.shape = lb
			lip.position = Vector3(0, 0.9, z + dz)
			v.add_child(lip)
			_box_mesh(lb.size, lip.position, Color(0.09, 0.09, 0.09), v, 0.5)

	# Coil racks (chocks)
	for z in COIL_Z:
		for dz in [0.75, -0.75]:
			var cs := CollisionShape3D.new()
			var cb := BoxShape3D.new()
			cb.size = Vector3(2.0, 0.35, 0.25)
			cs.shape = cb
			cs.position = Vector3(0, 1.025, z + dz)
			v.add_child(cs)
			chock_shapes.append(cs)
			chock_meshes.append(_box_mesh(cb.size, cs.position, AMBER, v))

	# Wheels
	var wheel_data := [
		[Vector3(-1.25, 0.5, 3.2), true],
		[Vector3(1.25, 0.5, 3.2), true],
		[Vector3(-1.25, 0.5, -1.8), false],
		[Vector3(1.25, 0.5, -1.8), false],
		[Vector3(-1.25, 0.5, -3.2), false],
		[Vector3(1.25, 0.5, -3.2), false],
	]
	for data in wheel_data:
		var w := VehicleWheel3D.new()
		w.position = data[0]
		w.use_as_steering = data[1]
		w.use_as_traction = not data[1]
		w.wheel_radius = 0.55
		w.wheel_rest_length = 0.25
		w.suspension_travel = 0.3
		w.suspension_stiffness = 60.0
		w.suspension_max_force = 25000.0
		w.damping_compression = 1.2
		w.damping_relaxation = 1.8
		w.wheel_friction_slip = 2.5
		var wm := MeshInstance3D.new()
		var tire := CylinderMesh.new()
		tire.top_radius = 0.55
		tire.bottom_radius = 0.55
		tire.height = 0.42
		tire.material = _mat(Color(0.05, 0.05, 0.05))
		wm.mesh = tire
		wm.rotation_degrees = Vector3(0, 0, 90)
		w.add_child(wm)
		v.add_child(w)
		wheels.append(w)

	# Headlights (two SpotLight3Ds on the cab, forward = cab local -Z before 180° rotation,
	# but after the chassis 180° yaw, forward is still local -Z of the truck body which points along world -Z).
	# Actually: a VehicleBody3D defaults to driving along +Z; we rotated 180°, so "forward" is now its local -Z.
	# A SpotLight3D emits along local -Z. So pointing it along the truck's local -Z shines forward.
	for sx in [-0.9, 0.9]:
		var sp := SpotLight3D.new()
		sp.position = Vector3(sx, 1.4, 4.3)
		sp.light_color = Color(1.0, 0.95, 0.8)
		sp.light_energy = 6.0
		sp.spot_range = 60.0
		sp.spot_angle = 42.0
		sp.spot_angle_attenuation = 0.4
		# Truck is yawed 180° on Y; motion runs along the body's local +Z.
		# SpotLight3D emits along local -Z, so yaw it 180° to point forward.
		sp.rotation_degrees = Vector3(-8, 180, 0)
		v.add_child(sp)
		headlights.append(sp)
		# Lens disc on the cab
		_box_mesh(Vector3(0.4, 0.3, 0.05), Vector3(sx, 1.4, 4.51), Color(1.0, 0.95, 0.78), v, 0.0, true)

	# Dust emitters behind rear axles
	dust_l = _make_dust()
	dust_l.position = Vector3(-1.25, 0.1, -3.6)
	v.add_child(dust_l)
	dust_r = _make_dust()
	dust_r.position = Vector3(1.25, 0.1, -3.6)
	v.add_child(dust_r)

	add_child(v)
	return v


func _make_dust() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 24
	p.lifetime = 0.6
	p.one_shot = false
	p.preprocess = 0.0
	p.speed_scale = 1.0
	p.explosiveness = 0.0
	p.randomness = 0.4
	p.local_coords = false
	var sph := SphereMesh.new()
	sph.radius = 0.12
	sph.height = 0.24
	sph.radial_segments = 6
	sph.rings = 3
	p.mesh = sph
	p.direction = Vector3(0, 1, 0)
	p.spread = 60.0
	p.gravity = Vector3(0, -1.6, 0)
	p.initial_velocity_min = 1.4
	p.initial_velocity_max = 2.6
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	p.color = Color(0.58, 0.46, 0.34, 0.55)
	return p


func _spawn_coils() -> void:
	for z in COIL_Z:
		var c := RigidBody3D.new()
		c.mass = 250.0
		var pm := PhysicsMaterial.new()
		pm.friction = 0.8
		pm.bounce = 0.05
		c.physics_material_override = pm
		c.continuous_cd = true
		c.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		c.angular_damp = 2.5

		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.7
		shape.height = 1.2
		cs.shape = shape
		cs.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(cs)

		var outer := MeshInstance3D.new()
		var om := CylinderMesh.new()
		om.top_radius = 0.7
		om.bottom_radius = 0.7
		om.height = 1.2
		var outer_mat := _mat(STEEL, 0.9)
		om.material = outer_mat
		outer.mesh = om
		outer.rotation_degrees = Vector3(0, 0, 90)
		outer.name = "Outer"
		c.add_child(outer)
		coil_mats.append(outer_mat)

		var eye := MeshInstance3D.new()
		var em := CylinderMesh.new()
		em.top_radius = 0.28
		em.bottom_radius = 0.28
		em.height = 1.22
		em.material = _mat(Color(0.06, 0.06, 0.07))
		eye.mesh = em
		eye.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(eye)

		c.position = truck.transform * Vector3(0, 1.57, z)
		add_child(c)
		coils.append(c)


func _reset_coils() -> void:
	for i in range(coils.size()):
		var c := coils[i]
		c.linear_velocity = Vector3.ZERO
		c.angular_velocity = Vector3.ZERO
		c.position = truck.transform * Vector3(0, 1.57, COIL_Z[i])
		c.rotation = Vector3.ZERO
		coil_mats[i].albedo_color = STEEL
		coil_mats[i].emission_enabled = false


func _reset_truck() -> void:
	truck.linear_velocity = Vector3.ZERO
	truck.angular_velocity = Vector3.ZERO
	truck.position = Vector3(0, 0.7, 0)
	truck.rotation_degrees = Vector3(0, 180, 0)
	truck.engine_force = 0.0
	truck.brake = 0.0
	truck.steering = 0.0


func _set_racks(on: bool) -> void:
	racks_on = on
	for cs in chock_shapes:
		cs.disabled = not on
	for m in chock_meshes:
		m.visible = on


# ============================================================= camera + hud
func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 65
	add_child(cam)
	cam.global_position = truck.global_position + Vector3(0, 7, 15)
	cam.look_at(truck.global_position)


func _build_hud() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_PASS
	ui.process_mode = Node.PROCESS_MODE_ALWAYS
	ui.draw.connect(_on_ui_draw)
	ui_layer.add_child(ui)


func _on_ui_draw() -> void:
	_buttons.clear()
	match state:
		State.TITLE:    _dim(0.55); _draw_title()
		State.HOW_TO:   _dim(0.6);  _draw_how_to()
		State.PLAY:     _draw_hud()
		State.PAUSE:    _dim(0.5);  _draw_pause()
		State.SETTINGS: _dim(0.6);  _draw_settings()
		State.RESULTS:  _dim(0.6);  _draw_results()


func _dim(a: float) -> void:
	ui.draw_rect(Rect2(Vector2.ZERO, VIEW), Color(0, 0, 0, a))


# ============================================================= mode / match
func _apply_mode() -> void:
	var m: Dictionary = MODES[mode_ix]
	for w in wheels:
		w.wheel_friction_slip = float(m.friction)
	for b in chicane_bodies:
		b.visible = bool(m.chicane)
		for c in b.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = not bool(m.chicane)


func _reset_match() -> void:
	var m: Dictionary = MODES[mode_ix]
	time_left = float(m.time)
	finished = false
	game_over = false
	grade = 1
	par_hit = false
	elapsed = 0.0
	clean_stops = 0
	delivery_t = 0.0
	in_dock = false
	lost.clear()
	delivered.clear()
	shake = 0.0
	shake_t = 0.0
	vignette_t = 0.0
	fov_t = 65.0
	banner_text = ""
	banner_t = 0.0
	cam_lead = Vector3.ZERO
	prev_speed = 0.0
	brake_coyote_t = 0.0
	_reset_truck()
	_reset_coils()
	_set_racks(false)
	delivered_label.visible = false
	_apply_mode()


func _begin_match() -> void:
	_reset_match()
	_set_state(State.PLAY)
	SFX.confirm()
	best_cfg["last_mode"] = mode_ix
	_save_best()


func _restart_match() -> void:
	_reset_match()
	_set_state(State.PLAY)


# ============================================================= input
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
					ui.queue_redraw()
			State.PLAY:
				if finished:
					if event.physical_keycode == KEY_ENTER:
						_set_state(State.RESULTS)
				elif event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
					SFX.click()
					_set_state(State.PAUSE)
				elif event.physical_keycode == KEY_ENTER:
					_restart_match()
				elif event.physical_keycode == KEY_H:
					SFX.kaching()
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
	# Positions are in actual window coords; our UI draws in VIEW space (1280x720).
	# canvas_items stretch scales for us — the Control.PRESET_FULL_RECT already matches.
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
		"mode_0": mode_ix = 0; ui.queue_redraw()
		"mode_1": mode_ix = 1; ui.queue_redraw()
		"mode_2": mode_ix = 2; ui.queue_redraw()
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


# ============================================================= loop
func _physics_process(delta: float) -> void:
	if state != State.PLAY or finished:
		return

	var speed := truck.linear_velocity.length()
	var throttle := Input.get_action_strength("accelerate") - Input.get_action_strength("reverse")
	var steer_in := Input.get_action_strength("left") - Input.get_action_strength("right")
	truck.steering = move_toward(truck.steering, steer_in * MAX_STEER, delta * 1.6)
	truck.engine_force = throttle * ENGINE_FORCE if speed < MAX_SPEED else 0.0

	# Brake coyote
	if Input.is_action_just_pressed("brake"):
		brake_coyote_t = BRAKE_COYOTE
	brake_coyote_t = maxf(0.0, brake_coyote_t - delta)
	var braking: bool = Input.is_action_pressed("brake") or brake_coyote_t > 0.0
	truck.brake = BRAKE_FORCE if braking else 0.0

	# Night Run crosswind — tiny but noticeable
	var m: Dictionary = MODES[mode_ix]
	var wind_m: float = float(m.wind)
	if wind_m > 0.0:
		var gust := wind_m * (0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.0007))
		truck.apply_central_force(Vector3(gust * 180.0, 0, 0))

	# Racks toggle (one-shot)
	if Input.is_action_just_pressed("racks"):
		if speed < 1.0:
			_set_racks(not racks_on)
			if racks_on:
				time_left -= 5.0
				_banner("RACKS SET  -5s", 1.0)
				SFX.confirm()
			else:
				_banner("RACKS OFF", 0.8)
				SFX.click()
		else:
			_banner("STOP to set racks", 1.0)

	_check_coils()

	# Clean-stop reward: hard decel + racks on + no coils lost in last beat
	var decel := (prev_speed - speed) / maxf(delta, 0.0001)
	if decel > CLEAN_STOP_DECEL and racks_on and speed < 2.0 and prev_speed > 10.0 and lost.is_empty():
		clean_stops += 1
		_flash_clean_stop()
	prev_speed = speed
	prev_racks_on = racks_on

	# Dock delivery ring
	var dist := truck.global_position.distance_to(DOCK_POS)
	in_dock = dist < 8.5 and speed < 2.2
	var all_coils_on_deck := _coils_on_deck() == coils.size() - lost.size()
	if in_dock and all_coils_on_deck and not lost.size() == coils.size():
		delivery_t = minf(DELIVERY_TIME, delivery_t + delta)
		if delivery_t >= DELIVERY_TIME:
			_do_delivery()
	else:
		delivery_t = maxf(0.0, delivery_t - delta * 2.0)

	# Clock
	time_left -= delta
	elapsed += delta
	if time_left <= 0.0:
		time_left = 0.0
		_finish(false, "OUT OF TIME")
	elif lost.size() == coils.size():
		_finish(false, "ALL COILS LOST")


func _coils_on_deck() -> int:
	var n := 0
	for c in coils:
		if lost.has(c) or delivered.has(c):
			continue
		var p := truck.to_local(c.global_position)
		if absf(p.x) < 1.8 and p.y > 0.6 and p.y < 3.5 and p.z > -5.2 and p.z < 2.6:
			n += 1
	return n


func _check_coils() -> void:
	var speed := truck.linear_velocity.length()
	for i in range(coils.size()):
		var c := coils[i]
		if lost.has(c) or delivered.has(c):
			continue
		var p := truck.to_local(c.global_position)
		var on_deck := absf(p.x) < 1.8 and p.y > 0.6 and p.y < 3.5 and p.z > -5.2 and p.z < 2.6
		if not on_deck:
			lost[c] = true
			coil_mats[i].albedo_color = LOST_RED
			coil_mats[i].emission_enabled = true
			coil_mats[i].emission = LOST_RED * 0.4
			coil_mats[i].emission_energy_multiplier = 1.0
			_banner("COIL LOST", 1.4)
			_impact(10.0)
			vignette_t = 0.6
			SFX.fail()


func _impact(mag: float) -> void:
	if settings.get("reduced_motion", false):
		return
	shake = maxf(shake, mag)
	shake_t = 0.4


func _flash_clean_stop() -> void:
	banner_text = "+1 CLEAN STOP"
	banner_t = 1.0
	SFX.success()


func _banner(t: String, dur: float) -> void:
	banner_text = t
	banner_t = dur


func _do_delivery() -> void:
	var remaining: Array = []
	for c in coils:
		if not lost.has(c) and not delivered.has(c):
			remaining.append(c)
	if remaining.is_empty():
		return
	for c in remaining:
		delivered[c] = true
		# Fade coil out visually: send it to the dock
		c.freeze = true
		c.position = DOCK_POS + Vector3(rng.randf_range(-3, 3), 1.0 + rng.randf() * 0.5, rng.randf_range(-3, 3))
	SFX.success()
	SFX.kaching()
	delivered_label.visible = true
	get_tree().create_timer(1.6).timeout.connect(func(): if is_instance_valid(delivered_label): delivered_label.visible = false)
	var any_lost := lost.size() > 0
	_finish(true, "CLEAN LOAD" if not any_lost else "PARTIAL DELIVERY")


func _finish(ok: bool, label: String) -> void:
	if finished:
		return
	finished = true
	var m: Dictionary = MODES[mode_ix]
	var any_lost := lost.size() > 0
	var all_lost := lost.size() == coils.size()
	par_hit = ok and elapsed <= float(m.par) and not any_lost
	if all_lost or not ok:
		grade = 1
	elif ok and not any_lost and par_hit:
		grade = 3
	else:
		grade = 2
	_banner(label, 2.0)
	# Save best per mode
	var key := "mode_%d" % mode_ix
	var row: Dictionary = best_cfg.get(key, {"grade": 0, "elapsed": 9999.0, "clean_stops": 0})
	row.grade = maxi(int(row.grade), grade)
	if ok and (float(row.elapsed) > elapsed or int(row.elapsed) == 0):
		row.elapsed = elapsed
	row.clean_stops = maxi(int(row.clean_stops), clean_stops)
	best_cfg[key] = row
	_save_best()
	get_tree().create_timer(1.4).timeout.connect(func(): if state == State.PLAY: _set_state(State.RESULTS))


# ============================================================= per-frame
func _process(delta: float) -> void:
	# UI timers always run (even paused via ALWAYS process_mode on ui, but main here is ALWAYS too).
	if banner_t > 0.0:
		banner_t = maxf(0.0, banner_t - delta)
		if banner_t <= 0.0:
			banner_text = ""
	if vignette_t > 0.0:
		vignette_t = maxf(0.0, vignette_t - delta * 1.6)
	if controls_fade_t > 0.0:
		controls_fade_t = maxf(0.0, controls_fade_t - delta)

	# Shake decay
	if shake_t > 0.0:
		shake_t = maxf(0.0, shake_t - delta)
		var k := shake_t / 0.4
		shake = shake * (0.9 if settings.get("reduced_motion", false) else 1.0)
		var amp := shake * k * k
		if settings.get("reduced_motion", false):
			amp = 0.0
		cam.h_offset = rng.randf_range(-amp, amp) * 0.02
		cam.v_offset = rng.randf_range(-amp, amp) * 0.02
	else:
		cam.h_offset = 0.0
		cam.v_offset = 0.0

	# Dock ring pulse
	if dock_ring:
		if settings.get("reduced_motion", false):
			dock_ring.scale = Vector3.ONE
		else:
			var p := 1.0 + sin(Time.get_ticks_msec() * 0.004) * 0.07
			dock_ring.scale = Vector3(p, 1.0, p)

	# Camera: chase cam with speed-based lead + FOV lean.
	# Truck yawed 180° on Y → its local +Z (direction of motion) is world -Z.
	# truck.global_transform.basis.z gives that direction; follow from behind along -fwd.
	if truck:
		var fwd := truck.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.001:
			fwd = fwd.normalized()
		var speed := truck.linear_velocity.length()
		var lead_target: Vector3 = fwd * clampf(speed * 0.4, 0.0, 10.0)
		if settings.get("reduced_motion", false):
			lead_target = Vector3.ZERO
		cam_lead = cam_lead.lerp(lead_target, clampf(delta * 3.0, 0.0, 1.0))
		var target := truck.global_position + cam_lead
		var desired := target - fwd * 15.0 + Vector3.UP * 6.5
		cam.global_position = cam.global_position.lerp(desired, 1.0 - exp(-delta * 4.0))
		cam.look_at(target + Vector3.UP * 1.5, Vector3.UP)

		# FOV widens 2° over 40mph (~17.9 m/s)
		var mph := speed * 2.237
		var target_fov := 65.0
		if not settings.get("reduced_motion", false):
			target_fov = 65.0 + clampf((mph - 20.0) / 20.0, 0.0, 1.0) * 2.0
		fov_t = lerp(fov_t, target_fov, clampf(delta * 2.5, 0.0, 1.0))
		cam.fov = fov_t

		# Dust: emit when accelerating & grounded & moving
		var accel_on := Input.get_action_strength("accelerate") > 0.1
		var emit := accel_on and speed > 1.0 and state == State.PLAY and not finished
		dust_l.emitting = emit
		dust_r.emitting = emit

	ui.queue_redraw()


# ============================================================= drawing
func _text(pos: Vector2, s: String, size: int = UI.TYPE_BODY, color: Color = INK, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, bold: bool = false, tnum: bool = false) -> void:
	var f: Font
	if bold:
		f = font_bold_tnum if tnum else font_bold
	else:
		f = font_tnum if tnum else font_regular
	ui.draw_string(f, pos, s, align, width, size, color)


func _button(id: String, rect: Rect2, label: String, primary: bool = false, size: int = UI.TYPE_BODY) -> void:
	var fill: Color = Color(AMBER.r, AMBER.g, AMBER.b, 0.22) if primary else UI.PANEL_FILL
	var border: Color = Color(AMBER.r, AMBER.g, AMBER.b, 0.9) if primary else UI.PANEL_BORDER
	UI.draw_panel(ui, rect, 12.0, fill, border)
	var tx: Vector2 = rect.position + Vector2(0, rect.size.y * 0.5 + size * 0.33)
	_text(tx, label, size, INK, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, primary)
	_buttons.append({"rect": rect, "id": id})


func _toggle(id: String, pos: Vector2, label: String, on: bool) -> void:
	var r := Rect2(pos, Vector2(500, 36))
	UI.draw_panel(ui, r, 10.0, UI.PANEL_FILL, UI.PANEL_BORDER)
	var knob := Rect2(r.position + Vector2(r.size.x - 56, 6), Vector2(42, 24))
	UI.draw_panel(ui, knob, 12.0, Color(AMBER.r, AMBER.g, AMBER.b, 0.9) if on else Color(1, 1, 1, 0.10), UI.PANEL_BORDER)
	ui.draw_circle(knob.position + Vector2(30 if on else 12, 12), 9, INK)
	_text(r.position + Vector2(16, 23), label, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, false)
	_buttons.append({"rect": r, "id": id})


# ---- HUD -------------------------------------------------------------------
func _draw_hud() -> void:
	var speed := truck.linear_velocity.length() if truck else 0.0
	var mph := int(roundf(speed * 2.237))
	var kph := int(roundf(speed * 3.6))

	# Speed chip top-left
	var sp_chip := Rect2(20, 20, 200, 92)
	UI.draw_panel(ui, sp_chip, 14.0, Color(0, 0, 0, 0.35), UI.PANEL_BORDER)
	_text(sp_chip.position + Vector2(18, 28), "SPEED", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(sp_chip.position + Vector2(18, 70), "%d" % mph, UI.TYPE_HUD, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(sp_chip.position + Vector2(118, 70), "MPH", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(sp_chip.position + Vector2(118, 86), "%d km/h" % kph, UI.TYPE_CAPTION, Color(INK, 0.5))

	# Clock + distance top-right
	var cl_chip := Rect2(VIEW.x - 220, 20, 200, 92)
	UI.draw_panel(ui, cl_chip, 14.0, Color(0, 0, 0, 0.35), UI.PANEL_BORDER)
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 28), "CLOCK", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, -1, true)
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 70), UI.mmss(time_left), UI.TYPE_HUD, INK, HORIZONTAL_ALIGNMENT_RIGHT, -1, true, true)
	var dist := int(truck.global_position.distance_to(DOCK_POS)) if truck else 0
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 86), "DOCK %dm" % dist, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_RIGHT)

	# Coil chip row (top-center)
	var chip_w := 44.0 * coils.size() + 20.0
	var row := Rect2(VIEW.x * 0.5 - chip_w * 0.5, 20, chip_w, 44)
	UI.draw_panel(ui, row, 14.0, Color(0, 0, 0, 0.35), UI.PANEL_BORDER)
	for i in range(coils.size()):
		var cx := row.position.x + 22 + i * 44.0
		var cy := row.position.y + 22.0
		var color: Color
		if delivered.has(coils[i]):
			color = DOCK_GREEN
		elif lost.has(coils[i]):
			color = LOST_RED
		else:
			color = STEEL
		ui.draw_circle(Vector2(cx, cy), 10.0, color)
		ui.draw_arc(Vector2(cx, cy), 10.0, 0, TAU, 20, Color(0, 0, 0, 0.55), 1.5, true)
		ui.draw_circle(Vector2(cx, cy), 3.0, Color(0.05, 0.05, 0.07))

	# Mode name + clean-stops under coil row
	var mode_label := "%s" % MODES[mode_ix].name
	if clean_stops > 0:
		mode_label += " · %d CLEAN" % clean_stops
	_text(Vector2(VIEW.x * 0.5, 86), mode_label, UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER)

	# Racks pill bottom-center
	var pill_w := 240.0
	var pill := Rect2(VIEW.x * 0.5 - pill_w * 0.5, VIEW.y - 60, pill_w, 36)
	var pill_fill: Color = Color(DOCK_GREEN.r, DOCK_GREEN.g, DOCK_GREEN.b, 0.22) if racks_on else Color(AMBER.r, AMBER.g, AMBER.b, 0.22)
	var pill_border: Color = DOCK_GREEN if racks_on else AMBER
	UI.draw_panel(ui, pill, 18.0, pill_fill, pill_border)
	var pill_text := "RACKS SET" if racks_on else "RACKS OFF · STOP + R"
	_text(pill.position + Vector2(0, 24), pill_text, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, pill.size.x, true)

	# Delivery ring (when in dock)
	if delivery_t > 0.0:
		var frac := delivery_t / DELIVERY_TIME
		var center := Vector2(VIEW.x * 0.5, VIEW.y * 0.5 + 40)
		UI.draw_ring_bg(ui, center, 60.0, Color(1, 1, 1, 0.15), 5.0)
		UI.draw_ring(ui, center, 60.0, frac, DOCK_GREEN, 6.0)
		_text(Vector2(0, VIEW.y * 0.5 + 118), "DELIVERING", UI.TYPE_BODY, DOCK_GREEN, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true)

	# Red vignette flash on coil loss
	if vignette_t > 0.0:
		var a: float = clampf(vignette_t * 0.6, 0.0, 0.6)
		_vignette(a)

	# Banner
	if banner_text != "":
		var a: float = clampf(banner_t * 2.0, 0.0, 1.0)
		var size: int = UI.TYPE_TITLE + 2
		var bg_h := 70.0
		var bg_y := VIEW.y * 0.42
		ui.draw_rect(Rect2(0, bg_y, VIEW.x, bg_h), Color(0, 0, 0, 0.35 * a))
		_text(Vector2(0, bg_y + 48), banner_text, size, Color(INK.r, INK.g, INK.b, 0.75 + 0.25 * a), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true, true)

	# Finished banner
	if finished:
		_dim(0.35)
		_text(Vector2(0, VIEW.y * 0.5 - 8), banner_text if banner_text != "" else "RUN COMPLETE", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true, true)
		_text(Vector2(0, VIEW.y * 0.5 + 24), "ENTER for results", UI.TYPE_BODY, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)

	# Controls hint
	_draw_controls_hint()


func _vignette(a: float) -> void:
	# 4 red bands fading inward.
	var layers := 6
	for i in range(layers):
		var t: float = float(i) / layers
		var band := 60.0 * (1.0 - t)
		var col := Color(LOST_RED.r, LOST_RED.g, LOST_RED.b, a * (0.08 + 0.12 * (1.0 - t)))
		ui.draw_rect(Rect2(0, i * band, VIEW.x, band), col)
		ui.draw_rect(Rect2(0, VIEW.y - (i + 1) * band, VIEW.x, band), col)


func _draw_controls_hint() -> void:
	if not settings.get("show_controls", true):
		return
	var alpha := 1.0
	if first_input_received:
		alpha = clampf(controls_fade_t / 3.0, 0.0, 1.0)
	if alpha <= 0.0:
		return
	var chips := [
		"W/S drive",
		"A/D steer",
		"SPACE brake",
		"R racks (stop first)",
		"H horn",
		"ESC pause",
	]
	var x := 20.0
	var y := VIEW.y - 100.0
	for c in chips:
		var w: float = font_regular.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.TYPE_CAPTION).x + 20
		var r := Rect2(x, y, w, 22)
		UI.draw_panel(ui, r, 10.0, Color(1, 1, 1, 0.08 * alpha), Color(1, 1, 1, 0.15 * alpha))
		_text(Vector2(x + 10, y + 15), c, UI.TYPE_CAPTION, Color(INK.r, INK.g, INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		x += w + 8


# ---- title -----------------------------------------------------------------
func _draw_title() -> void:
	var card := Rect2(80, 90, 560, 480)
	UI.draw_card(ui, card, AMBER)
	_text(card.position + Vector2(28, 60), "FLATBED HAULER", UI.TYPE_TITLE + 8, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(card.position + Vector2(28, 92), "4 coils to the dock.", UI.TYPE_BODY, Color(INK, 0.8))

	_text(card.position + Vector2(28, 136), "MODE", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(MODES.size()):
		var r := Rect2(card.position.x + 28 + i * 170, card.position.y + 156, 160, 72)
		var sel: bool = i == mode_ix
		var fill: Color = Color(AMBER.r, AMBER.g, AMBER.b, 0.20) if sel else UI.PANEL_FILL
		var bor: Color = Color(AMBER.r, AMBER.g, AMBER.b, 0.9) if sel else UI.PANEL_BORDER
		UI.draw_panel(ui, r, 10.0, fill, bor)
		_text(r.position + Vector2(0, 26), MODES[i].name, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, sel)
		_text(r.position + Vector2(10, 48), MODES[i].subtitle, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20)
		_buttons.append({"rect": r, "id": "mode_%d" % i})

	var by: float = card.position.y + 260
	_button("play",     Rect2(card.position.x + 28,  by, 220, 54), "Play", true, UI.TYPE_HEADLINE)
	_button("how_to",   Rect2(card.position.x + 264, by, 160, 54), "How to play")
	_button("settings", Rect2(card.position.x + 28,  by + 72, 160, 44), "Settings")

	var row: Dictionary = best_cfg.get("mode_%d" % mode_ix, {})
	if not row.is_empty():
		var best_t := float(row.get("elapsed", 0.0))
		var g := int(row.get("grade", 0))
		var line := "Best · "
		if best_t > 0.0:
			line += UI.mmss(best_t) + " · "
		line += "%d★" % g
		_text(card.position + Vector2(28, 420), line, UI.TYPE_CAPTION, Color(INK, 0.7))

	# Right info card
	var info := Rect2(680, 90, 520, 410)
	UI.draw_panel(ui, info)
	_text(info.position + Vector2(24, 36), "WHAT THIS SHOWS", UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var bullets := [
		"VehicleBody3D truck, 6 wheels, tandem drive.",
		"4 steel coils roll on hard braking and bumps.",
		"R sets coil racks when stopped. -5 seconds.",
		"Dock delivery holds for a beat, then counts.",
		"Night Run drops friction and adds crosswind.",
		"Procedural audio, headlights, dust.",
	]
	var yy: float = info.position.y + 70
	for b in bullets:
		_text(Vector2(info.position.x + 24, yy), "·  " + b, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, info.size.x - 48)
		yy += 28

	# Driver note
	var note := Rect2(80, VIEW.y - 86, VIEW.x - 160, 56)
	UI.draw_panel(ui, note, 10.0, Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.10))
	_text(note.position + Vector2(0, 32), "Rolling steel, headboard physics, coil racks. Everything simulated in VehicleBody3D.", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, note.size.x)


# ---- how to ----------------------------------------------------------------
func _draw_how_to() -> void:
	var r := Rect2(220, 90, 840, 540)
	UI.draw_card(ui, r, AMBER)
	_text(r.position + Vector2(28, 54), "HOW TO HAUL", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	var lines := [
		"W or S drive. A or D steer. SPACE brakes.",
		"Stop the truck and press R to set coil racks. Takes 5 seconds off the clock.",
		"Hard stops, speed bumps and the chicane will roll your coils if the racks are off.",
		"Pull up on the green dock pad and hold still. The ring fills in 1.2s.",
		"Deliver all 4 and beat par for 3 stars. A lost coil is a claim.",
		"H sounds the horn. ESC pauses. Reduced motion is in Settings.",
	]
	var yy: float = r.position.y + 110
	for l in lines:
		_text(Vector2(r.position.x + 28, yy), "·  " + l, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 56)
		yy += 32
	_button("back", Rect2(r.position.x + r.size.x - 180, r.position.y + r.size.y - 70, 140, 44), "Back")


# ---- pause -----------------------------------------------------------------
func _draw_pause() -> void:
	var r := Rect2(VIEW.x * 0.5 - 180, 180, 360, 320)
	UI.draw_card(ui, r, AMBER)
	_text(r.position + Vector2(0, 60), "PAUSED", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_button("resume",   Rect2(r.position.x + 40, r.position.y + 100, r.size.x - 80, 44), "Resume", true)
	_button("restart",  Rect2(r.position.x + 40, r.position.y + 150, r.size.x - 80, 44), "Restart run")
	_button("settings_from_pause", Rect2(r.position.x + 40, r.position.y + 200, r.size.x - 80, 44), "Settings")
	_button("quit_to_title", Rect2(r.position.x + 40, r.position.y + 250, r.size.x - 80, 44), "Quit to title")


# ---- settings --------------------------------------------------------------
func _draw_settings() -> void:
	var r := Rect2(360, 110, 560, 480)
	UI.draw_card(ui, r, AMBER)
	_text(r.position + Vector2(28, 50), "SETTINGS", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_text(r.position + Vector2(28, 110), "Volume", UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_button("vol_down", Rect2(r.position.x + 28, r.position.y + 125, 34, 32), "-")
	_button("vol_up",   Rect2(r.position.x + 68, r.position.y + 125, 34, 32), "+")
	var bar := Rect2(r.position.x + 118, r.position.y + 136, 300, 10)
	UI.draw_panel(ui, bar, 5.0, Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.14))
	ui.draw_rect(Rect2(bar.position, Vector2(bar.size.x * settings.volume, bar.size.y)), AMBER)
	_text(Vector2(r.position.x + 428, r.position.y + 148), "%d%%" % int(settings.volume * 100), UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_toggle("mute_toggle",    r.position + Vector2(28, 180), "Mute all audio", settings.mute)
	_toggle("reduced_motion", r.position + Vector2(28, 230), "Reduced motion", settings.reduced_motion)
	_toggle("colorblind",     r.position + Vector2(28, 280), "Colorblind palette", settings.colorblind)
	_toggle("show_controls",  r.position + Vector2(28, 330), "Show on-screen controls", settings.show_controls)

	_button("back", Rect2(r.position.x + r.size.x - 150, r.position.y + r.size.y - 70, 120, 44), "Back")


# ---- results ---------------------------------------------------------------
func _draw_results() -> void:
	var r := Rect2(260, 80, 760, 560)
	UI.draw_card(ui, r, AMBER)
	var title: String
	match grade:
		3: title = "CLEAN LOAD"
		2: title = "GOOD RUN"
		_: title = "SHORT HAUL"
	_text(r.position + Vector2(0, 72), title, UI.TYPE_TITLE + 6, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Stars
	var sx: float = r.position.x + r.size.x * 0.5 - 60
	for i in range(3):
		var filled: bool = i < grade
		var col: Color = AMBER if filled else Color(INK, 0.3)
		_draw_star(Vector2(sx + i * 50, r.position.y + 128), 18.0, col, filled)

	var cy: float = r.position.y + 190
	var on_truck := coils.size() - lost.size()
	var m: Dictionary = MODES[mode_ix]
	_text(Vector2(r.position.x, cy),       "%d / %d coils delivered" % [on_truck, coils.size()], UI.TYPE_HEADLINE, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_text(Vector2(r.position.x, cy + 40),  "Time %s · par %s" % [UI.mmss(elapsed), UI.mmss(float(m.par))], UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 68),  "Clean stops %d" % clean_stops, UI.TYPE_BODY, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 100), "Mode · %s" % MODES[mode_ix].name, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	var row: Dictionary = best_cfg.get("mode_%d" % mode_ix, {})
	if not row.is_empty():
		var best_t := float(row.get("elapsed", 0.0))
		var g := int(row.get("grade", 0))
		var cs := int(row.get("clean_stops", 0))
		var line := "Best · "
		if best_t > 0.0:
			line += UI.mmss(best_t) + " · "
		line += "%d★ · clean %d" % [g, cs]
		_text(Vector2(r.position.x, cy + 134), line, UI.TYPE_CAPTION, Color(INK, 0.6), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	_button("restart",    Rect2(r.position.x + r.size.x * 0.5 - 230, r.position.y + r.size.y - 86, 200, 50), "Run it again", true)
	_button("play_again", Rect2(r.position.x + r.size.x * 0.5 + 30,  r.position.y + r.size.y - 86, 200, 50), "Back to title")


func _draw_star(center: Vector2, r: float, color: Color, filled: bool) -> void:
	var pts := PackedVector2Array()
	for i in range(10):
		var a: float = -PI / 2.0 + i * PI / 5.0
		var rr: float = r if i % 2 == 0 else r * 0.45
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	if filled:
		ui.draw_colored_polygon(pts, color)
	else:
		pts.append(pts[0])
		ui.draw_polyline(pts, color, 1.5, true)


# ============================================================= save/load
func _load_best() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {"last_mode": 1}
	if cfg.load("user://flatbed_best.cfg") != OK:
		return out
	out["last_mode"] = cfg.get_value("meta", "last_mode", 1)
	for i in range(MODES.size()):
		var key := "mode_%d" % i
		if cfg.has_section(key):
			out[key] = {
				"grade": cfg.get_value(key, "grade", 0),
				"elapsed": cfg.get_value(key, "elapsed", 0.0),
				"clean_stops": cfg.get_value(key, "clean_stops", 0),
			}
	return out


func _save_best() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "last_mode", int(best_cfg.get("last_mode", 1)))
	for i in range(MODES.size()):
		var key := "mode_%d" % i
		if best_cfg.has(key):
			var row: Dictionary = best_cfg[key]
			cfg.set_value(key, "grade", int(row.get("grade", 0)))
			cfg.set_value(key, "elapsed", float(row.get("elapsed", 0.0)))
			cfg.set_value(key, "clean_stops", int(row.get("clean_stops", 0)))
	cfg.save("user://flatbed_best.cfg")
