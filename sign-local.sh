#!/bin/sh
set -eu

preferred_identity="${WINDOWSWINDOWS_SIGNING_IDENTITY:-59F098B48426A5C577FB7D1FA93C58810D5CEFAF}"
app_path="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
entitlements_path="${SRCROOT}/WindowsWindows/WindowsWindows.entitlements"
main_executable="${app_path}/Contents/MacOS/${EXECUTABLE_NAME}"

if [ "${ACTION:-}" = "clean" ]; then
    exit 0
fi

identity="-"
if security find-identity -v -p codesigning | grep -q "$preferred_identity"; then
    identity="$preferred_identity"
else
    echo "warning: preferred signing identity is unavailable; using an ad-hoc signature" >&2
fi

if [ ! -d "$app_path" ]; then
    echo "error: built application not found at $app_path" >&2
    exit 1
fi

# Sign embedded Mach-O files first so the main executable and outer bundle seal
# include their signatures.
find "$app_path/Contents" -type f -print0 | while IFS= read -r -d '' candidate; do
    if [ "$candidate" != "$main_executable" ] && file -b "$candidate" | grep -q 'Mach-O'; then
        codesign --force --sign "$identity" --timestamp=none "$candidate"
    fi
done

codesign --force --sign "$identity" --timestamp=none "$main_executable"
codesign --force --sign "$identity" --timestamp=none \
    --entitlements "$entitlements_path" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
