#!/bin/bash
# Build-only packaging: never installs, registers or executes MAS.
set -euo pipefail
[[ $# -eq 2 ]] || exit 64
app="$1"
configuration="$2"
cd "$(dirname "$0")"
shared="$PWD/../PrivilegedMAS/Shared"
service="$PWD/../PrivilegedMAS/Service"
identity=E898826915F0BFAD30789097118EDBBF619BC07E
if [[ "$configuration" != Debug ]]; then
    echo 'MAS privileged adapter omitted: Release signing is not configured.' >&2
    exit 0
fi
artifact="${MACSEED_MAS_ARTIFACT_DIR:-/private/tmp/macseed-mas-swift64-artifact}"
notices="${MACSEED_MAS_NOTICES_DIR:-$PWD/../PrivilegedMAS/Vendor}"
if [[ ! -f "$artifact/mas" || ! -d "$notices/ThirdPartyLicenses" ]] || ! security find-identity -v -p codesigning | grep -F "$identity" >/dev/null; then
    echo 'Building ordinary Debug without privileged MAS: qualified artifact/notices/signing identity unavailable.' >&2
    # Never leave a previous privileged payload in a newly unsigned build.
    rm -f "$app/Contents/Helpers/MASHelper" "$app/Contents/Helpers/MASClient" "$app/Contents/Helpers/mas"
    rm -f "$app/Contents/Library/LaunchDaemons/org.macseed.desktop.mas-helper.plist"
    exit 0
fi
python3 - "$artifact" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
assert m['source_commit']=='7c70ffdfd9f71a654300a78b3b627782e6abe1b4'
assert m['signed_mas_sha256']==hashlib.sha256((p/'mas').read_bytes()).hexdigest()=='d10cc734ca3e3af8b403a5b30215dbb6b8b179632451e9bb381376061a0808bf'
assert m['patch_sha256']==hashlib.sha256((p/'swift64.patch').read_bytes()).hexdigest()=='f7c6b6ad069f67992cefdf6fc1925167091b4c4ae3578ee7ac58de7dbedf04fd'
PY
mkdir -p "$app/Contents/Helpers" "$app/Contents/Library/LaunchDaemons" "$app/Contents/Resources/MASProvenance" "$app/Contents/Resources/ThirdPartyLicenses"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
options=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library -module-cache-path "$app/../mas-module-cache")
xcrun swiftc "${options[@]}" "$shared/MASServiceProtocol.swift" "$service/Contract.swift" "$shared/Trust.swift" "$shared/Journal.swift" "$shared/OperationLifetime.swift" "$shared/MASInventory.swift" "$shared/Recovery.swift" "$service/RecoveryCoordinator.swift" "$service/Store.swift" "$service/Helper.swift" -o "$app/Contents/Helpers/MASHelper"
xcrun swiftc "${options[@]}" "$shared/MASServiceProtocol.swift" "$service/Contract.swift" "$service/Client.swift" -o "$app/Contents/Helpers/MASClient"
cp -f "$artifact/mas" "$app/Contents/Helpers/mas"
chmod 555 "$app/Contents/Helpers/mas"
for name in manifest.json swift64.patch REPRODUCE.md; do cp "$artifact/$name" "$app/Contents/Resources/MASProvenance/$name"; done
ditto "$notices/ThirdPartyLicenses" "$app/Contents/Resources/ThirdPartyLicenses"
cat > "$app/Contents/Library/LaunchDaemons/org.macseed.desktop.mas-helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.macseed.desktop.mas-helper</string>
<key>BundleProgram</key><string>Contents/Helpers/MASHelper</string>
<key>MachServices</key><dict><key>org.macseed.desktop.mas-helper</key><true/></dict>
</dict></plist>
PLIST
codesign --verify --strict -R '=anchor apple generic and identifier "org.macseed.development.bundled-mas" and certificate leaf = H"E898826915F0BFAD30789097118EDBBF619BC07E"' "$app/Contents/Helpers/mas"
codesign --force --sign "$identity" --options runtime --timestamp=none --identifier org.macseed.desktop.mas-helper "$app/Contents/Helpers/MASHelper"
codesign --force --sign "$identity" --options runtime --timestamp=none --identifier org.macseed.desktop.mas-client "$app/Contents/Helpers/MASClient"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
