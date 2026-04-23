#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/dist/OpenClaw Deployer.app"

"$ROOT/Scripts/build_app.sh"
open "$APP_DIR"
