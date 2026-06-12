# loop-slice

The playable vertical slice of the instanced loot-action core loop: a Hub deck
with a teleporter, a Field room with one enemy, the three-button melee combo,
first-touch loot contention, and the sqlite profile commit — server-authoritative
over WebTransport/QUIC (`feat/module-http3`, multi-session per
[godot#56](https://github.com/v-sekai-multiplayer-fabric/godot/pull/56)).

The reducers transcribe the proven Lean cores
([loot](https://github.com/v-sekai-multiplayer-fabric/loot),
[combat](https://github.com/v-sekai-multiplayer-fabric/combat),
[progression](https://github.com/v-sekai-multiplayer-fabric/progression)), whose
wire parities pin the behavior.

## Play (flatscreen)

```sh
GODOT=godot.linuxbsd.editor.double.x86_64   # the merged double build
$GODOT --headless --script server.gd &      # the authority
$GODOT --path .                              # a windowed client
# WASD move, T vote teleport (4 votes start the run), SPACE attack on the beat,
# E grab the drop. Four clients run the full loop.
```

## The bot smoke

```sh
GODOT=... ./smoke.sh
# -> PLAYABLE LOOP SMOKE PASS: full slice ran end to end with exactly one grant
```

One server + four bots run hub -> vote -> fade -> field combat (timed combos
through the invulnerability window) -> loot contention (exactly one grant) ->
return + sqlite commit.

## XR mode

`XR=1` (or the Quest build) runs the same client through OpenXR: an XROrigin
with head camera and both controllers — left stick locomotion, right trigger
attack, A grab, left Y teleport vote. Verified headless against Monado: an
XR-session bot ran the full loop alongside three flatscreen bots.

## Quest 3

`export_presets.cfg` exports `build/loop-slice.apk` (arm64 double template,
debug-signed, OpenXR). The client reads the server host from `LOOP_HOST`, then
`res://server_host.txt` (baked at export), then loopback.
