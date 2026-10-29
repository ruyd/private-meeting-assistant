#!/bin/zsh
# Builds, launches and screenshots the Debug app, for checking UI changes without clicking around by
# hand (and for agents, which can't see the screen otherwise).
#
#   run-app.sh build                     # regenerate the project and build Debug
#   run-app.sh launch [args…]            # quit any running copy, launch with args
#   run-app.sh shot <out.png> [title]    # screenshot the app's window (title substring; default: main window)
#   run-app.sh settings [Tab]            # open Settings, optionally on a tab ("Accounts", "Storage"…)
#   run-app.sh windows                   # list the app's on-screen windows (id, title)
#   run-app.sh quit
#
# The app shows your real meetings. Screenshots and `settings` need Screen Recording and
# Accessibility permission for the terminal (or Claude) that runs this.
set -euo pipefail

MAC_DIR=${0:A:h:h}
APP_NAME="Private Meeting Assistant"
PROJECT="$MAC_DIR/PrivateMeetingAssistant.xcodeproj"

# xcodebuild needs Xcode, not the Command Line Tools xcode-select often points at.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" != *Xcode*.app* ]]; then
  export DEVELOPER_DIR=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer
fi

app_path() {
  local dir=$(xcodebuild -project "$PROJECT" -scheme PrivateMeetingAssistant -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
  echo "$dir/$APP_NAME.app"
}

# "<window id> <title>" per on-screen window of the app.
windows() {
  swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "Private Meeting Assistant" && (w["kCGWindowLayer"] as? Int) == 0 {
    print(w["kCGWindowNumber"] ?? "", w["kCGWindowName"] ?? "")
}
EOF
}

quit_app() { pkill -f "$APP_NAME.app/Contents/MacOS/" 2>/dev/null || true; }

activate() {
  osascript -e "tell application \"System Events\" to tell (first process whose name is \"$APP_NAME\") to set frontmost to true"
}

case "${1:-}" in
  build)
    (cd "$MAC_DIR" && xcodegen generate >/dev/null)
    xcodebuild -project "$PROJECT" -scheme PrivateMeetingAssistant -configuration Debug -destination 'platform=macOS' build 2>&1 \
      | grep -E "error:|\*\* BUILD" || true
    [[ -d "$(app_path)" ]] || { echo "build failed" >&2; exit 1; }
    ;;
  launch)
    shift
    app=$(app_path)
    [[ -d "$app" ]] || { echo "Not built yet: run '$0 build' first" >&2; exit 1; }
    quit_app
    sleep 1
    open -n "$app" --args "$@"
    # Wait for the main window.
    for _ in {1..30}; do
      [[ -n "$(windows)" ]] && break
      sleep 0.5
    done
    windows
    ;;
  shot)
    out=${2:?usage: shot <out.png> [title]}
    title=${3:-}
    if [[ -n "$title" ]]; then
      id=$(windows | grep -F -- "$title" | head -1 | cut -d' ' -f1)
    else
      # The main window is the one that isn't Settings (whose title is the tab name).
      id=$(windows | grep -vE " (Transcription|Summaries|Accounts|Storage|Permissions|About)$" | head -1 | cut -d' ' -f1)
    fi
    [[ -n "$id" ]] || { echo "No matching window. Windows:" >&2; windows >&2; exit 1; }
    screencapture -x -o -l "$id" "$out"
    echo "$out"
    ;;
  settings)
    activate
    osascript -e 'tell application "System Events" to keystroke "," using command down'
    sleep 1.5
    if [[ -n "${2:-}" ]]; then
      osascript -e "tell application \"System Events\" to tell (first process whose name is \"$APP_NAME\") to click button \"$2\" of toolbar 1 of window 1" >/dev/null
      sleep 0.5
    fi
    windows
    ;;
  windows) windows ;;
  quit) quit_app ;;
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
