#!/bin/bash
# Compiles and runs the tests. They use private pasteboards and a temporary
# database, so the real clipboard and history are never touched.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc Sources/Core/*.swift Tests/*.swift -o build/clipboard-manager-tests
./build/clipboard-manager-tests
