#!/usr/bin/env bash
# Launch the whole loop fleet with a clean, conflict-free MCP port map so EVERY
# godot executable is individually testable over its own runtime MCP.
#
# Port map (all 127.0.0.1):
#   8788  Quest 3 on-device MCP (the headset's own runtime MCP)   [device]
#   8790  adb forward host:8790 -> Quest:8788                      [reserved by quest-mcp-forward.service]
#   8794  loop-server      (authoritative server; state via Engine.get_main_loop())
#   8791  loop-bot2
#   8792  loop-bot3
#   8793  loop-bot4
#   8789  loop-human       (windowed flat player)
#   8795  loop-observer    (windowed overhead spectator)
#   8796+ spare (extra humans / a Quest-local desktop mirror)
#
# Usage: tools/loop_fleet.sh [up|down|ports]
# (no `set -e`: systemctl is-active/stop return non-zero for stopped units, which
#  is normal here and must not abort the launcher.)
GB=/home/ernest.lee/Documents/godot/bin/godot.linuxbsd.editor.double.x86_64
PROJ=/home/ernest.lee/Documents/loop_game
# Transport passthrough: `TRANSPORT=wt bash tools/loop_fleet.sh up` for WebTransport,
# otherwise ENet (the default the server/client pick when TRANSPORT is unset).
TRANSPORT="${TRANSPORT:-enet}"
TENV="--setenv=TRANSPORT=$TRANSPORT"

SERVER_PORT=8794
HUMAN_PORT=8789
OBSERVER_PORT=8795
declare -A BOT_PORT=( [bot2]=8791 [bot3]=8792 [bot4]=8793 )

units=(loop-server loop-bot2 loop-bot3 loop-bot4 loop-human loop-observer)

down() {
  for u in "${units[@]}"; do systemctl --user stop "$u.service" 2>/dev/null || true; done
}

ports() {
  echo "server    -> $SERVER_PORT   (run_script: use Engine.get_main_loop().phase / .players)"
  echo "bot2/3/4  -> ${BOT_PORT[bot2]} ${BOT_PORT[bot3]} ${BOT_PORT[bot4]}"
  echo "human     -> $HUMAN_PORT"
  echo "observer  -> $OBSERVER_PORT"
  echo "quest     -> 8790 (adb fwd -> device 8788)"
}

up() {
  down; sleep 2
  # --path sets the project so res:// resolves (for the runtime MCP autoload);
  # --script runs server.gd as the MainLoop.
  systemd-run --user --unit=loop-server --setenv=MCP_PORT=$SERVER_PORT $TENV \
    "$GB" --headless --xr-mode off --path "$PROJ" --script "$PROJ/server.gd" >/dev/null 2>&1
  sleep 4
  for b in bot2 bot3 bot4; do
    systemd-run --user --unit=loop-$b --setenv=BOT=1 --setenv=BOT_NAME=$b --setenv=BOT_NO_TIMEOUT=1 \
      --setenv=MCP_PORT=${BOT_PORT[$b]} $TENV "$GB" --headless --xr-mode off --path "$PROJ" >/dev/null 2>&1
  done
  sleep 3
  systemd-run --user --unit=loop-human --setenv=XR=0 --setenv=MCP_PORT=$HUMAN_PORT $TENV \
    "$GB" --xr-mode off --path "$PROJ" >/dev/null 2>&1
  sleep 3
  systemd-run --user --unit=loop-observer --setenv=SPECTATE=1 --setenv=XR=0 --setenv=MCP_PORT=$OBSERVER_PORT $TENV \
    "$GB" --xr-mode off --path "$PROJ" >/dev/null 2>&1
  sleep 6
  echo "fleet up:"; for u in "${units[@]}"; do printf "  %-14s %s\n" "$u" "$(systemctl --user is-active "$u.service")"; done
  echo; ports
}

case "${1:-up}" in
  up) up ;;
  down) down; echo "fleet down" ;;
  ports) ports ;;
  *) echo "usage: $0 [up|down|ports]"; exit 1 ;;
esac
