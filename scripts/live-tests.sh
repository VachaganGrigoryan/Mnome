#!/bin/bash
# Automatic tests against the real macOS: ./scripts/live-tests.sh [1] [2] [apps] [3]   (all of them by default)
#   1 = phase 1, what macOS allows (also changes a few settings and the pointer, and puts them back)
#   2 = phases 2 and 4, the window engine   apps = the engine on TextEdit, Terminal and VS Code
#   3 = phases 3 and 4 in the running Mnome: keys, snapping, workspaces, Alt+Tab (every window is minimized, then parked, for a moment)
#   displays = only on request: adds a virtual display beside the main one, then removes it
#   drag = only on request: edge tiling with the real mouse (moves the pointer and helper windows)
# Takes about 6 minutes. Hands off the keyboard and mouse until it ends.
set -uo pipefail
cd "$(dirname "$0")/.."
tests=("$@"); [ ${#tests[@]} -eq 0 ] && tests=(1 2 apps 3)
app="$PWD/build/Mnome.app"; failed=()
for t in "${tests[@]}"; do case $t in 1|2|apps|3|displays|drag) ;; *) echo "Unknown test: $t"; exit 2;; esac; done
wants() { [[ " ${tests[*]} " == *" $1 "* ]]; }
running() { pgrep -f "^$app/Contents/MacOS/Mnome$" >/dev/null; }
quit() { "$work/Mnome" --quit; } # never a signal: that would restore nothing
start() { running || open "$app"; for _ in $(seq 50); do running && { sleep 3; return 0; }; sleep 0.1; done; return 1; }

cargo build --manifest-path core/Cargo.toml --release --offline --quiet && swift build -Xlinker -L -Xlinker "$PWD/core/target/release" | tail -1 || exit 1
wants 3 && [ ! -d "$app" ] && { echo "Run scripts/build.sh first: test 3 needs the app."; exit 2; }
caffeinate -di -w $$ & # a locked screen hides every window
work=$(mktemp -d); cp -R .build/debug/Mnome .build/debug/*.bundle "$work/" # a build meanwhile changes nothing
was=no; running && was=yes
finish() { "$work/Mnome" --system-check rescue >/dev/null || echo "Some settings could not be put back: run .build/debug/Mnome --system-check rescue"; if [ $was = yes ]; then start; elif running; then quit; fi; rm -rf "$work"; }
trap finish EXIT; trap 'exit 130' INT TERM
run() { echo; echo "=== $1"; shift; "$work/Mnome" "$@" || failed+=("$*"); }

if wants 1 || wants 2 || wants apps || wants drag; then running && { quit || exit 1; }; fi # it would act on the same keys and windows
wants 1 && run "Phase 1: macOS" --system-check settings
wants 2 && run "Phase 2: window engine" --engine-check
wants apps && run "Phase 2: real apps" --engine-check apps
wants drag && run "Phase 8: edge tiling by drag" --engine-check drag
wants displays && run "Phase 4: a display that comes and goes" --engine-check displays
if wants 3; then start && run "Phase 3: keys and snapping" --key-check desktop workspaces || failed+=("Mnome did not start"); fi
echo; if [ ${#failed[@]} -eq 0 ]; then echo "ALL PASSED"; else printf 'FAILED: %s\n' "${failed[@]}"; exit 1; fi
