#!/usr/bin/env bash
# Build and run the location simulator tests against a fake phone. Needs only swiftc.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/location-sim-tests"
xcrun --sdk macosx swiftc -swift-version 5 -o "$OUT" \
    iCTRLApp/Location/LocationCore.swift \
    Tests/LocationSim/main.swift
"$OUT"
