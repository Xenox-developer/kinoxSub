#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly PROJECT_PATH="$NATIVE_DIR/KinoXPlayer.xcodeproj"
readonly SCHEME="KinoXPlayer"
readonly CONFIGURATION="Release"
readonly PRODUCT_NAME="KinoXPlayer"
readonly DIST_DIR="$NATIVE_DIR/dist"
readonly FINAL_APP="$DIST_DIR/$PRODUCT_NAME.app"

fail() {
  printf 'Ошибка: %s\n' "$1" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 \
  || fail "xcodebuild не найден. Установите Xcode и инструменты командной строки."

command -v codesign >/dev/null 2>&1 \
  || fail "codesign не найден. Без локальной подписи приложение не будет опубликовано в dist."

[[ -d "$PROJECT_PATH" ]] \
  || fail "проект не найден: $PROJECT_PATH"

temporary_root="${TMPDIR:-/tmp}"
temporary_root="${temporary_root%/}"
work_dir="$(mktemp -d "$temporary_root/KinoXPlayer-release.XXXXXX")" \
  || fail "не удалось создать временную папку для сборки."

derived_data_dir="$work_dir/DerivedData"
built_app="$derived_data_dir/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
staged_app=""
backup_app=""

cleanup() {
  local exit_status=$?

  if [[ -n "$backup_app" && -e "$backup_app" && ! -e "$FINAL_APP" ]]; then
    /bin/mv "$backup_app" "$FINAL_APP" 2>/dev/null || true
  fi

  if [[ -n "$staged_app" && -e "$staged_app" ]]; then
    /bin/rm -rf "$staged_app"
  fi

  if [[ -d "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi

  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Сборка %s (%s)…\n' "$SCHEME" "$CONFIGURATION"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data_dir" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

[[ -d "$built_app" ]] \
  || fail "сборка завершилась, но приложение не найдено: $built_app"

/bin/mkdir -p "$DIST_DIR"
staged_app="$DIST_DIR/.$PRODUCT_NAME.staging.$$.app"
/usr/bin/ditto "$built_app" "$staged_app"

codesign --force --deep --sign - --timestamp=none "$staged_app" \
  || fail "не удалось поставить ad-hoc подпись. Предыдущая сборка сохранена."

codesign --verify --deep --strict "$staged_app" \
  || fail "проверка ad-hoc подписи завершилась ошибкой. Предыдущая сборка сохранена."

if [[ -e "$FINAL_APP" ]]; then
  backup_app="$DIST_DIR/.$PRODUCT_NAME.previous.$$.app"
  /bin/mv "$FINAL_APP" "$backup_app"
fi

/bin/mv "$staged_app" "$FINAL_APP"
staged_app=""

if [[ -n "$backup_app" && -e "$backup_app" ]]; then
  /bin/rm -rf "$backup_app"
  backup_app=""
fi

printf 'Готово: %s\n' "$FINAL_APP"
