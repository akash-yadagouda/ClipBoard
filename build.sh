#!/bin/bash
# Compiles the utility to build/clipboard-manager.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -O Sources/Core/*.swift Sources/App/*.swift -o build/clipboard-manager
echo "Built build/clipboard-manager"
