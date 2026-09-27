#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_path="$PWD/dist/MornRunner.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    binaries=()
    for architecture in arm64 x86_64; do
        swift build -c release --arch "$architecture"
        binary_dir=$(swift build -c release --arch "$architecture" --show-bin-path)
        binaries+=("$binary_dir/MornRunner")
    done
    lipo -create "${binaries[@]}" -output "$app_path/Contents/MacOS/MornRunner"
else
    swift build -c release
    binary_dir=$(swift build -c release --show-bin-path)
    cp "$binary_dir/MornRunner" "$app_path/Contents/MacOS/MornRunner"
fi
cp Support/Info.plist "$app_path/Contents/Info.plist"
"${SWIFT_EXEC:-$(xcrun --find swiftc)}" -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" Support/MakeIcon.swift -o .build/make-icon
.build/make-icon "$PWD/dist"
iconutil -c icns dist/AppIcon.iconset -o "$app_path/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
    [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid VERSION'; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$app_path/Contents/Info.plist"
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime --identifier studio.tsukumi.MornRunner "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/MornRunner.app.zip
print "Built: $app_path"
