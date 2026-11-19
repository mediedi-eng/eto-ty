#!/bin/sh
# Start in Finder on the Mac that will run the simulator or sign the iPhone build.
set -eu
cd "$(dirname "$0")"

find_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
        printf '%s\n' "$DEVELOPER_DIR"
    elif [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
        printf '%s\n' /Applications/Xcode.app/Contents/Developer
    else
        selected=$(xcode-select -p 2>/dev/null || true)
        if [ -n "$selected" ] && [ -x "$selected/usr/bin/xcodebuild" ]; then printf '%s\n' "$selected"; fi
    fi
}

developer_dir=$(find_developer_dir)
if [ -z "$developer_dir" ]; then
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
make ios-build
open -a "$xcode_app" ios/EtoTy.xcodeproj
printf '%s\n' 'Проект открыт. Выбери iPhone в верхней панели Xcode и нажми Run.'
