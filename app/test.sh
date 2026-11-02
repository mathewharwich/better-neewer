#!/bin/zsh
set -euo pipefail
task_dir=${0:A:h}
mkdir -p "$task_dir/build"
swiftc -O -swift-version 6 "$task_dir/Sources/LightModels.swift" \
  "$task_dir/Sources/EffectCatalog.swift" "$task_dir/Sources/NeewerProtocol.swift" \
  "$task_dir/Tests/NeewerProtocolTests.swift" -o "$task_dir/build/NeewerProtocolTests"
"$task_dir/build/NeewerProtocolTests"
swiftc -O -swift-version 6 "$task_dir/Sources/LightModels.swift" \
  "$task_dir/Sources/EffectCatalog.swift" "$task_dir/Sources/NeewerProtocol.swift" \
  "$task_dir/Sources/StudioController.swift" "$task_dir/Tests/ProfilePersistenceTests.swift" \
  -o "$task_dir/build/ProfilePersistenceTests"
"$task_dir/build/ProfilePersistenceTests"
