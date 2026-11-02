#!/bin/zsh
set -euo pipefail

task_dir=${0:A:h}
task_build_dir=${BETTER_NEEWER_BUILD_DIR:-$task_dir/build}
app_path="$task_build_dir/Better Neewer.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$task_build_dir/slices"
task_sdk=$(xcrun --sdk macosx --show-sdk-path)
task_archs=(${=BETTER_NEEWER_ARCHS:-arm64 x86_64})
task_binaries=()
for task_arch in $task_archs; do
  case "$task_arch" in arm64|x86_64) ;; *) print -u2 -- "Unsupported architecture: $task_arch"; exit 1 ;; esac
  task_binary="$task_build_dir/slices/BetterNeewer-$task_arch"
  xcrun swiftc -O -swift-version 6 -sdk "$task_sdk" -target "$task_arch-apple-macosx14.0" \
    -framework AppKit -framework SwiftUI -framework Combine -framework CoreBluetooth \
    "$task_dir"/Sources/*.swift -o "$task_binary"
  task_binaries+=("$task_binary")
done
lipo -create $task_binaries -output "$app_path/Contents/MacOS/BetterNeewer"
cp "$task_dir/Info.plist" "$app_path/Contents/Info.plist"
if [[ -f "$task_dir/../LICENSE" ]]; then cp "$task_dir/../LICENSE" "$app_path/Contents/Resources/LICENSE"; fi
task_sign_identity=${BETTER_NEEWER_SIGN_IDENTITY:--}
if [[ "$task_sign_identity" == "-" ]]; then
  codesign --force --sign - "$app_path"
else
  codesign --force --options runtime --timestamp --sign "$task_sign_identity" "$app_path"
fi
codesign --verify --strict "$app_path"
lipo -archs "$app_path/Contents/MacOS/BetterNeewer"
print -r -- "$app_path"
