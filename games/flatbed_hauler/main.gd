extends Node3D
## FLATBED HAULER v2 — Dynamo portfolio.
## Haul steel from the mill to the dock. Rolling physics, cargo racks,
## cliff road, arcade high-score table. Shared ui_kit + sfx autoload.

const UI = preload("res://ui_kit.gd")

enum State { TITLE, HOW_TO, PLAY, PAUSE, SETTINGS, RESULTS, SCORES, NAME_ENTRY }

# Cargo kinds
const CARGO_COILS := "coils"
const CARGO_PIPES := "pipes"

# Coil layout (across-deck cylinders, roll fore/aft)
const COIL_Z := [1.2, -0.4, -2.0, -3.6]
const COIL_RADIUS := 0.7
const COIL_HEIGHT := 1.2
const COIL_MASS := 250.0

# Pipe layout (lengthwise cylinders, roll side to side)
const PIPE_X := [-0.75, 0.0, 0.75]
const PIPE_Z_CENTER := -1.1
const PIPE_RADIUS := 0.3
const PIPE_LENGTH := 5.0
const PIPE_MASS := 180.0

const DOCK_POS := Vector3(0, 0, -260)
const ENGINE_FORCE := 5000.0
const BRAKE_FORCE := 40.0
const MAX_SPEED := 24.0
const MAX_STEER := 0.45
const BRAKE_COYOTE := 0.06
const DELIVERY_TIME := 1.2
const CLEAN_STOP_DECEL := 8.0
const FALL_KILL_Y := -4.0
const ROAD_HALF_WIDTH := 11.0  # 22m wide road platform

const MODES := [
	{"name": "Yard",     "time": 180.0, "par": 90.0, "friction": 2.5, "chicane": false, "wind": 0.0, "subtitle": "180s · teaches"},
	{"name": "Haul",     "time": 120.0, "par": 70.0, "friction": 2.5, "chicane": true,  "wind": 0.0, "subtitle": "120s · the shift"},
	{"name": "Night Run","time": 120.0, "par": 70.0, "friction": 1.8, "chicane": true,  "wind": 7.0, "subtitle": "120s · low grip"},
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
var cargo: Array[RigidBody3D] = []
var cargo_mats: Array[StandardMaterial3D] = []
var lost: Dictionary = {}
var delivered: Dictionary = {}
var chock_shapes: Array[CollisionShape3D] = []
var chock_meshes: Array[MeshInstance3D] = []
var cradle_nodes: Array[Node] = []  # permanent cradles + backstops, cleared on cargo swap
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
var scores_cfg: Dictionary = {}  # key route%d_%s -> Array[{name, score, cargo, racks, time}]
var mode_ix: int = 1
var cargo_kind: String = CARGO_COILS
var _buttons: Array = []
var first_input_received := false
var controls_fade_t := 0.0
var mouse_pos := Vector2(-1000, -1000)

# Match
var time_left := 0.0
var finished := false
var game_over := false
var grade := 1
var par_hit := false
var elapsed := 0.0
var clean_stops := 0
var delivery_t := 0.0
var in_dock := false
var racks_at_finish := false
var final_score := 0
var final_rank := -1

# Name entry
var name_letters: Array[int] = [0, 0, 0]  # 0=A ... 25=Z
var name_pos: int = 0

# Pending finish-to-results transition (cancelable on restart)
var finish_timer_id: int = 0

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
var reset_grace_t := 0.0  # seconds; fall detect + lost checks ignored while > 0

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
	scores_cfg = _load_scores()
	mode_ix = int(best_cfg.get("last_mode", 1))
	cargo_kind = String(best_cfg.get("last_cargo", CARGO_COILS))
	_build_environment()
	_build_world()
	truck = _build_truck()
	_spawn_cargo()
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
	sm.ground_horizon_color = Color(0.42, 0.28, 0.22)
	sm.ground_bottom_color = Color(0.08, 0.06, 0.05)
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
	# Narrow road platform (cliff on both sides)
	var road_w: float = ROAD_HALF_WIDTH * 2.0
	_static_box(Vector3(road_w, 1, 310), Vector3(0, -0.5, -125), Color(0.26, 0.22, 0.18))
	# Shoulder stripes (edge of road, keep below truck wheels)
	for s in [-ROAD_HALF_WIDTH + 0.15, ROAD_HALF_WIDTH - 0.15]:
		_box_mesh(Vector3(0.3, 0.02, 300), Vector3(s, 0.01, -125), Color(0.9, 0.9, 0.9), self)
	# Center lane markings
	_box_mesh(Vector3(14, 0.02, 290), Vector3(0, 0.01, -125), Color(0.12, 0.12, 0.14), self)
	for i in range(28):
		_box_mesh(Vector3(0.25, 0.03, 4), Vector3(0, 0.02, 5 - i * 10.0), Color(0.95, 0.75, 0.2), self)

	# Cliff-side rail poles — occasional, breaks the horizon line
	for z in range(-20, -260, -40):
		for sx in [-ROAD_HALF_WIDTH + 0.4, ROAD_HALF_WIDTH - 0.4]:
			_box_mesh(Vector3(0.2, 1.2, 0.2), Vector3(sx, 0.6, z), Color(0.35, 0.33, 0.3), self)

	# Mill zone — wider platform at the start
	_static_box(Vector3(44, 1, 32), Vector3(0, -0.5, 24), Color(0.26, 0.22, 0.18))
	_static_box(Vector3(40, 18, 14), Vector3(0, 9, 26), Color(0.3, 0.28, 0.28))
	_static_box(Vector3(3, 30, 3), Vector3(-14, 15, 30), Color(0.4, 0.3, 0.26))
	_static_box(Vector3(3, 26, 3), Vector3(-8, 13, 30), Color(0.4, 0.3, 0.26))
	_box_mesh(Vector3(2.5, 0.5, 2.5), Vector3(-14, 30.3, 30), AMBER, self, 0.0, true)
	mill_sign = _sign_label("STEEL MILL", Vector3(0, 20, 18), 160, AMBER)

	# Speed bumps
	for z in [-35.0, -80.0, -170.0, -215.0]:
		_static_box(Vector3(road_w, 0.35, 1.2), Vector3(0, 0.1, z), Color(0.95, 0.75, 0.15))

	# Jersey-barrier chicane
	var side := 1.0
	for z in range(-105, -150, -12):
		var b := _static_box(Vector3(6, 1.2, 0.8), Vector3(2.6 * side, 0.6, z), Color(0.82, 0.82, 0.8))
		chicane_bodies.append(b)
		side = -side

	# Mesa scenery (far side of the void)
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in range(28):
		var sign_x: float = 1.0 if r.randf() > 0.5 else -1.0
		var x: float = r.randf_range(28, 90) * sign_x
		var z: float = r.randf_range(-300, 10)
		var h: float = r.randf_range(4, 14)
		# Mesa: anchor top below road level to read as distant land past the cliff.
		var top_y: float = r.randf_range(-6.0, -2.0)
		var sz := Vector3(r.randf_range(3, 8), h, r.randf_range(3, 8))
		_box_mesh(sz, Vector3(x, top_y - h * 0.5, z), Color(0.22, 0.19, 0.17).lerp(Color(0.4, 0.28, 0.22), r.randf()), self)

	# Dock platform
	_static_box(Vector3(32, 1, 32), DOCK_POS + Vector3(0, -0.5, -4), Color(0.26, 0.22, 0.18))

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
	for sx in [-9.0, 9.0]:
		_box_mesh(Vector3(0.6, 0.6, 0.6), DOCK_POS + Vector3(sx, 1.0, 0), DOCK_GREEN, self, 0.0, true)
	dock_sign = _sign_label("DOCK", DOCK_POS + Vector3(0, 9, -10), 160, DOCK_GREEN)

	# "DELIVERED" burst label
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

	var deck := CollisionShape3D.new()
	var deck_box := BoxShape3D.new()
	deck_box.size = Vector3(2.5, 0.5, 9.0)
	deck.shape = deck_box
	deck.position = Vector3(0, 0.6, 0)
	v.add_child(deck)
	_box_mesh(Vector3(2.5, 0.5, 9.0), Vector3(0, 0.6, 0), Color(0.17, 0.18, 0.2), v, 0.4)
	_box_mesh(Vector3(2.52, 0.08, 6.8), Vector3(0, 0.86, -1.1), Color(0.38, 0.26, 0.17), v)

	var cab := CollisionShape3D.new()
	var cab_box := BoxShape3D.new()
	cab_box.size = Vector3(2.5, 2.1, 2.2)
	cab.shape = cab_box
	cab.position = Vector3(0, 1.9, 3.4)
	v.add_child(cab)
	_box_mesh(Vector3(2.5, 2.1, 2.2), Vector3(0, 1.9, 3.4), Color(0.7, 0.11, 0.09), v, 0.3)
	_box_mesh(Vector3(2.3, 0.8, 0.05), Vector3(0, 2.3, 4.51), Color(0.12, 0.2, 0.3), v, 0.6)

	var head := CollisionShape3D.new()
	var head_box := BoxShape3D.new()
	head_box.size = Vector3(2.5, 1.8, 0.2)
	head.shape = head_box
	head.position = Vector3(0, 1.75, 2.2)
	v.add_child(head)
	_box_mesh(Vector3(2.5, 1.8, 0.2), Vector3(0, 1.75, 2.2), Color(0.25, 0.26, 0.3), v, 0.5)
	for mx in [-1.0, 1.0]:
		var m := _box_mesh(Vector3(0.3, 0.15, 0.3), Vector3(mx, 2.7, 2.2), AMBER, v, 0.0, true)
		marker_lights.append(m)

	for mx in [-1.1, 1.1]:
		_box_mesh(Vector3(0.3, 0.2, 0.1), Vector3(mx, 0.85, -4.6), LOST_RED, v, 0.0, true)

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

	for sx in [-0.9, 0.9]:
		var sp := SpotLight3D.new()
		sp.position = Vector3(sx, 1.4, 4.3)
		sp.light_color = Color(1.0, 0.95, 0.8)
		sp.light_energy = 6.0
		sp.spot_range = 60.0
		sp.spot_angle = 42.0
		sp.spot_angle_attenuation = 0.4
		sp.rotation_degrees = Vector3(-8, 180, 0)
		v.add_child(sp)
		headlights.append(sp)
		_box_mesh(Vector3(0.4, 0.3, 0.05), Vector3(sx, 1.4, 4.51), Color(1.0, 0.95, 0.78), v, 0.0, true)

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


# ============================================================= cargo
# A single system that spawns coils OR pipes and builds the matching racks
# attached to the truck. Call _despawn_cargo() first to tear down the old set.

func _despawn_cargo() -> void:
	for c in cargo:
		if is_instance_valid(c):
			c.queue_free()
	cargo.clear()
	cargo_mats.clear()
	# Remove racks (chocks) from the truck. Must also free the collision shapes
	# we parented onto the truck in _build_racks().
	for s in chock_shapes:
		if is_instance_valid(s):
			s.queue_free()
	for m in chock_meshes:
		if is_instance_valid(m):
			m.queue_free()
	for n in cradle_nodes:
		if is_instance_valid(n):
			n.queue_free()
	chock_shapes.clear()
	chock_meshes.clear()
	cradle_nodes.clear()
	racks_on = false


func _spawn_cargo() -> void:
	# Build permanent low cradles (visible for both cargos; non-colliding visual)
	# and spawn either coils or pipes with their matching racks.
	_despawn_cargo()
	if cargo_kind == CARGO_PIPES:
		_spawn_pipes()
	else:
		_spawn_coils()
	_build_racks()
	_set_racks(false)


func _spawn_coils() -> void:
	for z in COIL_Z:
		var c := RigidBody3D.new()
		c.mass = COIL_MASS
		var pm := PhysicsMaterial.new()
		pm.friction = 0.8
		pm.bounce = 0.05
		c.physics_material_override = pm
		c.continuous_cd = true
		c.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		c.angular_damp = 2.5

		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = COIL_RADIUS
		shape.height = COIL_HEIGHT
		cs.shape = shape
		cs.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(cs)

		var outer := MeshInstance3D.new()
		var om := CylinderMesh.new()
		om.top_radius = COIL_RADIUS
		om.bottom_radius = COIL_RADIUS
		om.height = COIL_HEIGHT
		var outer_mat := _mat(STEEL, 0.9)
		om.material = outer_mat
		outer.mesh = om
		outer.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(outer)
		cargo_mats.append(outer_mat)

		var eye := MeshInstance3D.new()
		var em := CylinderMesh.new()
		em.top_radius = 0.28
		em.bottom_radius = 0.28
		em.height = COIL_HEIGHT + 0.02
		em.material = _mat(Color(0.06, 0.06, 0.07))
		eye.mesh = em
		eye.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(eye)

		c.position = truck.transform * Vector3(0, 1.57, z)
		add_child(c)
		cargo.append(c)


func _spawn_pipes() -> void:
	for px in PIPE_X:
		var c := RigidBody3D.new()
		c.mass = PIPE_MASS
		var pm := PhysicsMaterial.new()
		pm.friction = 0.7
		pm.bounce = 0.08
		c.physics_material_override = pm
		c.continuous_cd = true
		c.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		c.angular_damp = 1.6

		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = PIPE_RADIUS
		shape.height = PIPE_LENGTH
		cs.shape = shape
		# CylinderMesh/Shape default axis is Y; rotate 90° on X so it points along Z.
		cs.rotation_degrees = Vector3(90, 0, 0)
		c.add_child(cs)

		var outer := MeshInstance3D.new()
		var om := CylinderMesh.new()
		om.top_radius = PIPE_RADIUS
		om.bottom_radius = PIPE_RADIUS
		om.height = PIPE_LENGTH
		var outer_mat := _mat(STEEL, 0.9)
		om.material = outer_mat
		outer.mesh = om
		outer.rotation_degrees = Vector3(90, 0, 0)
		c.add_child(outer)
		cargo_mats.append(outer_mat)

		# Dark bore caps (both ends)
		for ez in [PIPE_LENGTH * 0.5 + 0.001, -PIPE_LENGTH * 0.5 - 0.001]:
			var cap := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = PIPE_RADIUS * 0.88
			cm.bottom_radius = PIPE_RADIUS * 0.88
			cm.height = 0.04
			cm.material = _mat(Color(0.05, 0.05, 0.06))
			cap.mesh = cm
			cap.rotation_degrees = Vector3(90, 0, 0)
			cap.position = Vector3(0, 0, ez)
			c.add_child(cap)

		c.position = truck.transform * Vector3(px, 1.3, PIPE_Z_CENTER)
		add_child(c)
		cargo.append(c)


func _build_racks() -> void:
	# Permanent low cradles — short lips that stop the cargo from drifting even
	# with racks off. These stay collidable regardless of _set_racks state.
	# Attached to the truck so they move with it.
	if cargo_kind == CARGO_PIPES:
		for px in PIPE_X:
			for dx in [0.33, -0.33]:
				var lip := CollisionShape3D.new()
				var lb := BoxShape3D.new()
				lb.size = Vector3(0.08, 0.14, PIPE_LENGTH)
				lip.shape = lb
				lip.position = Vector3(px + dx, 1.0, PIPE_Z_CENTER)
				truck.add_child(lip)
				cradle_nodes.append(lip)
				cradle_nodes.append(_box_mesh(lb.size, lip.position, Color(0.09, 0.09, 0.09), truck, 0.5))
		# Backstops fore and aft so pipes don't slide out either end on brake/accel.
		for sz in [PIPE_Z_CENTER - PIPE_LENGTH * 0.5 - 0.1, PIPE_Z_CENTER + PIPE_LENGTH * 0.5 + 0.1]:
			var back := CollisionShape3D.new()
			var rb := BoxShape3D.new()
			rb.size = Vector3(2.5, 0.5, 0.15)
			back.shape = rb
			back.position = Vector3(0, 1.25, sz)
			truck.add_child(back)
			cradle_nodes.append(back)
			cradle_nodes.append(_box_mesh(rb.size, back.position, Color(0.09, 0.09, 0.09), truck, 0.5))
	else:
		for z in COIL_Z:
			for dz in [0.42, -0.42]:
				var lip := CollisionShape3D.new()
				var lb := BoxShape3D.new()
				lb.size = Vector3(2.0, 0.1, 0.1)
				lip.shape = lb
				lip.position = Vector3(0, 0.9, z + dz)
				truck.add_child(lip)
				cradle_nodes.append(lip)
				cradle_nodes.append(_box_mesh(lb.size, lip.position, Color(0.09, 0.09, 0.09), truck, 0.5))

	# Tall chocks that are toggled by R. Visible + collidable only when racks_on.
	if cargo_kind == CARGO_PIPES:
		# Lateral chocks: for each pipe position, two chocks running lengthwise
		# on left and right of the pipe. Chock size: thin X, moderate Y, long Z.
		for px in PIPE_X:
			for dx in [0.35, -0.35]:
				var cs := CollisionShape3D.new()
				var cb := BoxShape3D.new()
				cb.size = Vector3(0.1, 0.35, PIPE_LENGTH)
				cs.shape = cb
				cs.position = Vector3(px + dx, 1.15, PIPE_Z_CENTER)
				truck.add_child(cs)
				chock_shapes.append(cs)
				chock_meshes.append(_box_mesh(cb.size, cs.position, AMBER, truck))
	else:
		# Coil racks: fore/aft chocks per coil.
		for z in COIL_Z:
			for dz in [0.75, -0.75]:
				var cs := CollisionShape3D.new()
				var cb := BoxShape3D.new()
				cb.size = Vector3(2.0, 0.35, 0.25)
				cs.shape = cb
				cs.position = Vector3(0, 1.025, z + dz)
				truck.add_child(cs)
				chock_shapes.append(cs)
				chock_meshes.append(_box_mesh(cb.size, cs.position, AMBER, truck))


func _reset_cargo() -> void:
	# Unfreeze (delivery sets freeze=true), zero velocity, reset position +
	# rotation, reset material. Works for both coils and pipes.
	for i in range(cargo.size()):
		var c := cargo[i]
		if not is_instance_valid(c):
			continue
		c.freeze = false
		c.linear_velocity = Vector3.ZERO
		c.angular_velocity = Vector3.ZERO
		if cargo_kind == CARGO_PIPES:
			c.position = truck.transform * Vector3(PIPE_X[i], 1.3, PIPE_Z_CENTER)
		else:
			c.position = truck.transform * Vector3(0, 1.57, COIL_Z[i])
		c.rotation = Vector3.ZERO
		cargo_mats[i].albedo_color = STEEL
		cargo_mats[i].emission_enabled = false


func _reset_truck() -> void:
	# VehicleBody3D's own velocity + transform setters don't always teleport
	# cleanly after the body fell off the road. Push the transform directly
	# into the physics server, which does.
	var t := Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.7, 0))
	truck.linear_velocity = Vector3.ZERO
	truck.angular_velocity = Vector3.ZERO
	truck.engine_force = 0.0
	truck.brake = 0.0
	truck.steering = 0.0
	truck.global_transform = t
	PhysicsServer3D.body_set_state(truck.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t)
	PhysicsServer3D.body_set_state(truck.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(truck.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)


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
		State.TITLE:      _dim(0.55); _draw_title()
		State.HOW_TO:     _dim(0.6);  _draw_how_to()
		State.PLAY:       _draw_hud()
		State.PAUSE:      _dim(0.5);  _draw_pause()
		State.SETTINGS:   _dim(0.6);  _draw_settings()
		State.RESULTS:    _dim(0.6);  _draw_results()
		State.SCORES:     _dim(0.65); _draw_scores()
		State.NAME_ENTRY: _dim(0.7);  _draw_name_entry()


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
	# Cancel any pending finish→results transition.
	finish_timer_id += 1
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
	racks_at_finish = false
	final_score = 0
	final_rank = -1
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
	reset_grace_t = 0.5
	_reset_truck()
	# Full respawn so delivered-and-frozen cargo comes back clean, and so
	# switching cargo kind between runs rebuilds the racks correctly.
	_spawn_cargo()
	delivered_label.visible = false
	_apply_mode()


func _begin_match() -> void:
	_reset_match()
	_set_state(State.PLAY)
	SFX.confirm()
	best_cfg["last_mode"] = mode_ix
	best_cfg["last_cargo"] = cargo_kind
	_save_best()


func _restart_match() -> void:
	_reset_match()
	_set_state(State.PLAY)


# ============================================================= input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = (event as InputEventMouseMotion).position
		ui.queue_redraw()
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
					ui.queue_redraw()
				elif event.physical_keycode == KEY_C:
					cargo_kind = CARGO_PIPES if cargo_kind == CARGO_COILS else CARGO_COILS
					_spawn_cargo()
					SFX.click()
					ui.queue_redraw()
				elif event.physical_keycode == KEY_T:
					_set_state(State.SCORES)
			State.PLAY:
				if finished:
					if event.physical_keycode == KEY_ENTER:
						_proceed_from_finish()
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
			State.SCORES:
				if event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_ENTER:
					SFX.click()
					_set_state(State.TITLE)
			State.NAME_ENTRY:
				_handle_name_entry(event.physical_keycode)


func _proceed_from_finish() -> void:
	# When finished, the player hits Enter to see the results. If their score
	# is a new high, go to the name entry card first.
	if _score_qualifies(final_score):
		_set_state(State.NAME_ENTRY)
	else:
		_set_state(State.RESULTS)


func _handle_name_entry(key: int) -> void:
	match key:
		KEY_W, KEY_UP:
			name_letters[name_pos] = (name_letters[name_pos] - 1 + 26) % 26
			SFX.click()
		KEY_S, KEY_DOWN:
			name_letters[name_pos] = (name_letters[name_pos] + 1) % 26
			SFX.click()
		KEY_A, KEY_LEFT:
			name_pos = (name_pos - 1 + 3) % 3
			SFX.click()
		KEY_D, KEY_RIGHT:
			name_pos = (name_pos + 1) % 3
			SFX.click()
		KEY_ENTER, KEY_SPACE:
			var nm := _name_string()
			final_rank = _commit_score(nm, final_score)
			SFX.confirm()
			# Remember the name — handy for the next entry — but return cursor home.
			name_pos = 0
			_set_state(State.RESULTS)
	ui.queue_redraw()


func _name_string() -> String:
	var s := ""
	for n in name_letters:
		s += char(int(n) + 65)
	return s


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
		"scores": _set_state(State.SCORES)
		"mode_0": mode_ix = 0; _save_best(); ui.queue_redraw()
		"mode_1": mode_ix = 1; _save_best(); ui.queue_redraw()
		"mode_2": mode_ix = 2; _save_best(); ui.queue_redraw()
		"cargo_coils":
			if cargo_kind != CARGO_COILS:
				cargo_kind = CARGO_COILS
				_spawn_cargo()
				_save_best()
				ui.queue_redraw()
		"cargo_pipes":
			if cargo_kind != CARGO_PIPES:
				cargo_kind = CARGO_PIPES
				_spawn_cargo()
				_save_best()
				ui.queue_redraw()
		"resume": _set_state(State.PLAY)
		"restart": _restart_match()
		"settings_from_pause": _set_state(State.SETTINGS)
		"quit_to_title": _set_state(State.TITLE)
		"back": _set_state(state_prev)
		"back_title": _set_state(State.TITLE)
		"play_again": _set_state(State.TITLE)
		"commit_name":
			var nm := _name_string()
			final_rank = _commit_score(nm, final_score)
			SFX.confirm()
			_set_state(State.RESULTS)
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

	if reset_grace_t > 0.0:
		reset_grace_t = maxf(0.0, reset_grace_t - delta)

	# Fall-off-the-road detect — instant death (after a short grace so a stale
	# physics frame from the previous run can't trigger it)
	if reset_grace_t <= 0.0 and truck.global_position.y < FALL_KILL_Y:
		_finish(false, "WENT OFF THE ROAD")
		return

	var speed := truck.linear_velocity.length()
	var throttle := Input.get_action_strength("accelerate") - Input.get_action_strength("reverse")
	var steer_in := Input.get_action_strength("left") - Input.get_action_strength("right")
	truck.steering = move_toward(truck.steering, steer_in * MAX_STEER, delta * 1.6)
	truck.engine_force = throttle * ENGINE_FORCE if speed < MAX_SPEED else 0.0

	if Input.is_action_just_pressed("brake"):
		brake_coyote_t = BRAKE_COYOTE
	brake_coyote_t = maxf(0.0, brake_coyote_t - delta)
	var braking: bool = Input.is_action_pressed("brake") or brake_coyote_t > 0.0
	truck.brake = BRAKE_FORCE if braking else 0.0

	var m: Dictionary = MODES[mode_ix]
	var wind_m: float = float(m.wind)
	if wind_m > 0.0:
		var gust := wind_m * (0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.0007))
		truck.apply_central_force(Vector3(gust * 180.0, 0, 0))

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

	if reset_grace_t <= 0.0:
		_check_cargo()

	var decel := (prev_speed - speed) / maxf(delta, 0.0001)
	if decel > CLEAN_STOP_DECEL and racks_on and speed < 2.0 and prev_speed > 10.0 and lost.is_empty():
		clean_stops += 1
		_flash_clean_stop()
	prev_speed = speed
	prev_racks_on = racks_on

	var dist := truck.global_position.distance_to(DOCK_POS)
	in_dock = dist < 8.5 and speed < 2.2
	var all_cargo_on_deck := _cargo_on_deck() == cargo.size() - lost.size()
	if in_dock and all_cargo_on_deck and not lost.size() == cargo.size():
		delivery_t = minf(DELIVERY_TIME, delivery_t + delta)
		if delivery_t >= DELIVERY_TIME:
			_do_delivery()
	else:
		delivery_t = maxf(0.0, delivery_t - delta * 2.0)

	time_left -= delta
	elapsed += delta
	if time_left <= 0.0:
		time_left = 0.0
		_finish(false, "OUT OF TIME")
	elif lost.size() == cargo.size():
		_finish(false, "ALL CARGO LOST")


func _cargo_on_deck() -> int:
	var n := 0
	for c in cargo:
		if lost.has(c) or delivered.has(c):
			continue
		var p := truck.to_local(c.global_position)
		if _is_on_deck(p):
			n += 1
	return n


func _is_on_deck(p: Vector3) -> bool:
	# Shared check for both cargo kinds. Pipes are 5m long centered at z=-1.1,
	# so their center stays well inside z range [-5.2, 2.6] when on deck.
	return absf(p.x) < 1.8 and p.y > 0.5 and p.y < 3.5 and p.z > -5.2 and p.z < 2.6


func _check_cargo() -> void:
	for i in range(cargo.size()):
		var c := cargo[i]
		if lost.has(c) or delivered.has(c):
			continue
		var p := truck.to_local(c.global_position)
		if not _is_on_deck(p):
			lost[c] = true
			cargo_mats[i].albedo_color = LOST_RED
			cargo_mats[i].emission_enabled = true
			cargo_mats[i].emission = LOST_RED * 0.4
			cargo_mats[i].emission_energy_multiplier = 1.0
			_banner("COIL LOST" if cargo_kind == CARGO_COILS else "PIPE LOST", 1.4)
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
	for c in cargo:
		if not lost.has(c) and not delivered.has(c):
			remaining.append(c)
	if remaining.is_empty():
		return
	for c in remaining:
		delivered[c] = true
		c.freeze = true
		c.position = DOCK_POS + Vector3(rng.randf_range(-3, 3), 1.0 + rng.randf() * 0.5, rng.randf_range(-3, 3))
	SFX.success()
	SFX.kaching()
	delivered_label.visible = true
	var tid := finish_timer_id
	get_tree().create_timer(1.6).timeout.connect(func(): if tid == finish_timer_id and is_instance_valid(delivered_label): delivered_label.visible = false)
	var any_lost := lost.size() > 0
	_finish(true, "CLEAN LOAD" if not any_lost else "PARTIAL DELIVERY")


func _finish(ok: bool, label: String) -> void:
	if finished:
		return
	finished = true
	racks_at_finish = racks_on
	var m: Dictionary = MODES[mode_ix]
	var any_lost := lost.size() > 0
	var all_lost := lost.size() == cargo.size()
	par_hit = ok and elapsed <= float(m.par) and not any_lost
	if all_lost or not ok:
		grade = 1
	elif ok and not any_lost and par_hit:
		grade = 3
	else:
		grade = 2
	_banner(label, 2.0)

	# Scoring: cargo delivered * 1000 + time_left seconds * 50 + racks bonus 100
	var on_truck := cargo.size() - lost.size()
	final_score = on_truck * 1000 + int(time_left) * 50 + (100 if racks_at_finish else 0)
	# Grade multiplier so a 3-star run clearly beats a 2-star
	final_score += (grade - 1) * 500
	# Peek at rank — committed on name entry
	final_rank = -1

	var key := "mode_%d" % mode_ix
	var row: Dictionary = best_cfg.get(key, {"grade": 0, "elapsed": 9999.0, "clean_stops": 0})
	row.grade = maxi(int(row.grade), grade)
	if ok and (float(row.elapsed) > elapsed or int(row.elapsed) == 0):
		row.elapsed = elapsed
	row.clean_stops = maxi(int(row.clean_stops), clean_stops)
	best_cfg[key] = row
	_save_best()

	# Capturing current timer id so a restart during the delay cancels it.
	var tid := finish_timer_id
	get_tree().create_timer(1.4).timeout.connect(func(): if tid == finish_timer_id and state == State.PLAY and finished: _proceed_from_finish())


# ============================================================= per-frame
func _process(delta: float) -> void:
	if banner_t > 0.0:
		banner_t = maxf(0.0, banner_t - delta)
		if banner_t <= 0.0:
			banner_text = ""
	if vignette_t > 0.0:
		vignette_t = maxf(0.0, vignette_t - delta * 1.6)
	if controls_fade_t > 0.0:
		controls_fade_t = maxf(0.0, controls_fade_t - delta)

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

	if dock_ring:
		if settings.get("reduced_motion", false):
			dock_ring.scale = Vector3.ONE
		else:
			var p := 1.0 + sin(Time.get_ticks_msec() * 0.004) * 0.07
			dock_ring.scale = Vector3(p, 1.0, p)

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

		var mph := speed * 2.237
		var target_fov := 65.0
		if not settings.get("reduced_motion", false):
			target_fov = 65.0 + clampf((mph - 20.0) / 20.0, 0.0, 1.0) * 2.0
		fov_t = lerp(fov_t, target_fov, clampf(delta * 2.5, 0.0, 1.0))
		cam.fov = fov_t

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
	var hover: bool = rect.has_point(mouse_pos)
	var fill: Color
	var border: Color
	if primary:
		fill = Color(AMBER.r, AMBER.g, AMBER.b, 0.32 if hover else 0.22)
		border = Color(AMBER.r, AMBER.g, AMBER.b, 1.0 if hover else 0.9)
	else:
		fill = Color(1, 1, 1, 0.14 if hover else 0.06)
		border = Color(1, 1, 1, 0.28 if hover else 0.14)
	UI.draw_panel(ui, rect, 12.0, fill, border)
	var tx: Vector2 = rect.position + Vector2(0, rect.size.y * 0.5 + size * 0.33)
	_text(tx, label, size, INK, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, primary or hover)
	_buttons.append({"rect": rect, "id": id})


func _toggle(id: String, pos: Vector2, label: String, on: bool) -> void:
	var r := Rect2(pos, Vector2(500, 36))
	var hover: bool = r.has_point(mouse_pos)
	UI.draw_panel(ui, r, 10.0, Color(1, 1, 1, 0.14 if hover else 0.06), Color(1, 1, 1, 0.26 if hover else 0.14))
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

	var sp_chip := Rect2(20, 20, 200, 92)
	UI.draw_panel(ui, sp_chip, 14.0, Color(0, 0, 0, 0.45), UI.PANEL_BORDER)
	_text(sp_chip.position + Vector2(18, 28), "SPEED", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(sp_chip.position + Vector2(18, 70), "%d" % mph, UI.TYPE_HUD, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(sp_chip.position + Vector2(118, 70), "MPH", UI.TYPE_CAPTION, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(sp_chip.position + Vector2(118, 86), "%d km/h" % kph, UI.TYPE_CAPTION, Color(INK, 0.65))

	var cl_chip := Rect2(VIEW.x - 220, 20, 200, 92)
	UI.draw_panel(ui, cl_chip, 14.0, Color(0, 0, 0, 0.45), UI.PANEL_BORDER)
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 28), "CLOCK", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_RIGHT, -1, true)
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 70), UI.mmss(time_left), UI.TYPE_HUD, INK, HORIZONTAL_ALIGNMENT_RIGHT, -1, true, true)
	var dist := int(truck.global_position.distance_to(DOCK_POS)) if truck else 0
	_text(cl_chip.position + Vector2(cl_chip.size.x - 18, 86), "DOCK %dm" % dist, UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_RIGHT)

	# Cargo chip row (top-center) — count varies by cargo kind
	var cnt := cargo.size()
	var chip_w: float = 44.0 * cnt + 24.0
	var row := Rect2(VIEW.x * 0.5 - chip_w * 0.5, 20, chip_w, 44)
	UI.draw_panel(ui, row, 14.0, Color(0, 0, 0, 0.45), UI.PANEL_BORDER)
	for i in range(cnt):
		var cx: float = row.position.x + 22 + i * 44.0
		var cy: float = row.position.y + 22.0
		var color: Color
		if delivered.has(cargo[i]):
			color = DOCK_GREEN
		elif lost.has(cargo[i]):
			color = LOST_RED
		else:
			color = STEEL
		if cargo_kind == CARGO_PIPES:
			# Draw as a horizontal pill to signal "pipe"
			var pr := Rect2(cx - 16, cy - 5, 32, 10)
			UI.draw_panel(ui, pr, 5.0, color, Color(0, 0, 0, 0.55))
		else:
			ui.draw_circle(Vector2(cx, cy), 10.0, color)
			ui.draw_arc(Vector2(cx, cy), 10.0, 0, TAU, 20, Color(0, 0, 0, 0.55), 1.5, true)
			ui.draw_circle(Vector2(cx, cy), 3.0, Color(0.05, 0.05, 0.07))

	var mode_label := "%s · %s" % [MODES[mode_ix].name, "COILS" if cargo_kind == CARGO_COILS else "PIPES"]
	if clean_stops > 0:
		mode_label += " · %d CLEAN" % clean_stops
	_text(Vector2(VIEW.x * 0.5, 86), mode_label, UI.TYPE_CAPTION, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER)

	var pill_w := 260.0
	var pill := Rect2(VIEW.x * 0.5 - pill_w * 0.5, VIEW.y - 60, pill_w, 36)
	var pill_fill: Color = Color(DOCK_GREEN.r, DOCK_GREEN.g, DOCK_GREEN.b, 0.22) if racks_on else Color(AMBER.r, AMBER.g, AMBER.b, 0.22)
	var pill_border: Color = DOCK_GREEN if racks_on else AMBER
	UI.draw_panel(ui, pill, 18.0, pill_fill, pill_border)
	var pill_text := "RACKS SET" if racks_on else "RACKS OFF · STOP + R"
	_text(pill.position + Vector2(0, 24), pill_text, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, pill.size.x, true)

	if delivery_t > 0.0:
		var frac := delivery_t / DELIVERY_TIME
		var center := Vector2(VIEW.x * 0.5, VIEW.y * 0.5 + 40)
		UI.draw_ring_bg(ui, center, 60.0, Color(1, 1, 1, 0.15), 5.0)
		UI.draw_ring(ui, center, 60.0, frac, DOCK_GREEN, 6.0)
		_text(Vector2(0, VIEW.y * 0.5 + 118), "DELIVERING", UI.TYPE_BODY, DOCK_GREEN, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true)

	if vignette_t > 0.0:
		var a: float = clampf(vignette_t * 0.6, 0.0, 0.6)
		_vignette(a)

	if banner_text != "":
		var a: float = clampf(banner_t * 2.0, 0.0, 1.0)
		var size: int = UI.TYPE_TITLE + 2
		var bg_h := 70.0
		var bg_y := VIEW.y * 0.42
		ui.draw_rect(Rect2(0, bg_y, VIEW.x, bg_h), Color(0, 0, 0, 0.4 * a))
		_text(Vector2(0, bg_y + 48), banner_text, size, Color(INK.r, INK.g, INK.b, 0.75 + 0.25 * a), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true, true)

	if finished:
		_dim(0.4)
		_text(Vector2(0, VIEW.y * 0.5 - 8), banner_text if banner_text != "" else "RUN COMPLETE", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x, true, true)
		_text(Vector2(0, VIEW.y * 0.5 + 24), "ENTER for results", UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)

	_draw_controls_hint()


func _vignette(a: float) -> void:
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
		UI.draw_panel(ui, r, 10.0, Color(0, 0, 0, 0.35 * alpha), Color(1, 1, 1, 0.2 * alpha))
		_text(Vector2(x + 10, y + 15), c, UI.TYPE_CAPTION, Color(INK.r, INK.g, INK.b, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
		x += w + 8


# ---- title -----------------------------------------------------------------
func _draw_title() -> void:
	var card := Rect2(80, 70, 560, 580)
	UI.draw_card(ui, card, AMBER)
	_text(card.position + Vector2(28, 56), "FLATBED HAULER", UI.TYPE_TITLE + 6, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	_text(card.position + Vector2(28, 86), "Steel from the mill to the dock.", UI.TYPE_BODY, Color(INK, 0.85))

	# Route
	_text(card.position + Vector2(28, 126), "ROUTE", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	for i in range(MODES.size()):
		var r := Rect2(card.position.x + 28 + i * 170, card.position.y + 146, 160, 72)
		var sel: bool = i == mode_ix
		var hover: bool = r.has_point(mouse_pos)
		var fill: Color = Color(AMBER.r, AMBER.g, AMBER.b, 0.26 if sel else (0.14 if hover else 0.06))
		var bor: Color = Color(AMBER.r, AMBER.g, AMBER.b, 1.0 if sel else (0.5 if hover else 0.2))
		UI.draw_panel(ui, r, 10.0, fill, bor)
		_text(r.position + Vector2(0, 26), MODES[i].name, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, sel or hover)
		_text(r.position + Vector2(10, 48), MODES[i].subtitle, UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20)
		_buttons.append({"rect": r, "id": "mode_%d" % i})

	# Cargo selector
	_text(card.position + Vector2(28, 238), "CARGO", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var cargos := [["cargo_coils", "COILS", "4 across · roll fore/aft", CARGO_COILS],
				   ["cargo_pipes", "PIPES", "3 long · roll side to side", CARGO_PIPES]]
	for i in range(cargos.size()):
		var cr := Rect2(card.position.x + 28 + i * 250, card.position.y + 258, 240, 68)
		var sel: bool = cargo_kind == cargos[i][3]
		var hover: bool = cr.has_point(mouse_pos)
		var fill: Color = Color(SKY.r, SKY.g, SKY.b, 0.26 if sel else (0.14 if hover else 0.06))
		var bor: Color = Color(SKY.r, SKY.g, SKY.b, 1.0 if sel else (0.5 if hover else 0.2))
		UI.draw_panel(ui, cr, 10.0, fill, bor)
		_text(cr.position + Vector2(0, 26), cargos[i][1], UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, cr.size.x, sel or hover)
		_text(cr.position + Vector2(10, 48), cargos[i][2], UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, cr.size.x - 20)
		_buttons.append({"rect": cr, "id": cargos[i][0]})

	# Buttons
	var by: float = card.position.y + 346
	_button("play",     Rect2(card.position.x + 28,  by, 220, 54), "Play", true, UI.TYPE_HEADLINE)
	_button("scores",   Rect2(card.position.x + 264, by, 220, 54), "High scores")
	_button("how_to",   Rect2(card.position.x + 28,  by + 72, 220, 44), "How to play")
	_button("settings", Rect2(card.position.x + 264, by + 72, 220, 44), "Settings")

	var row: Dictionary = best_cfg.get("mode_%d" % mode_ix, {})
	if not row.is_empty():
		var best_t := float(row.get("elapsed", 0.0))
		var g := int(row.get("grade", 0))
		var line := "Best · "
		if best_t > 0.0:
			line += UI.mmss(best_t) + " · "
		line += "%d star" % g
		_text(card.position + Vector2(28, 500), line, UI.TYPE_CAPTION, Color(INK, 0.8))

	# Right info card
	var info := Rect2(680, 70, 520, 440)
	UI.draw_panel(ui, info)
	_text(info.position + Vector2(24, 36), "WHAT THIS SHOWS", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	var bullets := [
		"VehicleBody3D truck, 6 wheels, tandem drive.",
		"Coils roll fore/aft. Pipes roll side to side.",
		"R sets cargo racks when stopped. -5 seconds.",
		"Dock delivery holds for a beat, then counts.",
		"Night Run drops friction and adds crosswind.",
		"Fall off the road and the run is done.",
		"Top 10 saved per route and cargo.",
	]
	var yy: float = info.position.y + 70
	for b in bullets:
		_text(Vector2(info.position.x + 24, yy), "·  " + b, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_LEFT, info.size.x - 48)
		yy += 28

	var note := Rect2(680, 530, 520, 110)
	UI.draw_panel(ui, note, 10.0, Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.14))
	_text(note.position + Vector2(0, 36), "C swaps cargo. T opens high scores.", UI.TYPE_CAPTION, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, note.size.x, true)
	_text(note.position + Vector2(0, 66), "Rolling steel, headboard physics, cargo racks.", UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, note.size.x)


# ---- how to ----------------------------------------------------------------
func _draw_how_to() -> void:
	var r := Rect2(220, 90, 840, 540)
	UI.draw_card(ui, r, AMBER)
	_text(r.position + Vector2(28, 54), "HOW TO HAUL", UI.TYPE_TITLE, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
	var lines := [
		"W or S drive. A or D steer. SPACE brakes.",
		"Stop the truck and press R to set cargo racks. Takes 5 seconds off the clock.",
		"Hard stops, speed bumps and the chicane will roll your cargo if the racks are off.",
		"Coils roll fore and aft. Pipes roll side to side. Pick your poison on the title.",
		"Pull up on the green dock pad and hold still. The ring fills in 1.2s.",
		"Fall off the road and the run is done.",
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
	_text(Vector2(r.position.x + 428, r.position.y + 148), "%d%%" % int(settings.volume * 100), UI.TYPE_CAPTION, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)

	_toggle("mute_toggle",    r.position + Vector2(28, 180), "Mute all audio", settings.mute)
	_toggle("reduced_motion", r.position + Vector2(28, 230), "Reduced motion", settings.reduced_motion)
	_toggle("colorblind",     r.position + Vector2(28, 280), "Colorblind palette", settings.colorblind)
	_toggle("show_controls",  r.position + Vector2(28, 330), "Show on-screen controls", settings.show_controls)

	_button("back", Rect2(r.position.x + r.size.x - 150, r.position.y + r.size.y - 70, 120, 44), "Back")


# ---- results ---------------------------------------------------------------
func _draw_results() -> void:
	var r := Rect2(260, 60, 760, 600)
	UI.draw_card(ui, r, AMBER)
	var title: String
	match grade:
		3: title = "CLEAN LOAD"
		2: title = "GOOD RUN"
		_: title = "SHORT HAUL"
	_text(r.position + Vector2(0, 68), title, UI.TYPE_TITLE + 4, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Rank banner if placed
	if final_rank > 0:
		var rank_bg := Rect2(r.position.x + 180, r.position.y + 100, r.size.x - 360, 40)
		var is_top := final_rank == 1
		var bgf: Color = Color(DOCK_GREEN.r, DOCK_GREEN.g, DOCK_GREEN.b, 0.28) if is_top else Color(AMBER.r, AMBER.g, AMBER.b, 0.22)
		var bgb: Color = DOCK_GREEN if is_top else AMBER
		UI.draw_panel(ui, rank_bg, 8.0, bgf, bgb)
		var rtxt := "NEW HIGH SCORE" if is_top else "RANK %02d" % final_rank
		_text(rank_bg.position + Vector2(0, 28), rtxt, UI.TYPE_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER, rank_bg.size.x, true, true)

	# Stars
	var sx: float = r.position.x + r.size.x * 0.5 - 60
	for i in range(3):
		var filled: bool = i < grade
		var col: Color = AMBER if filled else Color(INK, 0.35)
		_draw_star(Vector2(sx + i * 50, r.position.y + 170), 18.0, col, filled)

	var cy: float = r.position.y + 220
	var on_truck := cargo.size() - lost.size()
	var m: Dictionary = MODES[mode_ix]
	var delivered_n := delivered.size()
	var kind_label := "coils" if cargo_kind == CARGO_COILS else "pipes"
	var line := "%d / %d %s delivered" % [delivered_n, cargo.size(), kind_label]
	if delivered_n == 0 and lost.size() < cargo.size():
		line = "%d / %d %s still on truck" % [on_truck, cargo.size(), kind_label]
	_text(Vector2(r.position.x, cy),       line, UI.TYPE_HEADLINE, INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_text(Vector2(r.position.x, cy + 40),  "Time %s · par %s" % [UI.mmss(elapsed), UI.mmss(float(m.par))], UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 68),  "Clean stops %d · racks %s" % [clean_stops, "set" if racks_at_finish else "off"], UI.TYPE_BODY, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, false, true)
	_text(Vector2(r.position.x, cy + 96),  "Route · %s · %s" % [MODES[mode_ix].name, "COILS" if cargo_kind == CARGO_COILS else "PIPES"], UI.TYPE_CAPTION, Color(INK, 0.7), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# Score tile
	var st := Rect2(r.position.x + r.size.x * 0.5 - 180, cy + 130, 360, 72)
	UI.draw_panel(ui, st, 12.0, Color(0, 0, 0, 0.35), UI.PANEL_BORDER)
	_text(st.position + Vector2(0, 28), "SCORE", UI.TYPE_CAPTION, Color(INK, 0.75), HORIZONTAL_ALIGNMENT_CENTER, st.size.x, true)
	_text(st.position + Vector2(0, 58), "%08d" % final_score, UI.TYPE_HEADLINE, AMBER, HORIZONTAL_ALIGNMENT_CENTER, st.size.x, true, true)

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


# ---- high scores -----------------------------------------------------------
func _draw_scores() -> void:
	var r := Rect2(280, 60, 720, 600)
	# Arcade-flavoured translucent panel with faint scanline texture
	UI.draw_panel(ui, r, 14.0, Color(0.02, 0.03, 0.05, 0.78), Color(AMBER.r, AMBER.g, AMBER.b, 0.6))
	# Scanlines
	for y in range(int(r.position.y) + 6, int(r.position.y + r.size.y) - 6, 3):
		ui.draw_rect(Rect2(r.position.x + 6, y, r.size.x - 12, 1), Color(1, 1, 1, 0.03))

	_text(r.position + Vector2(0, 64), "HIGH SCORES", UI.TYPE_TITLE + 4, AMBER, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	var sub := "%s · %s" % [MODES[mode_ix].name.to_upper(), "COILS" if cargo_kind == CARGO_COILS else "PIPES"]
	_text(r.position + Vector2(0, 92), sub, UI.TYPE_CAPTION, Color(INK, 0.85), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Column headers
	var hx: float = r.position.x + 60
	var hy: float = r.position.y + 128
	_text(Vector2(hx, hy),       "RANK", UI.TYPE_CAPTION, Color(INK, 0.65), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(hx + 90, hy),  "NAME", UI.TYPE_CAPTION, Color(INK, 0.65), HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_text(Vector2(r.position.x + r.size.x - 60, hy), "SCORE", UI.TYPE_CAPTION, Color(INK, 0.65), HORIZONTAL_ALIGNMENT_RIGHT, -1, true)
	ui.draw_rect(Rect2(r.position.x + 50, hy + 10, r.size.x - 100, 1), Color(AMBER.r, AMBER.g, AMBER.b, 0.35))

	var entries := _scores_for_current()
	var row_y: float = hy + 24
	for i in range(10):
		var e: Dictionary = entries[i] if i < entries.size() else {}
		var rank_text := "%02d" % (i + 1)
		var name_text := String(e.get("name", "---")) if not e.is_empty() else "---"
		var score_text := "%08d" % int(e.get("score", 0)) if not e.is_empty() else "--------"
		var col: Color = AMBER if (final_rank == i + 1) else INK
		_text(Vector2(hx, row_y + 22),       rank_text, UI.TYPE_HEADLINE, col, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
		_text(Vector2(hx + 90, row_y + 22),  name_text, UI.TYPE_HEADLINE, col, HORIZONTAL_ALIGNMENT_LEFT, -1, true, true)
		_text(Vector2(r.position.x + r.size.x - 60, row_y + 22), score_text, UI.TYPE_HEADLINE, col, HORIZONTAL_ALIGNMENT_RIGHT, -1, true, true)
		row_y += 32

	_button("back_title", Rect2(r.position.x + r.size.x * 0.5 - 100, r.position.y + r.size.y - 66, 200, 46), "Back", true)


# ---- name entry (arcade) --------------------------------------------------
func _draw_name_entry() -> void:
	var r := Rect2(VIEW.x * 0.5 - 300, 160, 600, 380)
	UI.draw_panel(ui, r, 14.0, Color(0.02, 0.03, 0.05, 0.85), Color(DOCK_GREEN.r, DOCK_GREEN.g, DOCK_GREEN.b, 0.7))
	for y in range(int(r.position.y) + 6, int(r.position.y + r.size.y) - 6, 3):
		ui.draw_rect(Rect2(r.position.x + 6, y, r.size.x - 12, 1), Color(1, 1, 1, 0.03))

	_text(r.position + Vector2(0, 56), "NEW HIGH SCORE", UI.TYPE_TITLE, DOCK_GREEN, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)
	_text(r.position + Vector2(0, 86), "SCORE %08d" % final_score, UI.TYPE_HEADLINE, AMBER, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)

	# Three letter cells
	var cell_w := 100.0
	var gap := 20.0
	var total := cell_w * 3 + gap * 2
	var start_x := r.position.x + (r.size.x - total) * 0.5
	var cy: float = r.position.y + 160
	for i in range(3):
		var cx := start_x + i * (cell_w + gap)
		var cr := Rect2(cx, cy, cell_w, 110)
		var sel: bool = i == name_pos
		var fill: Color = Color(DOCK_GREEN.r, DOCK_GREEN.g, DOCK_GREEN.b, 0.26) if sel else Color(1, 1, 1, 0.06)
		var bor: Color = DOCK_GREEN if sel else Color(1, 1, 1, 0.22)
		UI.draw_panel(ui, cr, 10.0, fill, bor)
		var ch := char(int(name_letters[i]) + 65)
		_text(cr.position + Vector2(0, 82), ch, UI.TYPE_HUD + 10, INK, HORIZONTAL_ALIGNMENT_CENTER, cr.size.x, true, true)
		if sel:
			# chevrons
			_text(Vector2(cx, cy - 6), "^", UI.TYPE_HEADLINE, DOCK_GREEN, HORIZONTAL_ALIGNMENT_CENTER, cell_w, true, true)
			_text(Vector2(cx, cy + cr.size.y + 24), "v", UI.TYPE_HEADLINE, DOCK_GREEN, HORIZONTAL_ALIGNMENT_CENTER, cell_w, true, true)

	_text(r.position + Vector2(0, r.size.y - 50), "W/S letter   A/D column   ENTER commit", UI.TYPE_CAPTION, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, true, true)


# ============================================================= save/load (best)
func _load_best() -> Dictionary:
	var cfg := ConfigFile.new()
	var out := {"last_mode": 1, "last_cargo": CARGO_COILS}
	if cfg.load("user://flatbed_best.cfg") != OK:
		return out
	out["last_mode"] = cfg.get_value("meta", "last_mode", 1)
	out["last_cargo"] = cfg.get_value("meta", "last_cargo", CARGO_COILS)
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
	cfg.set_value("meta", "last_cargo", String(best_cfg.get("last_cargo", CARGO_COILS)))
	for i in range(MODES.size()):
		var key := "mode_%d" % i
		if best_cfg.has(key):
			var row: Dictionary = best_cfg[key]
			cfg.set_value(key, "grade", int(row.get("grade", 0)))
			cfg.set_value(key, "elapsed", float(row.get("elapsed", 0.0)))
			cfg.set_value(key, "clean_stops", int(row.get("clean_stops", 0)))
	cfg.save("user://flatbed_best.cfg")


# ============================================================= save/load (scores)
func _scores_key(mode: int, cargo: String) -> String:
	return "route%d_%s" % [mode, cargo]


func _load_scores() -> Dictionary:
	var out: Dictionary = {}
	var cfg := ConfigFile.new()
	if cfg.load("user://flatbed_scores.cfg") != OK:
		return out
	for section in cfg.get_sections():
		var arr: Array = []
		for i in range(10):
			var key := "r%d" % i
			if cfg.has_section_key(section, key):
				var v: Dictionary = cfg.get_value(section, key, {})
				if not v.is_empty():
					arr.append(v)
		out[section] = arr
	return out


func _save_scores() -> void:
	var cfg := ConfigFile.new()
	for section in scores_cfg.keys():
		var arr: Array = scores_cfg[section]
		for i in range(arr.size()):
			cfg.set_value(section, "r%d" % i, arr[i])
	cfg.save("user://flatbed_scores.cfg")


func _scores_for_current() -> Array:
	return scores_cfg.get(_scores_key(mode_ix, cargo_kind), [])


func _score_qualifies(score: int) -> bool:
	if score <= 0:
		return false
	var arr: Array = _scores_for_current()
	if arr.size() < 10:
		return true
	return score > int(arr[arr.size() - 1].get("score", 0))


func _commit_score(nm: String, score: int) -> int:
	# Returns 1-based rank, or -1 if not placed.
	var key := _scores_key(mode_ix, cargo_kind)
	var arr: Array = scores_cfg.get(key, []).duplicate()
	var entry := {
		"name": nm,
		"score": score,
		"cargo": cargo_kind,
		"racks": racks_at_finish,
		"time": float(elapsed),
	}
	arr.append(entry)
	arr.sort_custom(func(a, b): return int(a.get("score", 0)) > int(b.get("score", 0)))
	if arr.size() > 10:
		arr.resize(10)
	scores_cfg[key] = arr
	_save_scores()
	for i in range(arr.size()):
		if arr[i] == entry:
			return i + 1
	return -1
