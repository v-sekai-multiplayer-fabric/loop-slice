extends Node
## Runtime MCP bridge — the SAME MCP server as the editor plugin (mcp_bridge.gd),
## but running INSIDE the deployed game (e.g. on the Quest 3) over its live
## SceneTree instead of the editor. Reach it over `adb forward`. Editor-only
## commands return an error; scene/node/eval/screenshot/performance work on the
## running game.
const MCPCommandsLib = preload("mcp_commands.gd")
const MCPHttpServerLib = preload("mcp_http_server.gd")

const HOST := "127.0.0.1"   # adb forward reaches the device loopback
var HTTP_PORT := int(OS.get_environment("MCP_PORT")) if OS.get_environment("MCP_PORT") != "" else 8788

var _cmds = MCPCommandsLib.new()
var _http = MCPHttpServerLib.new()

func _ready() -> void:
	_http.protocol.commands = _cmds
	if _http.start(HTTP_PORT, HOST) == OK:
		print("[godot_mcp] RUNTIME MCP on http://%s:%d/mcp" % [HOST, HTTP_PORT])
	else:
		push_error("[godot_mcp] runtime HTTP listen failed on :%d" % HTTP_PORT)
	set_process(true)

func _process(_delta: float) -> void:
	_cmds.editor = null
	_cmds.root = get_tree().current_scene if get_tree().current_scene else get_tree().root
	_http.poll()

func _exit_tree() -> void:
	_http.stop()
