# tools

Operator helpers for the on-device play loop (the durable copy; the live ones
run from `run/`, which is gitignored).

- `quest_screen_state.sh` — DISPLAYING / SCREEN_OFF / ON_NOT_RENDERING from the
  VrApi frame heartbeat + display power (per the screen-off detection decision).
- `adb.sh` — logged adb wrapper.
- `play_via_mcp.sh [x z]` — read the on-device client state, optionally move it
  (over the runtime MCP, `adb forward 8790 -> 8788`).
