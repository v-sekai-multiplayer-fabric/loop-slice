extends SceneTree
# The authoritative loop server: Hub -> fade -> Field (combat + loot) -> return.
# Runs the proven reducers (combat step, loot first-touch, progression commit)
# behind one WebTransportPeer listener; clients are humans or bots.
const PORT = 54400
const TICK_HZ = 30.0
const PLAYERS_NEEDED = int(4)
# Authority capacity TARGET: one single-threaded server must support at least this
# many authoritative players (and more if the transport allows — no hard cap). This
# is NOT the QUIC connection limit: authority and interest are split, and interest
# fans out to many more peers than there are players, so the transport connection
# table is sized far above this (see WT_SERVER_MAX_CONNECTIONS in the http3 module).
const PLAYER_CAPACITY_TARGET = int(150)
# combat tuning (CombatCore values)
const MIN_GAP = 6; const MAX_GAP = 18; const INVULN = 30; const MAX_HP = 100
const MELEE_RANGE = 2.5

var peer: MultiplayerPeer
var phase := "hub"
var players := {}        # peer_id -> {name, pos: Vector3, ready, kit, items}
var tick := 0; var tick_accum := 0.0
var combo := {}          # peer_id -> {stage, last_attack}
var enemy := {"alive": false, "hp": 0, "spawn_tick": 0, "pos": Vector3(0, 0, -4)}
var loot_box := {"present": false, "claims": []}
var loot_seed := 12345
var db_path := OS.get_environment("LOOP_DB") if OS.get_environment("LOOP_DB") != "" else "/tmp/loop_profiles.db"

static func _fmt(t: int) -> String:
	var d = Time.get_datetime_dict_from_unix_time(t)
	return "%04d%02d%02d%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]

# Transport is switchable: ENet for the local slice (stable today), WebTransport
# for the Quest-web path (TRANSPORT=wt) once the picoquic wedge is fixed. The text
# protocol is transport-agnostic, so only peer creation differs.
func _transport() -> String:
	return "wt" if OS.get_environment("TRANSPORT") == "wt" else "enet"

func _make_server_peer() -> MultiplayerPeer:
	if _transport() == "wt":
		var crypto = Crypto.new()
		var key = crypto.generate_ecdsa()
		var now = int(Time.get_unix_time_from_system())
		var cert = crypto.generate_self_signed_certificate_san(key, "CN=loop-zone",
			_fmt(now), _fmt(now + 86400), PackedStringArray(["DNS:localhost", "IP:127.0.0.1"]))
		var w := WebTransportPeer.new()
		return w if w.create_server(PORT, "/wt", cert, key) == OK else null
	var e := ENetMultiplayerPeer.new()
	return e if e.create_server(PORT, PLAYER_CAPACITY_TARGET) == OK else null

func _init():
	peer = _make_server_peer()
	if not peer:
		printerr("listen failed"); quit(1); return
	print("LOOPSRV ready on %d (transport=%s)" % [PORT, _transport()])
	# Attach the runtime MCP so the headless server is testable like the clients.
	# The server is the SceneTree itself, so inspect its state in run_script via
	# `Engine.get_main_loop()` (e.g. Engine.get_main_loop().phase / .players).
	if OS.get_environment("MCP_PORT") != "":
		var mcp_script = load("res://addons/vsekai_godot_mcp/mcp_runtime.gd")
		if mcp_script:
			root.call_deferred("add_child", mcp_script.new())

# Control messages go reliable; high-frequency position ("p:") goes unreliable.
# This matters most on WebTransport, where each RELIABLE packet opens a fresh bidi
# stream — streaming positions reliably exhausts the QUIC concurrent-stream limit
# in seconds and silently wedges all sends. Datagrams (unreliable) have no such cap.
const CH_CONTROL := 0   # reliable, ordered: welcome/roster/votes/fade/phase/loot/grant
const CH_POSITION := 1  # unreliable: high-frequency "p:" position replication
func send_to(pid: int, msg: String, reliable := true, channel := CH_CONTROL) -> void:
	peer.set_target_peer(pid)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(msg.to_utf8_buffer())

func broadcast(msg: String, reliable := true, channel := CH_CONTROL) -> void:
	for pid in players: send_to(pid, msg, reliable, channel)

func roll_item() -> int:
	# the proven loot roll (xorshift32 over cumw 50/80/100 -> items 101/202/303)
	var s := loot_seed & 0xFFFFFFFF
	s = (s ^ ((s << 13) & 0xFFFFFFFF)); s = (s ^ (s >> 17)); s = (s ^ ((s << 5) & 0xFFFFFFFF))
	var r := s % 100
	return 101 if r < 50 else (202 if r < 80 else 303)

func handle(pid: int, parts: PackedStringArray) -> void:
	match parts[0]:
		"join":
			players[pid] = {"name": parts[1], "kind": (parts[2] if parts.size() > 2 else "flat"),
				"pos": Vector3(randf_range(-2, 2), 0, randf_range(2, 4)), "yaw": 0.0,
				"ready": false, "kit": false, "items": [], "rtt": 0, "last_heard": Time.get_ticks_msec()}
			combo[pid] = {"stage": 0, "last_attack": 0}
			send_to(pid, "welcome:%d" % pid)
			# the starting kit (the shop's free-kit pressure valve)
			players[pid]["kit"] = true
			send_to(pid, "kit:monomate")
			print("JOIN peer=%d name=%s roster=%d" % [pid, parts[1], players.size()])
			broadcast("roster:%d" % players.size())
		"tf":
			if players.has(pid) and parts.size() >= 5:
				players[pid]["pos"] = Vector3(float(parts[1]), float(parts[2]), float(parts[3]))
				players[pid]["yaw"] = float(parts[4])
		"teleport":
			if players.has(pid) and phase == "hub":
				players[pid]["ready"] = true
				var n := 0
				for p in players: if players[p]["ready"]: n += 1
				print("VOTE peer=%d votes=%d/%d" % [pid, n, PLAYERS_NEEDED])
				broadcast("votes:%d/%d" % [n, PLAYERS_NEEDED])
				if n >= PLAYERS_NEEDED:
					phase = "fade_out"
					broadcast("fade:out")
		"attack":
			if phase != "field" or not players.has(pid): return
			var dist: float = players[pid]["pos"].distance_to(enemy["pos"])
			var c = combo[pid]
			var fx := []
			if c["stage"] == 0:
				c["stage"] = 1; c["last_attack"] = tick
				fx = resolve_swing(pid, 0, dist)
			else:
				var gap = tick - c["last_attack"]
				if gap >= MIN_GAP and gap <= MAX_GAP:
					var st = c["stage"]
					c["stage"] = 0 if st >= 2 else st + 1
					c["last_attack"] = tick
					fx = resolve_swing(pid, st, dist)
				else:
					c["stage"] = 0; fx = ["whiff"]
			send_to(pid, "fx:" + ":".join(fx))
		"grab":
			if phase == "field" and loot_box["present"]:
				loot_box["claims"].append([pid, tick])
		"pong":
			if players.has(pid) and parts.size() >= 2:
				players[pid]["rtt"] = Time.get_ticks_msec() - int(parts[1])
		"bye":
			players.erase(pid)

func resolve_swing(pid: int, stage: int, dist: float) -> Array:
	var fx := ["swing%d" % stage]
	if not enemy["alive"]: return fx
	if dist > MELEE_RANGE: fx.append("outofrange"); return fx
	if tick < enemy["spawn_tick"] + INVULN: fx.append("blocked"); return fx
	var dmg = [10, 15, 25][stage]
	enemy["hp"] = max(0, enemy["hp"] - dmg)
	fx.append("hit%d" % dmg)
	broadcast("enemy:hp:%d" % enemy["hp"])
	if enemy["hp"] == 0:
		enemy["alive"] = false
		fx.append("death")
		loot_box["present"] = true
		loot_box["claims"] = []
		broadcast("loot:spawned")
	return fx

func commit_profiles() -> void:
	var db = SQLite.new()
	if not db.open(db_path): printerr("db open failed"); return
	db.create_query("CREATE TABLE IF NOT EXISTS profiles(pid INT, name TEXT, item INT)").execute()
	db.create_query("DELETE FROM profiles").execute()
	for pid in players:
		for it in players[pid]["items"]:
			db.create_query("INSERT INTO profiles VALUES (?, ?, ?)").execute([pid, players[pid]["name"], it])
	db.close()

func _process(delta: float) -> bool:
	if not peer: return false
	peer.poll()
	while peer.get_available_packet_count() > 0:
		# get_packet_peer() peeks the sender of the NEXT packet (the MultiplayerPeer
		# contract), so read it BEFORE get_packet() pops. (WebTransportPeer cached it
		# after the pop; ENet follows the contract, so order matters.)
		var from = peer.get_packet_peer()
		var pkt = peer.get_packet().get_string_from_utf8()
		if players.has(from): players[from]["last_heard"] = Time.get_ticks_msec()
		handle(from, pkt.split(":"))
	tick_accum += delta
	while tick_accum >= 1.0 / TICK_HZ:
		tick_accum -= 1.0 / TICK_HZ
		step_tick()
	return false

var fade_ticks := 0
func step_tick() -> void:
	tick += 1
	# combo windows expire
	for pid in combo:
		var c = combo[pid]
		if c["stage"] > 0 and tick > c["last_attack"] + MAX_GAP:
			c["stage"] = 0
			send_to(pid, "fx:comboDrop")
	match phase:
		"fade_out":
			fade_ticks += 1
			if fade_ticks >= 30:
				phase = "field"; fade_ticks = 0
				enemy = {"alive": true, "hp": MAX_HP, "spawn_tick": tick, "pos": Vector3(0, 0, -4)}
				for pid in players: players[pid]["pos"] = Vector3(randf_range(-3, 3), 0, 2)
				broadcast("phase:field")
				broadcast("enemy:spawned:%d" % MAX_HP)
		"field":
			if loot_box["present"] and loot_box["claims"].size() > 0:
				# first-touch: earliest tick, ties to lowest pid (LootCore.resolve)
				var best = loot_box["claims"][0]
				for cl in loot_box["claims"]:
					if cl[1] < best[1] or (cl[1] == best[1] and cl[0] < best[0]): best = cl
				var item := roll_item()
				players[best[0]]["items"].append(item)
				loot_box["present"] = false
				for pid in players:
					send_to(pid, ("grant:%d" % item) if pid == best[0] else "reject:loot")
				print("LOOT granted item %d to peer %d" % [item, best[0]])
				phase = "fade_in"; broadcast("fade:out")
		"fade_in":
			fade_ticks += 1
			if fade_ticks >= 30:
				phase = "hub"; fade_ticks = 0
				commit_profiles()
				print("LOOP COMPLETE: party returned, profiles committed")
				# reset for a fresh round (continuous demo)
				for pid in players: players[pid]["ready"] = false
				for pid in combo: combo[pid] = {"stage": 0, "last_attack": 0}
				enemy = {"alive": false, "hp": 0, "spawn_tick": 0, "pos": Vector3(0, 0, -4)}
				loot_box = {"present": false, "claims": []}
				loot_seed += 7
				broadcast("phase:hub")
	# replicate positions + enemy at 10 Hz
	if tick % 3 == 0 and (phase == "field" or phase == "hub"):
		for pid in players:
			var pp = players[pid]["pos"]
			var yw = players[pid].get("yaw", 0.0)
			var kd = players[pid].get("kind", "flat")
			var rt = players[pid].get("rtt", 0)
			var age = Time.get_ticks_msec() - players[pid].get("last_heard", 0)
			broadcast("p:%d:%.2f:%.2f:%.2f:%.3f:%s:%d:%d" % [pid, pp.x, pp.y, pp.z, yw, kd, rt, age], false, CH_POSITION)
	if tick % 15 == 0:
		for pid in players: send_to(pid, "ping:%d" % Time.get_ticks_msec())
	# no liveliness drop enforced here yet; the connection-FSM (liveliness window +
	# 5s rejoin) is the proven spec to wire in so dead sessions leave the roster
