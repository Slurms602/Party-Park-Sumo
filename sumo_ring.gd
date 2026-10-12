class_name SumoRing
extends Arena
## Sumo Ring minigame: a round clay ring floating over the sea. No punches and no knockouts: grab belts, shove and
## charge to drive everyone else over the edge. Everyone still in scores when someone goes over, whoever put them
## there scores again, and the last one standing gets a bonus.

const RING_R := 8.5
const OUT_Y := -2.5  # below the platform's top: you're out
const GRIP_TIME := 4.0  # then a grip slips (Gang Beasts' grab drain)
const GRIP_GAP := 1.0  # how far apart a grip holds two wrestlers
const SHOVE_REACH := 1.5
const SHOVE := 70.0  # m/s² a shove pushes with, a beat long: more than anyone's footing (Beast caps that at 60)
const HEAVE := 42.0  # a heave is weaker, but mashed it adds to your walking, so the pair moves your way

var _pushes := {}  # host: pid -> [force (m/s²), seconds left] of a push in progress

const CLAY_SHADER := """
shader_type spatial;
varying vec3 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	float r = length(lp.xz);
	float grain = fract(sin(dot(floor(lp.xz * 24.0), vec2(12.9898, 78.233))) * 43758.5453);
	vec3 clay = mix(vec3(0.62, 0.38, 0.2), vec3(0.55, 0.33, 0.17), grain * 0.6);  // it faces the sun: keep it deep
	float ring = smoothstep(0.06, 0.0, abs(r - 6.6));  // the inner line
	float starts = step(abs(lp.x), 0.9) * step(abs(abs(lp.z) - 1.0), 0.07);  // the two starting lines
	ALBEDO = mix(clay, vec3(0.97, 0.95, 0.9), max(ring, starts));
	ROUGHNESS = 0.9;
}
"""


func _init() -> void:
	damage = 0.0
	go_word = "Hakkeyoi!"  # what the referee shouts to start a bout
	punch_word = "SHOVE"
	dive_word = "CHARGE"
	stats = [["Ring outs", "kos"]]


func setup(is_server: bool) -> void:
	_server = is_server
	half_w = RING_R + 2.0  # the camera stays over the ring
	_environment()
	_floor_and_walls()
	_decor()


func server_update(dt: float, beasts: Array) -> void:
	for b: Beast in beasts:
		if _pushes.has(b.pid):
			b.apply_central_force(_pushes[b.pid][0] * b.mass)
			_pushes[b.pid][1] -= dt
			if _pushes[b.pid][1] <= 0.0:
				_pushes.erase(b.pid)
		if not b.out and b.global_position.y < OUT_Y and game:
			_ring_out(b)


func _ring_out(b: Beast) -> void:
	if game.over:
		return
	var scores: Dictionary = game.scores
	var players: Dictionary = get_node("/root/Net").players  # autoloads by path: tests compile this script without them
	var by := b.last_hit_by if b.since_hit < 4.0 else 0
	b.set_out()
	for pid in game.beasts:
		if not game.beasts[pid].out and scores.has(pid):
			scores[pid].total += 1
	if by != 0 and by != b.pid and scores.has(by) and players.has(by):
		scores[by].kos += 1
		scores[by].total += 1
		game.feed(players[by].name, players[by].color, "RING OUT +1", Color("e5383b"), b.display_name, b.color)
	else:
		game.feed(b.display_name, b.color, "STEPPED OUT", Color("6a5a8a"))
	var alive: Array = game.beasts.values().filter(func(x): return not x.out)
	if alive.size() <= 1 and game.beasts.size() > 1:
		if alive.size() == 1 and scores.has(alive[0].pid):
			scores[alive[0].pid].total += 3
			game.feed(alive[0].display_name, alive[0].color, "LAST ONE STANDING +3", Color("c79a00"))
		get_tree().create_timer(1.5).timeout.connect(game.end_match)
	game.push_scores()


# ---------------------------------------------------------------- wrestling

func buttons(b: Beast, inp: Dictionary, dt: float) -> bool:
	## RMB grips the belt of whoever is in front of you. LMB shoves (tap) or shoves hard (hold);
	## in a grip it heaves you both forward (mash it) or throws them (hold).
	var o: Beast = b.holding if b.holding is Beast else null
	if o and (not inp.get("grab", false) or o.out or b.hold_time > GRIP_TIME or minf(o.global_position.y, b.global_position.y) < -0.6):
		_let_go(b)  # nobody holds on going over the edge, or drags the other over
		o = null
	elif o == null and inp.get("grab", false) and b.cooldown.grab <= 0.0:
		o = b._nearest(1.3, -0.2 if b._assist else 0.2)
		if o and o.held_by == null:
			b.holding = o
			b.hold_time = 0.0
			o.held_by = b
			b.fx.emit("thud", b.global_position, -4.0)
		else:
			o = null
	b.reaching = inp.get("grab", false) and o == null
	if o:
		b.hold_time += dt
		_pull(b, o)
	if b._pressed(inp, "punch") and b.cooldown.punch <= 0.0:
		b.charging = true
		b.charge = 0.0
	if b.charging:
		b.charge = minf(b.charge + dt, Beast.FULL_CHARGE)
		if not inp.get("punch", false):
			var power := b.charge / Beast.FULL_CHARGE
			b.charging = false
			b.charge = 0.0
			if b.holding is Beast and power > 0.35:
				_throw(b, b.holding, power)
			elif b.holding is Beast:
				_heave(b, b.holding)
			else:
				_shove(b, power)
	return true


func _let_go(b: Beast) -> void:
	b.release_hold()
	b.cooldown.grab = 0.8


func _pull(b: Beast, o: Beast) -> void:
	## A grip ties two wrestlers together like a short rope: walk into them to push, walk away to drag them.
	## It pulls on both, so whoever drives harder moves the pair.
	var d := (o.global_position - b.global_position) * Vector3(1, 0, 1)
	var dist := d.length()
	if dist > GRIP_GAP + 1.2:
		_let_go(b)  # torn loose
		return
	if dist > GRIP_GAP:
		var n := d / dist
		var apart := maxf((o.linear_velocity - b.linear_velocity).dot(n), 0.0)
		var f := n * ((dist - GRIP_GAP) * 120.0 + apart * 8.0)
		o.apply_central_force(-f * o.mass)
		b.apply_central_force(f * b.mass)
	o.last_hit_by = b.pid  # whoever had hold of you gets the credit if you go over
	o.since_hit = 0.0


func _heave(b: Beast, o: Beast) -> void:
	## A drive the way you're facing that carries the pair with you.
	var f := b._forward()
	b.cooldown.punch = 0.12
	b.punch_t = [Beast.PUNCH_TIME * 0.6, Beast.PUNCH_TIME * 0.6]
	_push(b, o, f * HEAVE, 0.15)
	_pushes[b.pid] = [f * HEAVE * 0.8, 0.15]  # you go with them
	b.fx.emit("thud", (b.global_position + o.global_position) * 0.5, -2.0)


func _push(b: Beast, o: Beast, f: Vector3, t: float) -> void:
	_pushes[o.pid] = [f * _brace(o, f), t]
	o.last_hit_by = b.pid
	o.since_hit = 0.0
	o.stagger = maxf(o.stagger, 0.2)
	o.hurt.emit(o, b.pid, f, 0.3, "")  # the hit reaction everyone sees


func _throw(b: Beast, o: Beast, power: float) -> void:
	## Let go and fling them the way you're facing, off their feet.
	_let_go(b)
	b.cooldown.grab = 1.0
	var f := b._forward()
	o.take_hit(b.pid, f, 0.0, lerpf(5.5, 8.5, power) * _brace(o, f), 0.4, lerpf(0.45, 0.8, power), "THROW!" if power > 0.7 else "")
	b.apply_central_impulse(-f * b.mass)
	b.fx.emit("smack", (b.global_position + o.global_position) * 0.5 + Vector3.UP * 0.3, 0.0)


func _shove(b: Beast, power: float) -> void:
	## Both palms out (tsuppari). It doesn't hurt, it just moves them; a held one knocks them off their feet (and loose).
	b.cooldown.punch = lerpf(0.3, 0.6, power)
	b.punch_t = [Beast.PUNCH_TIME, Beast.PUNCH_TIME]
	var o := b._nearest(3.0 if b._assist else SHOVE_REACH, 0.0 if b._assist else 0.35)
	if o:
		var to := (o.global_position - b.global_position) * Vector3(1, 0, 1)
		b.facing = atan2(-to.x, -to.z)  # a little aim help, like punches
	var f := b._forward()
	b.apply_central_impulse(f * (1.5 + power * 2.0) * b.mass)
	if o == null:
		b.fx.emit("whiff", b.global_position + f, -8.0)
		return
	var at := (b.global_position + o.global_position) * 0.5 + Vector3.UP * 0.3
	if power < 0.5:
		_push(b, o, f * SHOVE, 0.12)
		b.fx.emit("punch", at, 0.0)
		return
	o.take_hit(b.pid, f, 0.0, lerpf(6.0, 8.5, power) * _brace(o, f), 0.3, lerpf(0.35, 0.5, power), "OSHI!" if power > 0.95 else "")
	b.fx.emit("smack", at, 0.0)


func _brace(o: Beast, f: Vector3) -> float:
	## At the straw bales a wrestler on their feet digs in: pushes toward the edge move them half as far.
	var r := Vector3(o.global_position.x, 0.0, o.global_position.z)
	return 0.5 if r.length() > RING_R - 1.6 and f.dot(r.normalized()) > 0.0 and o.down_t <= 0.0 else 1.0


func prompts(me: Beast, tips: bool) -> Array:
	if me.holding != null or me.net_holding:
		return [["MASH LMB", "HEAVE"], ["HOLD LMB", "THROW"]]
	if tips:
		return [["LMB", "SHOVE"], ["HOLD RMB", "GRAB THEIR BELT"], ["SHIFT", "CHARGE"]]
	return []


func bot_think(b: Beast, dt: float) -> Dictionary:
	## Bots get round to the middle side of someone, then grip and drive them out (or shove, or charge),
	## and keep off the edge themselves.
	var m := b.bot_mem
	var inp := {move = Vector2.ZERO, jump = false, punch = false, grab = false, dive = false}
	m.t = m.get("t", randf()) + dt
	m.retarget = m.get("retarget", 0.0) - dt
	if m.retarget <= 0.0 or not is_instance_valid(m.get("foe")) or m.foe.out:
		m.foe = b._nearest(RING_R * 2.5, -1.0)
		m.retarget = randf_range(1.0, 2.5)
		m.plan = "grip" if randf() < 0.6 else "shove"
		m.wait = randf_range(0.4, 1.6)  # size them up before going in
	var me := Vector2(b.global_position.x, b.global_position.z)
	var foe: Beast = m.foe
	var lmb := ""  # what LMB should do now: "" nothing, "tap" or "hold"
	if foe == null:
		inp.move = -me.limit_length(1.0) * 0.5
	else:
		var at := Vector2(foe.global_position.x, foe.global_position.z)
		var to := at - me
		var d := to.length()
		var out := at.normalized() if at.length() > 0.5 else to.normalized()  # their nearest way off
		var edgy := at.length() > RING_R - 2.5
		if b.holding is Beast:
			inp.grab = true
			inp.move = (to.normalized() * 0.4 + out).normalized()  # walk them out
			if me.length() > RING_R - 1.3:
				inp.grab = false  # not over the edge with them
			lmb = "hold" if edgy and m.plan == "grip" and fmod(m.t, 2.0) < 0.2 else "tap"
		elif b.held_by != null:
			inp.grab = m.plan == "grip"  # grip back and fight it out, or shove free
			inp.move = -me.normalized() if me.length() > 1.0 else to.normalized()
			lmb = "" if inp.grab else "hold"
		elif d > 1.4 or m.wait > 0.0:
			m.wait -= dt
			var goal := at - out * (2.4 if m.wait > 0.0 else 1.2) if d > 2.2 or m.wait > 0.0 else at  # from the middle side
			inp.move = (goal - me).limit_length(1.0) * (0.6 if m.wait > 0.0 else 0.9)
			inp.dive = m.wait <= 0.0 and d > 3.0 and d < 6.0 and edgy and randf() < dt * 0.3
		else:
			inp.move = to.normalized() * 0.4
			inp.grab = m.plan == "grip"
			lmb = "" if inp.grab else ("hold" if edgy else "tap")
	if me.length() > RING_R - 1.8 and not b.holding is Beast:  # too close to the edge: step back in
		inp.move = (inp.move * 0.3 - me.normalized()).limit_length(1.0)
		inp.dive = false
	# One LMB press at a time: a tap or a charge, then a breather.
	m.p = m.get("p", 9.0) + dt
	if lmb != "" and m.p > m.get("hold", 0.0) + m.get("rest", 0.0):
		m.p = 0.0
		m.hold = 0.05 if lmb == "tap" else randf_range(0.5, 0.9)
		m.rest = randf_range(0.1, 0.3) if lmb == "tap" else randf_range(0.3, 0.8)
	inp.punch = m.p < m.get("hold", 0.0)
	return inp


func _environment() -> void:
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color("3d8fe6")
	psm.sky_horizon_color = Color("bfe2ff")
	psm.ground_horizon_color = Color("bfe2ff")
	psm.ground_bottom_color = Color("1f5f9e")
	sky.sky_material = psm
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("d6ebff")
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = not Look.fast()
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color("bfe2ff")
	env.fog_density = 0.006
	env.fog_sky_affect = 0.0
	if Look.high():
		Look.dress_env(env, Color("e8f4ff"), 0.0012)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_color = Color("fff3dc")
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	if Look.fast():
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 40.0
	add_child(sun)


func _floor_and_walls() -> void:
	# The platform: a fat cylinder whose top is at y = 0. Nothing stops you going over the edge.
	var shape := CylinderShape3D.new()
	shape.radius = RING_R
	shape.height = 2.0
	_body(shape, Vector3(0, -1.0, 0), 0.9)
	var top := CylinderMesh.new()
	top.top_radius = RING_R
	top.bottom_radius = RING_R
	top.height = 0.6
	top.radial_segments = 64
	var clay := ShaderMaterial.new()
	clay.shader = Shader.new()
	clay.shader.code = CLAY_SHADER
	Look.mesh(self, top, clay, Vector3(0, -0.3, 0))
	var side := CylinderMesh.new()  # the timber drum under the clay, narrowing into a rocky base
	side.top_radius = RING_R + 0.05
	side.bottom_radius = RING_R * 0.92
	side.height = 1.6
	side.radial_segments = 64
	Look.mesh(self, side, Look.toy(Color("8a5a36"), 0.8, false), Vector3(0, -1.4, 0))
	var base := CylinderMesh.new()
	base.top_radius = RING_R * 0.9
	base.bottom_radius = 2.0
	base.height = 6.0
	base.radial_segments = 24
	Look.mesh(self, base, Look.toy(Color("6e6a73"), 0.95, false), Vector3(0, -5.2, 0))
	var rope := TorusMesh.new()  # the straw rope just inside the edge: a line to stay inside, not a wall
	rope.inner_radius = RING_R - 0.42
	rope.outer_radius = RING_R - 0.18
	rope.rings = 64
	var straw := Look.toy(Color("e6cf8a"), 0.85, false)
	Look.mesh(self, rope, straw, Vector3(0, 0.02, 0)).scale = Vector3(1, 0.5, 1)
	var sea := PlaneMesh.new()
	sea.size = Vector2(400, 400)
	var water := Look.toy(Color("2a7fd4"), 0.08, false)
	water.metallic = 0.3
	Look.mesh(self, sea, water, Vector3(0, -7.0, 0))


func _decor() -> void:
	# Four corner posts with tassels in the sumo colours (no roof: the camera looks down from where it would hang),
	# and a few far-off islands.
	var post_mat := Look.toy(Color("b33a2e"), 0.5)
	var tassels := [Color("2a8f5a"), Color("e5383b"), Color("f2f2f2"), Color("1f2a44")]
	for k in 4:
		var a := PI * 0.25 + PI * 0.5 * k
		var p := Vector3(cos(a), 0, sin(a)) * (RING_R + 1.6)
		var post := CylinderMesh.new()
		post.top_radius = 0.18
		post.bottom_radius = 0.22
		post.height = 6.0
		Look.mesh(self, post, post_mat, p + Vector3(0, -0.5, 0))
		var tassel := SphereMesh.new()
		tassel.radius = 0.35
		tassel.height = 1.2
		Look.mesh(self, tassel, Look.toy(tassels[k], 0.7), p + Vector3(0, 2.6, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for k in 7:
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(45.0, 90.0)
		var island := CylinderMesh.new()
		island.top_radius = rng.randf_range(4.0, 9.0)
		island.bottom_radius = island.top_radius * 1.25
		island.height = 2.0
		var at := Vector3(sin(a) * d, -6.5, -cos(a) * d - 20.0)
		Look.mesh(self, island, Look.toy(Color("e9d39a"), 0.9, false), at)
		var hill := SphereMesh.new()
		hill.radius = island.top_radius * 0.8
		hill.height = island.top_radius * 0.9
		Look.mesh(self, hill, Look.toy(Color("5fae5a"), 0.9, false), at + Vector3(0, 1.0, 0))
	var sign := Label3D.new()
	sign.text = "SUMO RING"
	sign.font = Look.title_font()
	sign.font_size = 160
	sign.outline_size = 28
	sign.modulate = Color("fff4df")
	sign.outline_modulate = Color("b33a2e")
	sign.pixel_size = 0.01
	sign.position = Vector3(0, 4.0, -RING_R - 3.0)
	add_child(sign)
	if Look.fast():
		Look.no_shadow(self)
