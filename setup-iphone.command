#!/bin/sh
# Start in Finder on the Mac that will run the simulator or sign the iPhone build.
set -eu
cd "$(dirname "$0")"
mode=${1:---open}
case "$mode" in
    --build|--smoke|--open) ;;
    *) echo 'Usage: setup-iphone.command [--open|--build|--smoke]' >&2; exit 2 ;;
esac

find_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
        printf '%s\n' "$DEVELOPER_DIR"
        return
    fi
    selected=$(xcode-select -p 2>/dev/null || true)
    if [ -n "$selected" ] && [ -x "$selected/usr/bin/xcodebuild" ]; then
        printf '%s\n' "$selected"
    elif [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
        printf '%s\n' /Applications/Xcode.app/Contents/Developer
    fi
}

developer_dir=$(find_developer_dir)
if [ -z "$developer_dir" ] && [ "$mode" = --open ]; then
    printf '%s\n' 'Открою Xcode в App Store. Нажми «Загрузить» и дождись появления кнопки «Открыть».'
    if ! open 'macappstore://itunes.apple.com/app/id497799835?mt=12'; then
        open 'https://apps.apple.com/app/id497799835' || true
    fi
    printf '%s\n' 'Когда Xcode установится в «Программы», нажми Enter.'
    IFS= read -r _ || exit 1
    developer_dir=$(find_developer_dir)
fi
if [ -z "$developer_dir" ]; then
    printf '%s\n' 'Полный Xcode пока не найден. Заверши установку и открой этот файл ещё раз.' >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"
xcode_app=$(dirname "$(dirname "$DEVELOPER_DIR")")
run_xcodebuild() {
    xcodebuild -project ios/EtoTy.xcodeproj -scheme EtoTy -configuration Debug \
        -derivedDataPath local-data/build/ios "$@"
}

build_app() {
    run_xcodebuild -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
}

if [ "$mode" = --build ]; then
    build_app
    exit 0
fi

if [ "$mode" = --open ] && ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    open -a "$xcode_app"
    printf '%s\n' 'Заверши первый запуск Xcode и системные подтверждения, затем нажми Enter.'
    IFS= read -r _ || exit 1
fi
xcodebuild -license check
xcodebuild -checkFirstLaunchStatus

device_name='EtoTy Development'
select_simulator() {
    catalog=$(xcrun simctl list -j) || {
        printf '%s\n' 'Нет связи с CoreSimulator. Открой Xcode и повтори запуск из Finder или Terminal на Mac.' >&2
        return 1
    }
    printf '%s\n' "$catalog" | python3 -c '
import json, sys
catalog = json.load(sys.stdin)
mode, name = sys.argv[1:3]
runtimes = sorted(
    (r for r in catalog["runtimes"] if r.get("isAvailable")
     and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
     and int(r["version"].split(".")[0]) >= 17),
    key=lambda r: tuple(int(n) for n in r["version"].split(".")), reverse=True)
candidates = []
for runtime in runtimes:
    runtime_id = runtime["identifier"]
    devices = catalog["devices"].get(runtime_id, [])
    if mode == "--open":
        for device in devices:
            if (device.get("name") == name and device.get("isAvailable")
                    and ".iPhone-" in device.get("deviceTypeIdentifier", "")):
                print(device["udid"])
                sys.exit(0)
    types = [d["identifier"] for d in runtime.get("supportedDeviceTypes", [])]
    types.extend(d.get("deviceTypeIdentifier", "") for d in devices)
    iphone = next((t for t in types if ".iPhone-" in t), None)
    if iphone:
        candidates.append((runtime_id, iphone))
if not candidates:
    sys.exit(3)
print(*candidates[0])
' "$mode" "$device_name"
}

waiting=false
while :; do
    if selection=$(select_simulator); then break; else result=$?; fi
    if [ "$result" -ne 3 ]; then exit "$result"; fi
    if [ "$mode" != --open ] || [ ! -t 0 ]; then
        printf '%s\n' 'Установи iOS Simulator версии 17 или новее в Xcode → Settings → Components.' >&2
        exit 1
    fi
    if [ "$waiting" = false ]; then
        printf '%s\n' 'Ожидаю iOS Simulator. Если загрузка уже идёт в Xcode, дождись её завершения. Иначе выбери iOS в Settings → Components. Для отмены нажми Ctrl+C.'
        waiting=true
    fi
    sleep 8
done

if [ "$mode" = --smoke ]; then
    runtime=${selection% *}
    device_type=${selection#* }
    simulator=$(xcrun simctl create "EtoTy smoke $$" "$device_type" "$runtime")
    trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' 0
    trap 'exit 1' HUP INT TERM
    run_xcodebuild -destination "platform=iOS Simulator,id=$simulator" \
        -parallel-testing-enabled NO -only-testing:EtoTyUITests test
    exit 0
fi

case "$selection" in
    *' '*) simulator=$(xcrun simctl create "$device_name" "${selection#* }" "${selection% *}") ;;
    *) simulator=$selection ;;
esac

build_app
xcrun simctl bootstatus "$simulator" -b
app="local-data/build/ios/Build/Products/Debug-iphonesimulator/EtoTy.app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$simulator" "$app"
xcrun simctl launch --terminate-running-process "$simulator" "$bundle_id"
device_hub="$xcode_app/Contents/Applications/DeviceHub.app"
if [ -d "$device_hub" ]; then
    open -a "$device_hub" "devices://device/open?id=$simulator"
else
    open -a "$DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$simulator"
fi
printf '%s\n' '«Это ты» запущено. При следующем запуске личный профиль сохранится в этом симуляторе.'
