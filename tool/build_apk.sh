#!/usr/bin/env bash
# Builds the release APK the way README's "Versioning" and "Build" sections
# describe: move the version first, then build, so the APK that comes out
# carries a versionCode higher than the one already on the phone.
#
# A plain `flutter build apk` does not move the version, and Android compares
# versionCode before anything else: two builds of the same tree install as
# the same version and the second one is refused.
#
# Usage:
#   tool/build_apk.sh                 # 0.3.18+26 -> 0.3.18+27, then build
#   tool/build_apk.sh --patch         # 0.3.18+26 -> 0.3.19+27, then build
#   tool/build_apk.sh --no-bump       # build the version as it stands
set -euo pipefail

cd "$(dirname "$0")/.."

bump=1
bump_args=()
for arg in "$@"; do
  case "$arg" in
    --no-bump) bump=0 ;;
    --patch|--minor|--major) bump_args+=("$arg") ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: tool/build_apk.sh [--patch|--minor|--major] [--no-bump]" >&2
      exit 64
      ;;
  esac
done

if [ "$bump" -eq 1 ]; then
  dart run tool/bump_version.dart "${bump_args[@]}"
fi

# The bump flags above belong to this script, not to Flutter: forwarding them
# made `tool/build_apk.sh --patch` fail with "Could not find an option named
# patch" right after it had already moved the version.
flutter build apk --release --target-platform android-arm64

apk="build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$apk" ]; then
  echo "build finished but $apk is missing" >&2
  exit 1
fi
echo "APK: $apk"
ls -lh "$apk"
