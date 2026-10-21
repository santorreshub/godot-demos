extends Node3D
## FLATBED HAULER
## Get 4 steel coils from the mill to the dock before the clock runs out.
## Coils roll on hard braking, bumps and launches. Stop the truck and press R to set coil racks.
##
## Everything is built in code (zero imported assets). To swap in Blender models,
## replace the primitive meshes in _build_truck() and _spawn_coils() with .glb scenes.

const COIL_Z := [1.2, -0.4, -2.0, -3.6]
const DOCK_POS := Vector3(0, 0, -260)
const TIME_LIMIT := 120.0
const ENGINE_FORCE := 5000.0
const BRAKE_FORCE := 40.0
const MAX_SPEED := 24.0
const MAX_STEER := 0.45

var truck: VehicleBody3D
var coils: Array[RigidBody3D] = []
var lost := {}
var chock_shapes: Array[CollisionShape3D] = []
var chock_meshes: Array[MeshInstance3D] = []
var racks_on := false
var cam: Camera3D
var hud: Label
var banner: Label
var time_left := TIME_LIMIT
var finished := false

const STEEL := Color(0.62, 0.65, 0.7)
const LOST_RED := Color(0.85, 0.2, 0.15)


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_world()
	truck = _build_truck()
	_spawn_coils()
	_set_racks(false)
	_build_camera()
	_build_hud()


# ---------------------------------------------------------------- input
func _setup_input() -> void:
	var map := {
		"accelerate": [KEY_W, KEY_UP],
		"reverse": [KEY_S, KEY_DOWN],
		"left": [KEY_A, KEY_LEFT],
		"right": [KEY_D, KEY_RIGHT],
		"brake": [KEY_SPACE],
		"racks": [KEY_R],
		"restart": [KEY_ENTER],
	}
	for action in map:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- helpers
func _mat(c: Color, metal := 0.0, emissive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = 0.35 if metal > 0.0 else 0.85
	if emissive:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.5
	return m


func _box_mesh(size: Vector3, pos: Vector3, color: Color, parent: Node, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(color, metal)
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


func _sign(text: String, pos: Vector3, size := 96, color := Color.WHITE) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.modulate = color
	l.outline_size = 16
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	add_child(l)


# ---------------------------------------------------------------- world
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.5, 0.82)
	sm.sky_horizon_color = Color(0.98, 0.72, 0.5)
	sm.ground_horizon_color = Color(0.98, 0.72, 0.5)
	sm.ground_bottom_color = Color(0.3, 0.25, 0.2)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.85
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.95, 0.78, 0.62)
	env.fog_density = 0.0015
	env.glow_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 35, 0)
	sun.light_color = Color(1.0, 0.9, 0.78)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)


func _build_world() -> void:
	# Ground + road
	_static_box(Vector3(400, 1, 700), Vector3(0, -0.5, -200), Color(0.34, 0.29, 0.23))
	_box_mesh(Vector3(14, 0.02, 290), Vector3(0, 0.01, -125), Color(0.16, 0.16, 0.17), self)
	for i in range(28):
		_box_mesh(Vector3(0.25, 0.03, 4), Vector3(0, 0.02, 5 - i * 10.0), Color(0.95, 0.8, 0.2), self)

	# Steel mill at the start
	_static_box(Vector3(40, 18, 14), Vector3(0, 9, 26), Color(0.35, 0.33, 0.32))
	_static_box(Vector3(3, 30, 3), Vector3(-14, 15, 30), Color(0.4, 0.3, 0.28))
	_static_box(Vector3(3, 26, 3), Vector3(-8, 13, 30), Color(0.4, 0.3, 0.28))
	_sign("STEEL MILL", Vector3(0, 20, 18), 160, Color(1, 0.6, 0.25))

	# Speed bumps — each one tests your coils
	for z in [-35.0, -80.0, -170.0, -215.0]:
		_static_box(Vector3(14, 0.35, 1.2), Vector3(0, 0.1, z), Color(0.95, 0.75, 0.15))

	# Jersey-barrier chicane
	var side := 1.0
	for z in range(-105, -150, -12):
		_static_box(Vector3(8, 1.2, 0.8), Vector3(3.2 * side, 0.6, z), Color(0.82, 0.82, 0.8))
		side = -side

	# Some scenery on the shoulders
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in range(60):
		var x := rng.randf_range(14, 120) * (1 if rng.randf() > 0.5 else -1)
		var z := rng.randf_range(-320, 10)
		var h := rng.randf_range(2, 9)
		_box_mesh(Vector3(rng.randf_range(2, 6), h, rng.randf_range(2, 6)), Vector3(x, h / 2, z), Color(0.3, 0.27, 0.22).lerp(Color(0.45, 0.33, 0.24), rng.randf()), self)

	# Delivery dock
	var pad := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 8
	cyl.bottom_radius = 8
	cyl.height = 0.05
	cyl.material = _mat(Color(0.2, 0.9, 0.45), 0.0, true)
	pad.mesh = cyl
	pad.position = DOCK_POS + Vector3(0, 0.03, 0)
	add_child(pad)
	_static_box(Vector3(24, 6, 6), DOCK_POS + Vector3(0, 3, -14), Color(0.3, 0.35, 0.45))
	_sign("DOCK", DOCK_POS + Vector3(0, 9, -10), 160, Color(0.4, 1, 0.6))


# ---------------------------------------------------------------- truck
func _build_truck() -> VehicleBody3D:
	# VehicleBody3D drives along its local +Z. We rotate it 180° so it faces the dock (-Z).
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
	_box_mesh(Vector3(2.5, 0.5, 9.0), Vector3(0, 0.6, 0), Color(0.2, 0.2, 0.22), v, 0.4)
	_box_mesh(Vector3(2.52, 0.08, 6.8), Vector3(0, 0.86, -1.1), Color(0.45, 0.32, 0.2), v)

	# Cab
	var cab := CollisionShape3D.new()
	var cab_box := BoxShape3D.new()
	cab_box.size = Vector3(2.5, 2.1, 2.2)
	cab.shape = cab_box
	cab.position = Vector3(0, 1.9, 3.4)
	v.add_child(cab)
	_box_mesh(Vector3(2.5, 2.1, 2.2), Vector3(0, 1.9, 3.4), Color(0.75, 0.12, 0.1), v, 0.3)
	_box_mesh(Vector3(2.3, 0.8, 0.05), Vector3(0, 2.3, 4.51), Color(0.15, 0.25, 0.35), v, 0.6)

	# Headboard — stops coils from sliding into the cab
	var head := CollisionShape3D.new()
	var head_box := BoxShape3D.new()
	head_box.size = Vector3(2.5, 1.8, 0.2)
	head.shape = head_box
	head.position = Vector3(0, 1.75, 2.2)
	v.add_child(head)
	_box_mesh(Vector3(2.5, 1.8, 0.2), Vector3(0, 1.75, 2.2), Color(0.3, 0.3, 0.32), v, 0.5)

	# Permanent low cradles: keep coils seated under normal driving. A hard stop
	# or hitting a bump fast can still pop a coil over them.
	for z in COIL_Z:
		for dz in [0.42, -0.42]:
			var lip := CollisionShape3D.new()
			var lb := BoxShape3D.new()
			lb.size = Vector3(2.0, 0.1, 0.1)
			lip.shape = lb
			lip.position = Vector3(0, 0.9, z + dz)
			v.add_child(lip)
			_box_mesh(lb.size, lip.position, Color(0.12, 0.12, 0.12), v, 0.5)

	# Coil racks (chocks): one in front of and one behind each coil. Toggled with R.
	for z in COIL_Z:
		for dz in [0.75, -0.75]:
			var cs := CollisionShape3D.new()
			var cb := BoxShape3D.new()
			cb.size = Vector3(2.0, 0.35, 0.25)
			cs.shape = cb
			cs.position = Vector3(0, 1.025, z + dz)
			v.add_child(cs)
			chock_shapes.append(cs)
			chock_meshes.append(_box_mesh(cb.size, cs.position, Color(1.0, 0.8, 0.1), v))

	# Wheels: steer up front, drive in back (tandem)
	var wheels := [
		[Vector3(-1.25, 0.5, 3.2), true],
		[Vector3(1.25, 0.5, 3.2), true],
		[Vector3(-1.25, 0.5, -1.8), false],
		[Vector3(1.25, 0.5, -1.8), false],
		[Vector3(-1.25, 0.5, -3.2), false],
		[Vector3(1.25, 0.5, -3.2), false],
	]
	for data in wheels:
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
		tire.material = _mat(Color(0.07, 0.07, 0.07))
		wm.mesh = tire
		wm.rotation_degrees = Vector3(0, 0, 90)
		w.add_child(wm)
		v.add_child(w)

	add_child(v)
	return v


func _spawn_coils() -> void:
	for z in COIL_Z:
		var c := RigidBody3D.new()
		c.mass = 250.0
		var pm := PhysicsMaterial.new()
		pm.friction = 0.8
		pm.bounce = 0.05
		c.physics_material_override = pm
		c.continuous_cd = true
		# Rolling resistance: coils stay put under normal driving, but launches,
		# bumps at speed and panic stops will still send them rolling.
		c.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		c.angular_damp = 2.5

		# Coil axis runs side-to-side (X), so it rolls fore/aft — just like the real thing.
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
		om.material = _mat(STEEL, 0.9)
		outer.mesh = om
		outer.rotation_degrees = Vector3(0, 0, 90)
		outer.name = "Outer"
		c.add_child(outer)

		var eye := MeshInstance3D.new()
		var em := CylinderMesh.new()
		em.top_radius = 0.28
		em.bottom_radius = 0.28
		em.height = 1.22
		em.material = _mat(Color(0.08, 0.08, 0.09))
		eye.mesh = em
		eye.rotation_degrees = Vector3(0, 0, 90)
		c.add_child(eye)

		c.position = truck.transform * Vector3(0, 1.57, z)
		add_child(c)
		coils.append(c)


func _set_racks(on: bool) -> void:
	racks_on = on
	for cs in chock_shapes:
		cs.disabled = not on
	for m in chock_meshes:
		m.visible = on


# ---------------------------------------------------------------- camera + hud
func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 65
	add_child(cam)
	cam.global_position = truck.global_position + Vector3(0, 7, 15)
	cam.look_at(truck.global_position)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(20, 16)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 46)
	banner.add_theme_color_override("font_outline_color", Color.BLACK)
	banner.add_theme_constant_override("outline_size", 12)
	banner.text = "Haul 4 coils to the DOCK\nW/S drive · A/D steer · SPACE brake\nStop + R = set coil racks"
	layer.add_child(banner)
	get_tree().create_timer(4.0).timeout.connect(func(): if not finished: banner.text = "")


# ---------------------------------------------------------------- loop
func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
		return

	if finished:
		truck.engine_force = 0.0
		truck.brake = BRAKE_FORCE
		return

	var speed := truck.linear_velocity.length()
	var throttle := Input.get_action_strength("accelerate") - Input.get_action_strength("reverse")
	var steer_in := Input.get_action_strength("left") - Input.get_action_strength("right")
	if (throttle != 0.0 or steer_in != 0.0) and banner.text.begins_with("Haul"):
		banner.text = ""
	truck.steering = move_toward(truck.steering, steer_in * MAX_STEER, delta * 1.6)
	truck.engine_force = throttle * ENGINE_FORCE if speed < MAX_SPEED else 0.0
	truck.brake = BRAKE_FORCE if Input.is_action_pressed("brake") else 0.0

	if Input.is_action_just_pressed("racks"):
		if speed < 1.0:
			_set_racks(not racks_on)
			if racks_on:
				time_left -= 5.0  # strapping in costs time — that's the trade-off
				_flash("RACKS SET  (-5s)")
		else:
			_flash("STOP the truck first to set racks")

	_check_coils()

	time_left -= delta
	var on_truck := coils.size() - lost.size()
	if on_truck == 0:
		_finish("ALL COILS LOST\nThe claim is going to be ugly.")
	elif time_left <= 0.0:
		time_left = 0.0
		_finish("OUT OF TIME\nDetention charges incoming.")
	elif truck.global_position.distance_to(DOCK_POS) < 8.0 and speed < 2.0:
		var grade := "CLEAN LOAD" if on_truck == coils.size() else "PARTIAL DELIVERY"
		_finish("%s\n%d / %d coils · %ds left" % [grade, on_truck, coils.size(), int(time_left)])


func _check_coils() -> void:
	for c in coils:
		if lost.has(c):
			continue
		var p := truck.to_local(c.global_position)
		var on_deck := absf(p.x) < 1.8 and p.y > 0.6 and p.y < 3.5 and p.z > -5.2 and p.z < 2.6
		if not on_deck:
			lost[c] = true
			var outer := c.get_node("Outer") as MeshInstance3D
			(outer.mesh as CylinderMesh).material = _mat(LOST_RED, 0.6)
			_flash("COIL LOST!")


func _flash(text: String) -> void:
	if finished:
		return
	banner.text = text
	get_tree().create_timer(1.5).timeout.connect(func(): if not finished and banner.text == text: banner.text = "")


func _finish(text: String) -> void:
	finished = true
	banner.text = text + "\n\nENTER to run it again"


func _process(delta: float) -> void:
	if truck == null:
		return
	var target := truck.global_position
	var fwd := truck.global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized()
	var desired := target - fwd * 15.0 + Vector3.UP * 6.5
	cam.global_position = cam.global_position.lerp(desired, 1.0 - exp(-delta * 4.0))
	cam.look_at(target + Vector3.UP * 1.5, Vector3.UP)

	var mph := truck.linear_velocity.length() * 2.237
	hud.text = "TIME %d:%02d   |   %d mph   |   COILS %d/%d   |   RACKS: %s   |   DOCK %dm" % [
		int(time_left) / 60, int(time_left) % 60, mph,
		coils.size() - lost.size(), coils.size(),
		"ON" if racks_on else "OFF (stop + R)",
		int(truck.global_position.distance_to(DOCK_POS)),
	]
