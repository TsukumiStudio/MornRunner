#!/bin/bash
# Optional workaround for CLT installations with stale private PackageDescription interfaces.
# The system toolchain is never modified. Usage: bash Support/with-local-toolchain.sh swift test
set -euo pipefail
cd "$(dirname "$0")/.."
toolchain_dir="$(dirname "$(xcrun --find swift)")/../lib/swift/pm/ManifestAPI"
local_libs="$PWD/.build/local-swiftpm"
mkdir -p "$local_libs"
ditto "$toolchain_dir" "$local_libs/ManifestAPI"
while IFS= read -r -d '' private_interface; do
    public_interface="${private_interface/.private.swiftinterface/.swiftinterface}"
    if [ -f "$public_interface" ]; then cp "$public_interface" "$private_interface"; fi
done < <(find "$local_libs/ManifestAPI" -name '*.private.swiftinterface' -print0)
export SWIFTPM_CUSTOM_LIBS_DIR="$local_libs"
# Old CLT updates can also leave two definitions of SwiftBridging.
include_dir="$(dirname "$(xcrun --find swift)")/../include/swift"
if [ -f "$include_dir/module.modulemap" ] && [ -f "$include_dir/bridging.modulemap" ]; then
    printf '// Hidden stale module map in this build only.\n' > "$local_libs/empty.modulemap"
    python3 - "$include_dir/module.modulemap" "$local_libs" <<'PY'
import json, pathlib, sys
original = str(pathlib.Path(sys.argv[1]).resolve())
root = pathlib.Path(sys.argv[2])
(root / 'overlay.json').write_text(json.dumps({'version': 0, 'case-sensitive': False, 'roots': [
    {'type': 'file', 'name': original, 'external-contents': str(root / 'empty.modulemap')}
]}))
PY
    export MORN_REAL_SWIFTC="$(xcrun --find swiftc)"
    export MORN_SWIFT_OVERLAY="$local_libs/overlay.json"
    export MORN_DEVELOPER_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
    cat > "$local_libs/swiftc" <<'SH'
#!/bin/bash
exec "$MORN_REAL_SWIFTC" -F "$MORN_DEVELOPER_FRAMEWORKS" -vfsoverlay "$MORN_SWIFT_OVERLAY" -Xcc -ivfsoverlay -Xcc "$MORN_SWIFT_OVERLAY" "$@"
SH
    chmod +x "$local_libs/swiftc"
    export SWIFT_EXEC="$local_libs/swiftc"
fi
if [ "${1:-}" = swift ] && [ "${2:-}" = test ]; then
    set -- "$@" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/Frameworks"
fi
exec "$@"
