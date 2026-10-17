#!/bin/zsh
# build.sh          -> dist/Smoll.app
# build.sh install  -> /Applications/Smoll.app only (nothing left in dist) + register the Finder service
set -e
cd "$(dirname "$0")"

# image tools ship inside the app; vendored once, refreshed by rerunning the script
[[ -d app/Helpers ]] || scripts/vendor-tools.sh
swift build -c release

if [[ "$1" == "install" ]]; then
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    APP="$STAGE/Smoll.app"
else
    APP=dist/Smoll.app
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/smoll "$APP/Contents/MacOS/Smoll"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R app/Helpers/ "$APP/Contents/Helpers/"
cp -R app/Licenses "$APP/Contents/Resources/Licenses"
codesign --force --sign - "$APP"

if [[ "$1" == "install" ]]; then
    rm -rf /Applications/smoll.app /Applications/Smoll.app
    cp -R "$APP" /Applications/Smoll.app
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Smoll.app
    echo "Installed to /Applications. If [Make smoll] doesn't show up in Finder's context menu yet, log out/in once."
else
    echo "Built $APP"
fi
