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

var peer: MultiplayerPeer
var my_id := 0
var phase := "hub"
var bot := OS.get_environment("BOT") == "1"
var spectate := OS.get_environment("SPECTATE") == "1"
var _focus_order: Array = []
var _focus_idx: int = -1
var _spec_cam: Camera3D = null
var last_server_ms: int = 0
var welcome_ms: int = 0
var xr := OS.get_environment("XR") == "1" or OS.has_feature("mobile")
var xr_interface: XRInterface
var xr_origin: XROrigin3D
var right_hand: XRController3D
var left_hand: XRController3D
var xr_cam: XRCamera3D
# edge-detect XR buttons (poll, not signal — robust against signal-wiring quirks)
var _xr_prev := {"trigger": false, "ax": false, "by": false}
var bot_name: String = ("spectator" if OS.get_environment("SPECTATE") == "1" else (OS.get_environment("BOT_NAME") if OS.get_environment("BOT_NAME") != "" else "player"))
var avatar: CharacterBody3D
var remotes := {}      # pid -> MeshInstance3D
var enemy_node: MeshInstance3D
var enemy_hp := 100
# packets queued from outside _physics_process (e.g. the runtime MCP). Draining
# them inside the frame loop (next to tf/pong) sends through the SAME flushed path,
# so injected sends behave exactly like the client's own input.
var mcp_queue: Array = []
func mcp_send(s: String) -> void: mcp_queue.append(s)
# Control goes reliable; high-frequency "tf" (position) goes unreliable. On
# WebTransport each reliable packet opens a fresh bidi stream, so streaming tf
# reliably exhausts the QUIC stream limit in seconds and wedges all sends.
const CH_CONTROL := 0   # reliable, ordered: join/vote/attack/grab/pong/bye
const CH_POSITION := 1  # unreliable: high-frequency tf
func _put(s: String, reliable := true, channel := CH_CONTROL) -> void:
	if not peer: return
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(s.to_utf8_buffer())
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
	peer = _make_client_peer()
	if not peer:
		printerr("connect failed"); get_tree().quit(1); return
	t0 = Time.get_ticks_msec()

# Transport is switchable: ENet locally (stable), WebTransport with TRANSPORT=wt
# for the Quest-web path. Same text protocol either way.
func _make_client_peer() -> MultiplayerPeer:
	if OS.get_environment("TRANSPORT") == "wt":
		var w := WebTransportPeer.new()
		return w if w.create_client(server_host(), PORT, "/wt") == OK else null
	var e := ENetMultiplayerPeer.new()
	return e if e.create_client(server_host(), PORT) == OK else null

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
	if spectate:
		# high 3/4 tactical camera (FFT / Blue Archive style), frames hub -> field
		var tcam := Camera3D.new()
		tcam.position = Vector3(7.5, 12.5, 9.0)
		tcam.fov = 48.0
		add_child(tcam)
		tcam.look_at(Vector3(0.0, 0.5, -2.5), Vector3.UP)
		tcam.current = true
		_spec_cam = tcam
		var am0 = avatar.get_child(0)
		if am0: am0.visible = false       # do not draw the spectator body
	elif xr:
		xr_origin = XROrigin3D.new()
		xr_cam = XRCamera3D.new()   # head height comes from headset tracking, origin at floor
		# add_child(.., true) forces readable names ("XRCamera3D" not "@XRCamera3D@6")
		xr_origin.add_child(xr_cam, true)
		left_hand = XRController3D.new(); left_hand.name = "LeftHand"; left_hand.tracker = "left_hand"
		right_hand = XRController3D.new(); right_hand.name = "RightHand"; right_hand.tracker = "right_hand"
		xr_origin.add_child(left_hand, true); xr_origin.add_child(right_hand, true)
		for h in [left_hand, right_hand]:
			var hm := MeshInstance3D.new(); var hs := SphereMesh.new(); hs.radius = 0.06; hs.height = 0.12
			hm.mesh = hs; h.add_child(hm, true)
		avatar.add_child(xr_origin, true)
	else:
		var cam := Camera3D.new()
		cam.position = Vector3(0, 7.0, 6.0)        # high 3/4 tactical, frames you + the arena
		cam.rotation_degrees.x = -48
		cam.fov = 52
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

const ORB_PALETTE := [
	Color(0.40, 0.70, 1.00), Color(0.50, 1.00, 0.55), Color(1.00, 0.55, 0.85),
	Color(0.95, 0.85, 0.30), Color(0.65, 0.55, 1.00), Color(1.00, 0.60, 0.35)]

func _remote(pid: int, kind: String) -> Node3D:
	if not remotes.has(pid):
		var holder := Node3D.new()
		add_child(holder)
		var is_xr := kind == "xr"
		var col: Color = Color(0.98, 0.78, 0.12) if is_xr else ORB_PALETTE[pid % ORB_PALETTE.size()]
		# the xr_grid dot orb (player sphere + 6 axis dots + orientation lines)
		var orb = ClassDB.instantiate("XRGridOrientationOrb")
		holder.add_child(orb)
		orb.call("setup", col)
		orb.position.y = 0.9
		# label
		var lbl := Label3D.new()
		lbl.name = "Label3D"
		lbl.text = ("Q3 #%d" % pid) if is_xr else ("P%d" % pid)
		lbl.position = Vector3(0, 2.1, 0); lbl.font_size = 72; lbl.modulate = col
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		holder.add_child(lbl)
		# focus highlight ring (hidden unless focused)
		var ring := MeshInstance3D.new()
		var tor := TorusMesh.new(); tor.inner_radius = 0.7; tor.outer_radius = 0.85
		ring.mesh = tor; ring.position.y = 0.05; ring.name = "focus_ring"
		var rm := StandardMaterial3D.new(); rm.albedo_color = Color(1,1,1,0.9)
		rm.emission_enabled = true; rm.emission = Color(1,1,1); ring.material_override = rm
		ring.visible = false
		holder.add_child(ring)
		holder.set_meta("orb", orb); holder.set_meta("col", col)
		holder.set_meta("base_scale", 1.4 if is_xr else 1.0)
		holder.set_meta("tag", ("Q3 #%d" % pid) if is_xr else ("P%d" % pid))
		holder.set_meta("rtt", 0); holder.set_meta("age", 0)
		var s0: float = 1.4 if is_xr else 1.0
		holder.scale = Vector3(s0, s0, s0)
		remotes[pid] = holder
		_focus_order.append(pid)
	return remotes[pid]

func _combat_fx(p: PackedStringArray) -> void:
	# server sends fx:swing<stage>[:hit<dmg>|:outofrange|:blocked|:death], or fx:whiff / fx:comboDrop
	if bot or spectate: return
	var hit := false
	for i in range(1, p.size()):
		var tok := p[i]
		if tok.begins_with("hit"):
			hud.text = "HIT %s!  beast HP %d/100" % [tok.substr(3), enemy_hp]
			hit = true
		elif tok == "outofrange":
			hud.text = "OUT OF RANGE — walk closer to the beast (WASD)"
		elif tok == "blocked":
			hud.text = "BLOCKED — the beast is warming up, hit again"
		elif tok == "death":
			hud.text = "BEAST DOWN! press E to grab the loot"
		elif tok == "whiff":
			hud.text = "WHIFF — time your taps to the beat"
		elif tok == "comboDrop":
			hud.text = "combo dropped — restart the chain"
	if hit and enemy_node and enemy_node.visible:
		_flash_enemy()

func _flash_enemy() -> void:
	var mi := enemy_node
	var mat := mi.get_active_material(0)
	if mat is StandardMaterial3D:
		var base: Color = (mat as StandardMaterial3D).albedo_color
		var t := create_tween()
		(mat as StandardMaterial3D).albedo_color = Color(1, 1, 1)
		t.tween_property(mat, "albedo_color", base, 0.18)
	var s := mi.scale
	var t2 := create_tween()
	mi.scale = s * 1.18
	t2.tween_property(mi, "scale", s, 0.15)

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
			if spectate: hud.text = "SPECTATING — phase: %s" % phase
			if phase == "field":
				avatar.position = Vector3(randf_range(-3, 3), 0, 2)
				hud.text = "FIELD: SPACE to attack on the beat, E to grab loot"
			elif phase == "hub":
				avatar.position = Vector3(0, 0, 4)
				if bot and OS.get_environment("BOT_NO_TIMEOUT") == "1":
					# continuous: reset and re-vote next round
					bot_voted = false; got_grant = false; got_reject = false; bot_attack_timer = 0.0
					hud.text = "bot %s: new round" % bot_name
				elif bot:
					var verdict := "GRANT" if got_grant else ("REJECT" if got_reject else "NONE")
					print("BOT %s LOOP COMPLETE outcome=%s" % [bot_name, verdict])
					_put("bye:x")
					get_tree().quit(0)
				else:
					loop_done = true
					hud.text = "back in hub — loop complete"
		"enemy":
			if p[1] == "spawned":
				enemy_node.visible = true; enemy_hp = 100
				if not bot and not spectate: hud.text = "FIELD — beast HP 100/100 — walk up (WASD), SPACE on the beat"
			elif p[1] == "hp":
				enemy_hp = int(p[2])
				if not bot and not spectate and enemy_hp > 0:
					hud.text = "FIELD — beast HP %d/100 — keep the combo, E to grab loot" % enemy_hp
				if enemy_hp == 0: enemy_node.visible = false
		"loot":
			loot_node.visible = true
		"grant":
			got_grant = true; loot_node.visible = false
			hud.text = "GRANTED item %s!" % p[1]
		"reject":
			got_reject = true; loot_node.visible = false
		"ping":
			_put("pong:%s" % p[1])
		"left":
			var lpid := int(p[1])
			if remotes.has(lpid):
				remotes[lpid].queue_free()
				remotes.erase(lpid)
				_focus_order.erase(lpid)
		"fx": _combat_fx(p)
		"p":
			if p.size() < 7: return        # tolerate older/short transform packets
			var pid := int(p[1])
			if pid != my_id:
				var kind: String = p[6]
				var h := _remote(pid, kind)
				h.position = Vector3(float(p[2]), 0.0, float(p[4]))
				var yaw := float(p[5])
				h.get_meta("orb").call("update_from_basis", Basis(Vector3.UP, yaw))
				h.set_meta("rtt", (int(p[7]) if p.size() > 7 else 0))
				h.set_meta("age", (int(p[8]) if p.size() > 8 else 0))

func _breathe() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for pid in remotes:
		var h = remotes[pid]
		var rtt: int = h.get_meta("rtt", 0)
		var age: int = h.get_meta("age", 0)
		var base: float = h.get_meta("base_scale", 2.0)
		var live := age < 400                      # heard within 0.4 s
		var rate := 5.0 if live else 1.0           # breathe fast when connected
		var amp := 0.16 if live else 0.05
		var s := base * (1.0 + amp * sin(t * rate))
		h.scale = Vector3(s, s, s)
		# colour: green<60ms, yellow<150, orange<300, red else; grey if stale
		var col: Color
		if age > 1500: col = Color(0.4, 0.4, 0.45)         # disconnected
		elif rtt < 60: col = Color(0.3, 1.0, 0.45)
		elif rtt < 150: col = Color(0.95, 0.9, 0.3)
		elif rtt < 300: col = Color(1.0, 0.6, 0.2)
		else: col = Color(1.0, 0.3, 0.3)
		h.get_meta("orb").call("setup", col)
		var lbl = h.get_node_or_null("Label3D")
		if lbl: lbl.text = "%s  %dms" % [h.get_meta("tag", "P%d" % pid), rtt]

func _physics_process(delta: float) -> void:
	if not peer: return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		last_server_ms = Time.get_ticks_msec()
		handle(peer.get_packet().get_string_from_utf8())
	var now := Time.get_ticks_msec()
	var status := peer.get_connection_status()
	# transport down (or stuck connecting > 4 s): rebuild the client and rejoin
	if status == MultiplayerPeer.CONNECTION_DISCONNECTED or (status != MultiplayerPeer.CONNECTION_CONNECTED and now - t0 > 4000):
		if bot and OS.get_environment("BOT_NO_TIMEOUT") != "1" and now - t0 > 30000:
			printerr("BOT %s TIMEOUT" % bot_name); get_tree().quit(1)
		t0 = now; last_server_ms = now
		peer.close(); peer = _make_client_peer()
		my_id = 0
		return
	if status != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	# connected — join, then watch for a silent server (dropped by liveliness)
	if my_id == 0:
		_put("join:%s:%s" % [bot_name, ("xr" if xr else "flat")])
		my_id = -1; welcome_ms = now; last_server_ms = now
		return
	if my_id < 0:
		if now - welcome_ms > 3000: my_id = 0   # no welcome — resend join
		return
	# a real drop surfaces as transport-down above and reconnects there
	# drain externally-queued packets through the working send path
	if not mcp_queue.is_empty():
		for s in mcp_queue: _put(String(s))
		mcp_queue.clear()
	if spectate:
		_breathe()
		_spectate_focus(delta)
	elif bot: _bot_drive(delta)
	else: _human_drive(delta)
	send_accum += delta
	if send_accum >= 0.1:
		send_accum = 0.0
		var tp: Vector3 = avatar.global_transform.origin
		var yaw: float = avatar.rotation.y
		if xr and xr_origin != null and xr_origin.has_node("XRCamera3D"):
			var cx := xr_origin.get_node("XRCamera3D") as XRCamera3D
			tp = cx.global_transform.origin
			yaw = cx.global_transform.basis.get_euler().y
		_put("tf:%.2f:%.2f:%.2f:%.3f" % [tp.x, tp.y, tp.z, yaw], false, CH_POSITION)
	if Time.get_ticks_msec() - t0 > 120000 and bot and not spectate and not loop_done and OS.get_environment("BOT_NO_TIMEOUT") != "1":
		printerr("BOT %s TIMEOUT phase=%s" % [bot_name, phase]); get_tree().quit(1)

func _spectate_focus(delta: float) -> void:
	# Tab cycles focus; number keys 1-9 jump; Esc returns to the wide overhead.
	if Input.is_key_pressed(KEY_ESCAPE):
		_focus_idx = -1
	if Input.is_action_just_pressed("ui_focus_next"):  # Tab
		if _focus_order.size() > 0:
			_focus_idx = (_focus_idx + 1) % _focus_order.size()
	for n in range(1, 10):
		if Input.is_key_pressed(KEY_0 + n) and n <= _focus_order.size():
			_focus_idx = n - 1
	var wide_pos := Vector3(7.5, 12.5, 9.0)
	var wide_look := Vector3(0.0, 0.5, -2.5)
	var tgt_pos := wide_pos
	var tgt_look := wide_look
	var focused_pid := -1
	if _focus_idx >= 0 and _focus_idx < _focus_order.size():
		focused_pid = _focus_order[_focus_idx]
		if remotes.has(focused_pid):
			var fp: Vector3 = remotes[focused_pid].position
			tgt_look = fp + Vector3(0, 0.9, 0)
			tgt_pos = fp + Vector3(2.6, 4.2, 4.8)   # close 3/4 over the player
	# highlight rings
	for pid in remotes:
		var r = remotes[pid].get_node_or_null("focus_ring")
		if r: r.visible = (pid == focused_pid)
	if _spec_cam:
		_spec_cam.position = _spec_cam.position.lerp(tgt_pos, clamp(delta * 4.0, 0, 1))
		_spec_cam.look_at(tgt_look, Vector3.UP)
		var who := ("wide overhead" if focused_pid < 0 else "focus P%d" % focused_pid)
		hud.text = "SPECTATING — %s   [Tab/1-9 focus, Esc wide]" % who

func _human_drive(delta: float) -> void:
	if xr and left_hand and right_hand and xr_cam:
		# locomotion: left thumbstick, camera-relative (stick up -> gaze forward)
		var stick: Vector2 = left_hand.get_vector2("primary")
		var move: Vector3 = xr_cam.global_transform.basis * Vector3(stick.x, 0.0, -stick.y)
		move.y = 0.0
		if move.length() > 0.15:
			avatar.position += move.normalized() * 3.0 * delta
		# actions, edge-detected by polling (robust vs signal wiring):
		# right trigger -> attack, right A -> grab, left Y/B -> teleport vote.
		var trig := right_hand.is_button_pressed("trigger_click")
		var ax := right_hand.is_button_pressed("ax_button")
		var by := left_hand.is_button_pressed("by_button")
		if trig and not _xr_prev["trigger"]: _put("attack:x")
		if ax and not _xr_prev["ax"]: _put("grab:x")
		if by and not _xr_prev["by"]: _put("teleport:x")
		_xr_prev["trigger"] = trig; _xr_prev["ax"] = ax; _xr_prev["by"] = by
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1
	if Input.is_key_pressed(KEY_S): dir.z += 1
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	avatar.velocity = dir.normalized() * 4.0
	avatar.move_and_slide()
	if Input.is_key_pressed(KEY_T): _put("teleport:x")
	if Input.is_action_just_pressed("ui_accept"): _put("attack:x")
	if Input.is_key_pressed(KEY_E): _put("grab:x")

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
				_put("teleport:x")
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
				_put("attack:x")
				_put("grab:x") # grabs only land once loot spawns
