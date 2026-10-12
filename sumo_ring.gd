class_name SumoRing
extends Arena
## Sumo Ring minigame: a round clay platform floating over the sea. Knock everyone off; last bowler standing wins.
## Everyone still on the ring scores each time someone goes over; the last one standing gets a bonus.

const RING_R := 8.5
const OUT_Y := -2.5  # below the platform's top: you're out

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


func setup(is_server: bool) -> void:
	_server = is_server
	half_w = RING_R + 2.0  # the camera stays over the ring
	_environment()
	_floor_and_walls()
	_decor()


func safe_radius() -> float:
	return RING_R - 1.4


func server_update(_dt: float, beasts: Array) -> void:
	for b: Beast in beasts:
		if not b.out and b.global_position.y < OUT_Y and game:
			_ring_out(b)


func _ring_out(b: Beast) -> void:
	if game.over:
		return
	var scores: Dictionary = game.scores
	var players: Dictionary = get_node("/root/Net").players  # autoloads by path: tests compile this script without them
	var by := b.last_toucher if b.state >= Beast.BALL and b.last_toucher != 0 else (b.last_hit_by if b.since_hit < 4.0 else 0)
	b.set_out()
	for pid in game.beasts:
		if not game.beasts[pid].out and scores.has(pid):
			scores[pid].total += 1
	if by != 0 and by != b.pid and scores.has(by) and players.has(by):
		scores[by].kos += 1
		game.feed(players[by].name, players[by].color, "RING OUT", Color("e5383b"), b.display_name, b.color)
	else:
		game.feed(b.display_name, b.color, "FELL OFF", Color("6a5a8a"))
	var alive: Array = game.beasts.values().filter(func(x): return not x.out)
	if alive.size() <= 1 and game.beasts.size() > 1:
		if alive.size() == 1 and scores.has(alive[0].pid):
			scores[alive[0].pid].total += 3
			game.feed(alive[0].display_name, alive[0].color, "LAST ONE STANDING +3", Color("c79a00"))
		get_tree().create_timer(1.5).timeout.connect(game.end_match)
	game.push_scores()


func carry_prompts(_me: Beast) -> Array:
	return [["HOLD LMB", "WIND UP"], ["RELEASE", "THROW THEM OFF!"]]


func bot_carry(b: Beast, m: Dictionary, inp: Dictionary, dt: float) -> Dictionary:
	## Carry them to the nearest edge and throw them over it.
	var pos := Vector2(b.global_position.x, b.global_position.z)
	var out := pos / pos.length() if pos.length() > 0.5 else Vector2(0, 1)
	if pos.length() < safe_radius() - 1.0 and m.get("wind", -1.0) < 0.0:
		inp.move = out
		return inp
	inp.move = out * 0.2  # face outward while winding up
	return super(b, m, inp, dt)


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
