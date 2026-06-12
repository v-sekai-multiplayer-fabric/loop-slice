#!/usr/bin/env bash
# Sync the vendored MCP addon into addons/ after a subtree pull.
cd "$(dirname "$0")/.."
rm -rf addons/vsekai_godot_mcp
cp -r thirdparty/vsekai-godot-mcp/addons/vsekai_godot_mcp addons/
echo "synced addons/vsekai_godot_mcp from the subtree"
