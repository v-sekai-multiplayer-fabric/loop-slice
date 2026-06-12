extends Node3D
# The playable loop client: Hub deck -> teleporter -> Field room -> melee combo
# -> loot grab -> return. Flatscreen (WASD + mouse, SPACE attack, E grab,
# T teleport vote). BOT=1 drives the same loop unattended for the smoke.
const PORT = 54400

static func server_host() -> String:
	var env := OS.get_environment("LOOP_HOST")
	if env != "": return env
	if FileAccess.file_exists("res://server_host.txt"):
		var h := FileAccess.open("res://server_host.txt", FileAccess.READ).get_as_text().strip_edges()
		if h != "": return h
	return "127.0.0.1"

var peer: WebTransportPeer
var my_id := 0
var phase := "hub"
var bot := OS.get_environment("BOT") == "1"
var xr := OS.get_environment("XR") == "1"
var xr_interface: XRInterface
var xr_origin: XROrigin3D
var right_hand: XRController3D
var left_hand: XRController3D
var bot_name: String = OS.get_environment("BOT_NAME") if OS.get_environment("BOT_NAME") != "" else "player"
var avatar: CharacterBody3D
var remotes := {}      # pid -> MeshInstance3D
var enemy_node: MeshInstance3D
var loot_node: MeshInstance3D
var fade: ColorRect
var hud: Label
var t0 := 0
var got_grant := false; var got_reject := false; var loop_done := false
var bot_attack_timer := 0.0
var send_accum := 0.0

func _ready() -> void:
	if xr:
		xr_interface = XRServer.find_interface("OpenXR")
		if xr_interface and (xr_interface.is_initialized() or xr_interface.initialize()):
			get_viewport().use_xr = true
			print("XR session up: ", xr_interface.get_name())
		else:
			printerr("XR requested but OpenXR failed to initialize"); get_tree().quit(3); return
	_build_world()
	peer = WebTransportPeer.new()
	if peer.create_client(server_host(), PORT, "/wt") != OK:
		printerr("connect failed"); get_tree().quit(1); return
	t0 = Time.get_ticks_msec()

func _build_world() -> void:
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, -30, 0); add_child(sun)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.05, 0.07, 0.12)
	e.ambient_light_color = Color(0.5, 0.5, 0.6); e.ambient_light_energy = 0.6
	env.environment = e; add_child(env)
	# hub deck
	_slab(Vector3(0, -0.5, 4), Vector3(12, 1, 8), Color(0.25, 0.3, 0.4), "hub_floor")
	# teleporter ring
	var ring := MeshInstance3D.new(); var cyl := CylinderMesh.new()
	cyl.top_radius = 1.4; cyl.bottom_radius = 1.4; cyl.height = 0.1
	ring.mesh = cyl; ring.position = Vector3(0, 0.05, 6.5)
	var rm := StandardMaterial3D.new(); rm.albedo_color = Color(0.2, 0.9, 0.9); rm.emission_enabled = true
	rm.emission = Color(0.1, 0.7, 0.8); ring.material_override = rm; add_child(ring)
	# field arena (visible during field phase, just farther out)
	_slab(Vector3(0, -0.5, -6), Vector3(14, 1, 10), Color(0.3, 0.22, 0.2), "field_floor")
	# avatar
	avatar = CharacterBody3D.new()
	var am := MeshInstance3D.new(); var cap := CapsuleMesh.new(); cap.height = 1.6; cap.radius = 0.35
	am.mesh = cap; am.position.y = 0.8
	var amat := StandardMaterial3D.new(); amat.albedo_color = Color(0.9, 0.8, 0.2); am.material_override = amat
	avatar.add_child(am)
	if xr:
		xr_origin = XROrigin3D.new()
		var xr_cam := XRCamera3D.new(); xr_cam.position.y = 1.7
		xr_origin.add_child(xr_cam)
		left_hand = XRController3D.new(); left_hand.tracker = "left_hand"
		right_hand = XRController3D.new(); right_hand.tracker = "right_hand"
		xr_origin.add_child(left_hand); xr_origin.add_child(right_hand)
		for h in [left_hand, right_hand]:
			var hm := MeshInstance3D.new(); var hs := SphereMesh.new(); hs.radius = 0.06; hs.height = 0.12
			hm.mesh = hs; h.add_child(hm)
		avatar.add_child(xr_origin)
		right_hand.button_pressed.connect(_on_xr_button.bind(true))
		left_hand.button_pressed.connect(_on_xr_button.bind(false))
	else:
		var cam := Camera3D.new(); cam.position = Vector3(0, 3.2, 4.5); cam.rotation_degrees.x = -30
		avatar.add_child(cam)
	avatar.position = Vector3(0, 0, 4); add_child(avatar)
	# enemy + loot placeholders
	enemy_node = _ball(Vector3(0, 0.9, -4), 0.9, Color(0.85, 0.2, 0.2)); enemy_node.visible = false
	loot_node = _ball(Vector3(0, 0.4, -4), 0.4, Color(0.95, 0.8, 0.1)); loot_node.visible = false
	# fade + hud
	var ui := CanvasLayer.new(); add_child(ui)
	fade = ColorRect.new(); fade.color = Color(0, 0, 0, 0); fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE; ui.add_child(fade)
	hud = Label.new(); hud.position = Vector2(12, 8); hud.text = "connecting..."; ui.add_child(hud)

func _slab(pos: Vector3, size: Vector3, col: Color, n: String) -> void:
	var mi := MeshInstance3D.new(); var box := BoxMesh.new(); box.size = size
	mi.mesh = box; mi.position = pos; mi.name = n
	var m := StandardMaterial3D.new(); m.albedo_color = col; mi.material_override = m
	add_child(mi)

func _ball(pos: Vector3, r: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new(); var s := SphereMesh.new(); s.radius = r; s.height = r * 2
	mi.mesh = s; mi.position = pos
	var m := StandardMaterial3D.new(); m.albedo_color = col; m.emission_enabled = true
	m.emission = col * 0.4; mi.material_override = m
	add_child(mi); return mi

func _remote(pid: int) -> MeshInstance3D:
	if not remotes.has(pid):
		var mi := _ball(Vector3.ZERO, 0.45, Color(0.4, 0.6, 0.95))
		remotes[pid] = mi
	return remotes[pid]

func handle(msg: String) -> void:
	var p = msg.split(":")
	match p[0]:
		"welcome":
			my_id = int(p[1]); hud.text = "in hub as peer %d — T to vote teleport" % my_id
		"kit": hud.text += "  [kit: %s]" % p[1]
		"votes": if not bot: hud.text = "teleport votes %s" % p[1]
		"fade": fade.color.a = 1.0
		"phase":
			phase = p[1]; fade.color.a = 0.0
			if phase == "field":
				avatar.position = Vector3(randf_range(-3, 3), 0, 2)
				hud.text = "FIELD: SPACE to attack on the beat, E to grab loot"
			elif phase == "hub":
				avatar.position = Vector3(0, 0, 4)
				hud.text = "back in hub — loop complete"
				loop_done = true
				if bot:
					var verdict := "GRANT" if got_grant else ("REJECT" if got_reject else "NONE")
					print("BOT %s LOOP COMPLETE outcome=%s" % [bot_name, verdict])
					peer.put_packet("bye:x".to_utf8_buffer())
					get_tree().quit(0)
		"enemy":
			if p[1] == "spawned": enemy_node.visible = true
			elif p[1] == "hp" and int(p[2]) == 0: enemy_node.visible = false
		"loot":
			loot_node.visible = true
		"grant":
			got_grant = true; loot_node.visible = false
			hud.text = "GRANTED item %s!" % p[1]
		"reject":
			got_reject = true; loot_node.visible = false
		"fx": pass # combat feedback; the HUD shows phase text
		"p":
			var pid := int(p[1])
			if pid != my_id:
				_remote(pid).position = Vector3(float(p[2]), 0.45, float(p[3]))

func _physics_process(delta: float) -> void:
	if not peer: return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		handle(peer.get_packet().get_string_from_utf8())
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if Time.get_ticks_msec() - t0 > 30000 and not loop_done:
			printerr("BOT %s TIMEOUT pre-connect" % bot_name); get_tree().quit(1)
		return
	if my_id == 0:
		peer.put_packet(("join:%s" % bot_name).to_utf8_buffer())
		my_id = -1 # waiting for welcome
		return
	if my_id < 0: return
	if bot: _bot_drive(delta)
	else: _human_drive(delta)
	send_accum += delta
	if send_accum >= 0.1:
		send_accum = 0.0
		peer.put_packet(("pos:%.2f:%.2f" % [avatar.position.x, avatar.position.z]).to_utf8_buffer())
	if Time.get_ticks_msec() - t0 > 120000 and bot and not loop_done:
		printerr("BOT %s TIMEOUT phase=%s" % [bot_name, phase]); get_tree().quit(1)

func _on_xr_button(button: String, right: bool) -> void:
	if right and button == "trigger_click":
		peer.put_packet("attack:x".to_utf8_buffer())
	elif right and button == "ax_button":
		peer.put_packet("grab:x".to_utf8_buffer())
	elif not right and button == "by_button":
		peer.put_packet("teleport:x".to_utf8_buffer())

func _human_drive(delta: float) -> void:
	if xr and left_hand:
		var stick: Vector2 = left_hand.get_vector2("primary")
		var fwd: Vector3 = Vector3.FORWARD
		if xr_origin.has_node("XRCamera3D"):
			fwd = -(xr_origin.get_node("XRCamera3D") as XRCamera3D).global_transform.basis.z
		fwd.y = 0.0; fwd = fwd.normalized()
		var rightv: Vector3 = fwd.cross(Vector3.UP) * -1.0
		avatar.position += (fwd * -stick.y + rightv * stick.x) * 3.0 * delta
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	avatar.velocity = dir.normalized() * 4.0
	avatar.move_and_slide()
	if Input.is_key_pressed(KEY_T): peer.put_packet("teleport:x".to_utf8_buffer())
	if Input.is_action_just_pressed("ui_accept"): peer.put_packet("attack:x".to_utf8_buffer())
	if Input.is_key_pressed(KEY_E): peer.put_packet("grab:x".to_utf8_buffer())

var bot_voted := false
func _bot_drive(delta: float) -> void:
	match phase:
		"hub":
			if loop_done: return
			# walk to the teleporter ring, then vote once
			var target := Vector3(0, 0, 6.5)
			if avatar.position.distance_to(target) > 0.6:
				avatar.position = avatar.position.move_toward(target, 4.0 * delta)
			elif not bot_voted:
				bot_voted = true
				peer.put_packet("teleport:x".to_utf8_buffer())
		"field":
			# close to melee range of the enemy at (0,-4), then attack on the beat
			var target := Vector3(0.0, 0.0, -2.2)
			if avatar.position.distance_to(target) > 0.4:
				avatar.position = avatar.position.move_toward(target, 4.0 * delta)
				return
			bot_attack_timer += delta
			# 0.3 s ~= 9 ticks at 30 Hz — inside the [6,18] combo window
			if bot_attack_timer >= 0.3:
				bot_attack_timer = 0.0
				peer.put_packet("attack:x".to_utf8_buffer())
				peer.put_packet("grab:x".to_utf8_buffer()) # grabs only land once loot spawns
