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

if [ "$mode" = --smoke ]; then
    # Select an installed iOS runtime and a compatible iPhone without using any personal simulator.
    xcodebuild -license check
    if ! xcodebuild -checkFirstLaunchStatus; then
        echo 'Завершите первый запуск Xcode перед проверкой симулятора.' >&2
        exit 1
    fi
    selection=$(xcrun simctl list -j | python3 -c '
import json, sys
catalog = json.load(sys.stdin)
runtimes = sorted(
    (runtime for runtime in catalog["runtimes"] if runtime.get("isAvailable")
     and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
    key=lambda runtime: tuple(int(n) for n in runtime["version"].split(".")),
    reverse=True,
)
for runtime in runtimes:
    if int(runtime["version"].split(".")[0]) < 17:
        continue
    device_types = [device["identifier"] for device in runtime.get("supportedDeviceTypes", [])]
    device_types.extend(device.get("deviceTypeIdentifier", "") for device
                        in catalog["devices"].get(runtime["identifier"], []))
    iphone = next((identifier for identifier in device_types if ".iPhone-" in identifier), None)
    if iphone:
        print(runtime["identifier"], iphone)
        break
else:
    sys.exit("Для проверки установите iOS Simulator версии 17 или новее в настройках Xcode.")
')
    runtime=${selection% *}
    device_type=${selection#* }
    simulator=$(xcrun simctl create "EtoTy smoke $$" "$device_type" "$runtime")
    trap 'xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; xcrun simctl delete "$simulator" >/dev/null 2>&1 || true' 0
    trap 'exit 1' HUP INT TERM
    run_xcodebuild -destination "platform=iOS Simulator,id=$simulator" \
        -parallel-testing-enabled NO -only-testing:EtoTyUITests test
    exit 0
fi

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    open -a "$xcode_app"
    printf '%s\n' 'Заверши первый запуск Xcode, включая выбор iOS и системные подтверждения, затем нажми Enter.'
    IFS= read -r _ || exit 1
    xcodebuild -checkFirstLaunchStatus
fi
runtimes=$(LC_ALL=C xcrun simctl list runtimes available)
if ! printf '%s\n' "$runtimes" | awk '/^iOS [0-9]/ && $2+0 >= 17 && $0 !~ /unavailable/ { found=1 } END { exit !found }'; then
    printf '%s\n' 'Загружаю среду iOS Simulator через Xcode.'
    xcodebuild -downloadPlatform iOS
fi
build_app
open -a "$xcode_app" ios/EtoTy.xcodeproj
printf '%s\n' 'Проект открыт. Выбери iPhone в верхней панели Xcode и нажми Run.'
