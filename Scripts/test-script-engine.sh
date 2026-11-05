#!/usr/bin/env bash
# Build and run the ScriptEngine tests against a fake phone. Needs only swiftc.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/script-engine-tests"
xcrun --sdk macosx swiftc -swift-version 5 -o "$OUT" \
    iCTRLKit/RPCTypes.swift iCTRLKit/ScriptModel.swift iCTRLKit/ScriptEngine.swift \
    Tests/ScriptEngine/main.swift
"$OUT"
