#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/runner"
BUILD="$ROOT/build"
LOGS="$BUILD/logs"
TOOLS="$BUILD/tools"
EXPORT="$BUILD/ios"
GODOT="$TOOLS/Godot.app/Contents/MacOS/Godot"
VERSION=4.6
TAG="$VERSION-stable"
PLUGIN_DIR="$PROJECT/ios/plugins/FilePicker"
PLUGIN_SRC="$ROOT/native/file_picker"
PLUGIN_HEADERS="$TOOLS/godot-ios-headers-$TAG"
RELEASE="https://github.com/godotengine/godot-builds/releases/download/$TAG"
mkdir -p "$LOGS"

# Preserve the original status even when tee succeeds. Every stage gets a full log.
run_log() {
    local file="$1" status
    shift
    set +e
    "$@" 2>&1 | tee "$LOGS/$file"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}
errors() {
    python3 - "$1" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print('No command log was created:', p)
    sys.exit(0)
lines = p.read_text(errors='replace').splitlines()
pattern = re.compile(r'Undefined symbols|duplicate symbol|library not found|framework not found|\bld:|error:|SCRIPT ERROR|Parse Error|ERROR:', re.I)
selected = set()
for i, line in enumerate(lines):
    if pattern.search(line):
        selected.update(range(max(0, i-2), min(len(lines), i+14)))
print('\n=== Compiler / linker / Godot errors (full log retained) ===')
if selected:
    for i in sorted(selected):
        print(f'{i+1}: {lines[i]}')
else:
    print('No recognized error marker; final 100 lines follow.')
    print('\n'.join(lines[-100:]))
PY
}
failed() {
    local status=$?
    printf '\nFAILED: stage=%s line=%s exit=%s\n' "${1:-unknown}" "${2:-unknown}" "$status" | tee -a "$LOGS/failure.txt"
    exit "$status"
}
trap 'failed "${STAGE:-startup}" "$LINENO"' ERR

require_file() {
    local path="$1" label="${2:-required file}"
    if [ ! -s "$path" ]; then
        echo "ERROR: Missing or empty $label: $path"
        return 1
    fi
}
write_file_picker_gdip() {
    mkdir -p "$PLUGIN_DIR"
    cat > "$PLUGIN_DIR/FilePicker.gdip" <<'GDIP'
[config]
name="FilePicker"
binary="FilePicker.a"
initialization="file_picker_init"
deinitialization="file_picker_deinit"

[dependencies]
linked=[]
embedded=[]
system=["Foundation.framework", "UIKit.framework", "UniformTypeIdentifiers.framework"]
capabilities=[]
files=[]
linker_flags=["-ObjC"]

[plist]
GDIP
    require_file "$PLUGIN_DIR/FilePicker.gdip" "FilePicker.gdip"
}
ensure_platform_header() {
    local header_root="$1" relative_path="$2" destination
    destination="$header_root/$relative_path"
    if [ ! -s "$destination" ]; then
        mkdir -p "$(dirname "$destination")"
        curl --fail --location --retry 3 --connect-timeout 30 --max-time 120 \
            --output "$destination" \
            "https://raw.githubusercontent.com/godotengine/godot/$TAG/$relative_path"
    fi
    require_file "$destination" "$relative_path"
}

fetch() {
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 1800 \
        --output "$TOOLS/$1" "$RELEASE/$1"
}
verify_download() {
    python3 - "$TOOLS" "$1" <<'PY'
import hashlib, pathlib, sys
root, name = pathlib.Path(sys.argv[1]), sys.argv[2]
entries = {}
for line in (root/'SHA512-SUMS.txt').read_text().splitlines():
    parts = line.split()
    if len(parts) == 2:
        entries[parts[1].lstrip('*')] = parts[0].lower()
if name not in entries:
    raise SystemExit('Missing official checksum: ' + name)
h = hashlib.sha512()
with (root/name).open('rb') as f:
    for chunk in iter(lambda: f.read(8*1024*1024), b''):
        h.update(chunk)
if h.hexdigest() != entries[name]:
    raise SystemExit('SHA512 mismatch: ' + name)
print('SHA512 verified:', name)
PY
}

environment() {
    test "$(uname -s)" = Darwin
    sw_vers
    uname -m
    xcode-select -p
    xcodebuild -version
    xcrun --sdk iphoneos --show-sdk-version
    xcrun --sdk iphoneos --show-sdk-path
    python3 --version
    df -h "$ROOT"
}
download() {
    mkdir -p "$TOOLS"
    fetch SHA512-SUMS.txt
    fetch "Godot_v${TAG}_macos.universal.zip"
    verify_download "Godot_v${TAG}_macos.universal.zip"
    ditto -x -k "$TOOLS/Godot_v${TAG}_macos.universal.zip" "$TOOLS"
    test -x "$GODOT"
    "$GODOT" --version
}
templates() {
    fetch "Godot_v${TAG}_export_templates.tpz"
    verify_download "Godot_v${TAG}_export_templates.tpz"
    local target="$HOME/Library/Application Support/Godot/export_templates/$VERSION.stable"
    mkdir -p "$target"
    # Only the iOS template is needed; don't unpack all platforms.
    unzip -p "$TOOLS/Godot_v${TAG}_export_templates.tpz" templates/ios.zip > "$target/ios.zip"
    test -s "$target/ios.zip"
    unzip -tq "$target/ios.zip"
    rm "$TOOLS/Godot_v${TAG}_export_templates.tpz"
}
build_file_picker_plugin() {
    mkdir -p "$PLUGIN_DIR" "$PLUGIN_HEADERS"
    write_file_picker_gdip
    local archive="$TOOLS/godot-headers-$TAG.zip"
    local headers_url="https://github.com/godot-mobile-plugins/godot-ios-builds/releases/download/$TAG/godot-headers-$TAG.zip"
    if [ ! -s "$archive" ]; then
        curl --fail --location --retry 3 --connect-timeout 30 --max-time 900 \
            --output "$archive" "$headers_url"
    fi
    rm -rf "$PLUGIN_HEADERS"
    mkdir -p "$PLUGIN_HEADERS"
    unzip -q "$archive" -d "$PLUGIN_HEADERS"

    local object_header header_root sdk object_file
    object_header="$(find "$PLUGIN_HEADERS" -type f -path '*/core/object/object.h' -print -quit)"
    test -n "$object_header"
    header_root="${object_header%/core/object/object.h}"
    test -f "$header_root/core/config/engine.h"
    test -f "$header_root/core/object/class_db.h"
    # Godot core/typedefs.h includes "platform_config.h" without a directory prefix.
    # The iOS header archive stores it under platform/ios/.
    ensure_platform_header "$header_root" "platform/ios/platform_config.h"
    ensure_platform_header "$header_root" "drivers/apple_embedded/platform_config.h"
    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    object_file="$BUILD/FilePicker.o"

    xcrun --sdk iphoneos clang++ \
        -x objective-c++ -std=gnu++17 -O2 -fobjc-arc -fmodules -fcxx-modules \
        -fno-exceptions -fvisibility=hidden \
        -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 \
        -DNDEBUG -DNS_BLOCK_ASSERTIONS=1 \
        -DPTRCALL_ENABLED -DTYPED_METHOD_BIND \
        -DIOS_ENABLED -DAPPLE_EMBEDDED_ENABLED -DUNIX_ENABLED -DCOREAUDIO_ENABLED -DVULKAN_ENABLED \
        -I"$header_root" -I"$header_root/platform/ios" \
        -c "$PLUGIN_SRC/file_picker.mm" -o "$object_file"

    rm -f "$PLUGIN_DIR/FilePicker.release.a" "$PLUGIN_DIR/FilePicker.debug.a"
    xcrun ar rcs "$PLUGIN_DIR/FilePicker.release.a" "$object_file"
    xcrun ranlib "$PLUGIN_DIR/FilePicker.release.a"
    # The runner only exports Release, but keeping a debug variant lets Godot validate the plugin cleanly.
    cp "$PLUGIN_DIR/FilePicker.release.a" "$PLUGIN_DIR/FilePicker.debug.a"

    file "$PLUGIN_DIR/FilePicker.release.a"
    xcrun nm -gU "$PLUGIN_DIR/FilePicker.release.a" > "$LOGS/file-picker-symbols.txt"
    # Godot's generated dummy.cpp references the C++ (mangled) entry points.
    grep -q '_Z16file_picker_initv' "$LOGS/file-picker-symbols.txt"
    grep -q '_Z18file_picker_deinitv' "$LOGS/file-picker-symbols.txt"
    test -s "$PLUGIN_DIR/FilePicker.gdip"
    echo "Native iOS FilePicker plugin built against Godot $TAG headers."
}
validate() {
    # The descriptor is source metadata and must always exist, even before the native archive is rebuilt.
    if [ ! -s "$PLUGIN_DIR/FilePicker.gdip" ]; then
        echo "FilePicker.gdip missing; regenerating it."
        write_file_picker_gdip
    fi
    require_file "$PROJECT/project.godot" "project.godot"
    require_file "$PROJECT/export_presets.cfg" "export_presets.cfg"
    require_file "$PROJECT/runner.tscn" "runner.tscn"
    require_file "$PROJECT/runner.gd" "runner.gd"
    require_file "$PLUGIN_SRC/file_picker.mm" "native FilePicker source"
    require_file "$PLUGIN_SRC/file_picker.h" "native FilePicker header"
    require_file "$PLUGIN_DIR/FilePicker.gdip" "FilePicker.gdip"
    if [ ! -s "$PLUGIN_DIR/FilePicker.release.a" ]; then
        echo "FilePicker.release.a is missing. Building native plugin now."
        build_file_picker_plugin
    fi
    require_file "$PLUGIN_DIR/FilePicker.release.a" "FilePicker release library"
    require_file "$PLUGIN_DIR/FilePicker.debug.a" "FilePicker debug library"
    if ! grep -q '^plugins/FilePicker=true$' "$PROJECT/export_presets.cfg"; then
        echo "ERROR: iOS export preset does not enable plugins/FilePicker=true"
        return 1
    fi
    echo "Validate preflight: required project and FilePicker plugin files are present."
    local actual
    actual="$("$GODOT" --version)"
    case "$actual" in 4.6.stable.*) ;; *) echo "Unexpected engine: $actual"; return 1 ;; esac
    # Import before loading scenes or exporting resources.
    if run_log godot-import.log "$GODOT" --headless --path "$PROJECT" --editor --import; then
        :
    else
        errors "$LOGS/godot-import.log"
        return 1
    fi
    if run_log godot-run.log "$GODOT" --headless --path "$PROJECT" --quit-after 90; then
        :
    else
        errors "$LOGS/godot-run.log"
        return 1
    fi
    python3 - "$LOGS" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1])
for name in ('godot-import.log', 'godot-run.log'):
    text=(root/name).read_text(errors='replace')
    if re.search(r'SCRIPT ERROR|Parse Error|Failed to load script|ERROR:', text):
        raise SystemExit('Godot validation errors in ' + name)
if 'RUNNER_READY:' not in (root/'godot-run.log').read_text():
    raise SystemExit('Main scene never reached _ready')
print('Main scene imported and ran successfully.')
PY
}
export_ios() {
    # Fresh directory prevents an old successful export from masking a failure.
    rm -rf "$EXPORT"
    mkdir -p "$EXPORT"
    local status=0
    if run_log godot-export.log "$GODOT" --headless --verbose --path "$PROJECT" \
        --export-release iOS "$EXPORT/Runner.ipa"; then
        status=0
    else
        status=$?
        errors "$LOGS/godot-export.log"
    fi
    printf '%s\n' "$status" > "$LOGS/godot-export-exit.txt"
    # The requested output name is NOT presumed to be an archive.
    python3 - "$EXPORT" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
projects=list(root.rglob('*.xcodeproj'))
if len(projects)!=1 or projects[0].name!='Runner.xcodeproj':
    raise SystemExit('Expected one fresh Runner.xcodeproj, found: '+str(projects))
p=projects[0]
if not (p/'project.pbxproj').is_file() or (p/'project.pbxproj').stat().st_size==0:
    raise SystemExit('Missing or empty project.pbxproj')
packs=list(root.rglob('*.pck'))
if not any(p.stat().st_size>0 for p in packs):
    raise SystemExit('Missing exported Godot resource pack')
(root/'project-path.txt').write_text(str(p)+'\n')
print('Verified exported Xcode project:', p)
PY
    local pbxproj="$(cat "$EXPORT/project-path.txt")/project.pbxproj"
    plutil -lint "$pbxproj"
    if ! grep -q 'FilePicker' "$pbxproj"; then
        echo 'FilePicker plugin is not present in exported Xcode project.'
        return 1
    fi
    if ! grep -q 'UniformTypeIdentifiers' "$pbxproj"; then
        echo 'UniformTypeIdentifiers.framework was not linked by FilePicker.gdip.'
        return 1
    fi
    echo 'Verified native FilePicker plugin in exported Xcode project.'
    run_log xcode-project.log xcodebuild -list -project "$(cat "$EXPORT/project-path.txt")"
    if [ "$status" -ne 0 ]; then
        echo "::warning::Godot exited $status, but a fresh readable Xcode project and resource pack exist. Continuing to the actual device build."
    fi
}
build_app() {
    rm -rf "$BUILD/DerivedData"
    local status
    if run_log xcodebuild.log xcodebuild \
        -project "$(cat "$EXPORT/project-path.txt")" -scheme Runner \
        -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
        -derivedDataPath "$BUILD/DerivedData" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
        PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= \
        build; then
        :
    else
        status=$?
        echo "xcodebuild failed with original exit code $status"
        errors "$LOGS/xcodebuild.log"
        return "$status"
    fi
}
verify_app() {
    local app="$BUILD/DerivedData/Build/Products/Release-iphoneos/Runner.app"
    test -d "$app"
    test -s "$app/Info.plist"
    plutil -lint "$app/Info.plist"
    local executable
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
    test "$executable" = Runner
    test -x "$app/$executable"
    file "$app/$executable"
    xcrun lipo "$app/$executable" -verify_arch arm64
    # Check the Mach-O target is iOS device, not iOS Simulator.
    xcrun vtool -show-build "$app/$executable" > "$LOGS/macho-build.txt"
    cat "$LOGS/macho-build.txt"
    python3 - "$app" "$LOGS/macho-build.txt" <<'PY'
import pathlib, plistlib, re, sys
app=pathlib.Path(sys.argv[1])
p=plistlib.loads((app/'Info.plist').read_bytes())
assert p['CFBundleSupportedPlatforms']==['iPhoneOS'], p
assert p['CFBundlePackageType']=='APPL', p
assert 'arm64' in p.get('UIRequiredDeviceCapabilities', ['arm64']), p
text=pathlib.Path(sys.argv[2]).read_text()
assert re.search(r'platform\s+IOS\b', text), text
assert 'IOSSIMULATOR' not in text, text
assert not (app/'embedded.mobileprovision').exists(), 'Unexpected provisioning profile'
assert not (app/'_CodeSignature').exists(), 'Unexpected signature directory'
assert any(f.stat().st_size>0 for f in app.rglob('*.pck')), 'Missing runtime PCK'
print('Verified iPhone arm64 application and Godot resources.')
PY
    xcrun otool -l "$app/$executable" > "$LOGS/macho-load-commands.txt"
    if grep -q LC_CODE_SIGNATURE "$LOGS/macho-load-commands.txt"; then
        echo 'Unexpected signed executable in unsigned build.'
        return 1
    fi
}
package_ipa() {
    local app="$BUILD/DerivedData/Build/Products/Release-iphoneos/Runner.app"
    rm -rf "$BUILD/package"
    mkdir -p "$BUILD/package/Payload" "$ROOT/dist"
    rm -f "$ROOT/dist/Runner.ipa"
    ditto "$app" "$BUILD/package/Payload/Runner.app"
    (cd "$BUILD/package" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ROOT/dist/Runner.ipa" Payload)
    python3 - "$ROOT/dist/Runner.ipa" <<'PY'
import pathlib, plistlib, stat, sys, zipfile
path=pathlib.Path(sys.argv[1])
with zipfile.ZipFile(path) as z:
    assert z.testzip() is None, 'ZIP CRC failure'
    names=z.namelist()
    assert all(n.startswith('Payload/') for n in names), 'Wrong ZIP root'
    plist='Payload/Runner.app/Info.plist'
    assert plist in names, 'Missing Info.plist'
    info=plistlib.loads(z.read(plist))
    exe='Payload/Runner.app/'+info['CFBundleExecutable']
    assert exe in names and z.getinfo(exe).file_size>0, 'Missing executable'
    assert z.read(exe)[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'), 'Not Mach-O'
    assert (z.getinfo(exe).external_attr>>16) & stat.S_IXUSR, 'Lost executable mode'
    assert any(n.endswith('.pck') for n in names), 'Missing Godot resources'
    assert not any('_CodeSignature/' in n or n.endswith('embedded.mobileprovision') for n in names)
print('Verified unsigned IPA:', path, 'bytes:', path.stat().st_size)
PY
}

STAGE="${1:-all}"
case "$STAGE" in
    environment|download|templates|build_file_picker_plugin|validate|export_ios|build_app|verify_app|package_ipa)
        "$STAGE" 2>&1 | tee "$LOGS/$STAGE.log" ;;
    all)
        for STAGE in environment download templates build_file_picker_plugin validate export_ios build_app verify_app package_ipa; do
            "$STAGE" 2>&1 | tee "$LOGS/$STAGE.log"
        done ;;
    *) echo "Unknown stage: $STAGE"; exit 2 ;;
esac
