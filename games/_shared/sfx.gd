extends Node
## Procedural SFX bus. Register as autoload "SFX".
## Everything is synthesized through AudioStreamGenerator so the web build has
## zero audio assets. Gated on first user input (web audio restriction).

const SAMPLE_RATE := 44100.0
const BUFFER_LENGTH := 0.4  # seconds per clip
const MAX_VOICES := 6

var _unlocked := false
var _volume := 0.7
var _muted := false
var _voices: Array[AudioStreamPlayer] = []
var _ix := 0


func _ready() -> void:
	for i in range(MAX_VOICES):
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = SAMPLE_RATE
		gen.buffer_length = BUFFER_LENGTH
		p.stream = gen
		add_child(p)
		_voices.append(p)
	# Keep running while scenes pause; it is handy for menu clicks.
	process_mode = Node.PROCESS_MODE_ALWAYS


func unlock_on_first_input() -> void:
	_unlocked = true


func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)


func set_muted(m: bool) -> void:
	_muted = m


func click() -> void:
	_play(_render(_env(0.08, 0.004, 0.07), _tone_square(1800.0, 0.08)))


func confirm() -> void:
	_play(_render(_env(0.14, 0.004, 0.13), _tone_blend(880.0, 1320.0, 0.14)))


func success() -> void:
	# Little three-note arpeggio.
	var frames: PackedVector2Array = _concat([
		_render(_env(0.10, 0.004, 0.09), _tone_sine(880.0, 0.10)),
		_render(_env(0.10, 0.004, 0.09), _tone_sine(1108.73, 0.10)),
		_render(_env(0.16, 0.004, 0.15), _tone_sine(1318.51, 0.16)),
	])
	_play(frames)


func fail() -> void:
	_play(_render(_env(0.20, 0.004, 0.19), _tone_descent(440.0, 180.0, 0.20)))


func tick() -> void:
	_play(_render(_env(0.04, 0.002, 0.035), _tone_sine(2200.0, 0.04)), 0.5)


func kaching() -> void:
	# Short bright bell plus a lower partial. Not a real cash register — a
	# recognisable "money" cue in a few sines.
	var frames: PackedVector2Array = _concat([
		_render(_env(0.05, 0.003, 0.045), _tone_blend(1760.0, 2637.0, 0.05)),
		_render(_env(0.22, 0.004, 0.21), _tone_blend(1318.51, 1975.53, 0.22)),
	])
	_play(frames, 0.9)


# -- synthesis helpers --------------------------------------------------------
func _env(dur: float, attack: float, decay: float) -> PackedFloat32Array:
	var n := int(dur * SAMPLE_RATE)
	var atk := int(attack * SAMPLE_RATE)
	var dec := int(decay * SAMPLE_RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var g := 1.0
		if i < atk and atk > 0:
			g = float(i) / float(atk)
		elif i > n - dec and dec > 0:
			g = float(n - i) / float(dec)
		out[i] = clampf(g, 0.0, 1.0)
	return out


func _tone_sine(freq: float, dur: float) -> PackedFloat32Array:
	var n := int(dur * SAMPLE_RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var step: float = TAU * freq / SAMPLE_RATE
	for i in range(n):
		out[i] = sin(phase)
		phase += step
	return out


func _tone_square(freq: float, dur: float) -> PackedFloat32Array:
	var sine := _tone_sine(freq, dur)
	var out := PackedFloat32Array()
	out.resize(sine.size())
	for i in range(sine.size()):
		out[i] = 1.0 if sine[i] >= 0.0 else -1.0
	return out


func _tone_blend(f1: float, f2: float, dur: float) -> PackedFloat32Array:
	var a := _tone_sine(f1, dur)
	var b := _tone_sine(f2, dur)
	var out := PackedFloat32Array()
	out.resize(a.size())
	for i in range(a.size()):
		out[i] = (a[i] + b[i]) * 0.5
	return out


func _tone_descent(f_start: float, f_end: float, dur: float) -> PackedFloat32Array:
	var n := int(dur * SAMPLE_RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t: float = float(i) / float(n)
		var f: float = lerp(f_start, f_end, t)
		phase += TAU * f / SAMPLE_RATE
		out[i] = sin(phase)
	return out


func _render(env: PackedFloat32Array, tone: PackedFloat32Array) -> PackedVector2Array:
	var n: int = mini(env.size(), tone.size())
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var s: float = env[i] * tone[i] * 0.35
		out[i] = Vector2(s, s)
	return out


func _concat(parts: Array) -> PackedVector2Array:
	var total := 0
	for p: PackedVector2Array in parts:
		total += p.size()
	var out := PackedVector2Array()
	out.resize(total)
	var i := 0
	for p: PackedVector2Array in parts:
		for v in p:
			out[i] = v
			i += 1
	return out


func _play(frames: PackedVector2Array, gain: float = 1.0) -> void:
	if _muted or _volume <= 0.0 or not _unlocked or frames.is_empty():
		return
	var p: AudioStreamPlayer = _voices[_ix]
	_ix = (_ix + 1) % MAX_VOICES
	p.volume_db = linear_to_db(clampf(_volume * gain, 0.0, 1.0))
	if not p.playing:
		p.play()
	var pb := p.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb == null:
		return
	var room := pb.get_frames_available()
	var push: PackedVector2Array = frames.slice(0, mini(frames.size(), room))
	pb.push_buffer(push)
