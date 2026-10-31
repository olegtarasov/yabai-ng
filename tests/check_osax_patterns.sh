#!/bin/sh
# Static local Dock signature check; returns 77 outside macOS 27.
set -eu
cd "$(dirname "$0")/.."
mkdir -p tests/bin
clang tests/integration/osax_patterns.m -framework Foundation -o tests/bin/osax_patterns
tests/bin/osax_patterns "$@"
