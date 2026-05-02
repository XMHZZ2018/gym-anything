#!/bin/bash
set -e

echo "=== Setting up OpenToonz environment ==="

# Wait for desktop to be ready
sleep 5

# Create OpenToonz directories for ga user
echo "Setting up OpenToonz directories..."
su - ga -c "mkdir -p /home/ga/OpenToonz"
su - ga -c "mkdir -p /home/ga/OpenToonz/projects"
su - ga -c "mkdir -p /home/ga/OpenToonz/outputs"
su - ga -c "mkdir -p /home/ga/Desktop"

# Download official OpenToonz sample data
echo "Downloading OpenToonz sample data..."
SAMPLE_DIR="/home/ga/OpenToonz/samples"
su - ga -c "mkdir -p $SAMPLE_DIR"

# Download from official GitHub repository
cd /tmp
wget -q https://github.com/opentoonz/opentoonz_sample/archive/refs/heads/master.zip -O opentoonz_sample.zip || {
    echo "Warning: Could not download sample data from GitHub"
}

if [ -f /tmp/opentoonz_sample.zip ]; then
    unzip -q /tmp/opentoonz_sample.zip -d /tmp/
    cp -r /tmp/opentoonz_sample-master/* "$SAMPLE_DIR/" || true
    chown -R ga:ga "$SAMPLE_DIR"
    rm -rf /tmp/opentoonz_sample.zip /tmp/opentoonz_sample-master
    echo "Sample data downloaded successfully"
fi

# Create desktop shortcut for OpenToonz
cat > /home/ga/Desktop/OpenToonz.desktop << 'EOF'
[Desktop Entry]
Name=OpenToonz
Comment=2D Animation Software
Exec=/usr/local/bin/opentoonz
Icon=opentoonz
StartupNotify=true
Terminal=false
Type=Application
Categories=Graphics;2DGraphics;Animation;
EOF
chmod +x /home/ga/Desktop/OpenToonz.desktop
chown ga:ga /home/ga/Desktop/OpenToonz.desktop

# Create launch script
cat > /usr/local/bin/launch-opentoonz << 'LAUNCH_EOF'
#!/bin/bash
export DISPLAY=${DISPLAY:-:1}
xhost +local: 2>/dev/null || true

if command -v opentoonz &> /dev/null; then
    exec opentoonz "$@"
else
    echo "OpenToonz not found"
    exit 1
fi
LAUNCH_EOF
chmod +x /usr/local/bin/launch-opentoonz

# Seed the user's config from the AppImage's bundled `stuff/` tree. The
# bundled launcher only copies this on first run if ~/.config/OpenToonz/stuff
# does NOT exist yet — and OpenToonz needs the menubar/template files inside
# or it shows a permanent "Cannot open menubar settings template file"
# warning dialog blocking the main UI.
su - ga -c "mkdir -p /home/ga/.config/OpenToonz"
BUNDLED_STUFF=/opt/opentoonz/share/opentoonz/stuff
if [ -d "$BUNDLED_STUFF" ]; then
    cp -r "$BUNDLED_STUFF" /home/ga/.config/OpenToonz/
fi

# Create a preferences file to skip startup dialogs
cat > /home/ga/.config/OpenToonz/stuff/config/preferences.ini << 'PREF_EOF'
[General]
AutoSaveEnabled=false
AutoSavePeriod=10
DefaultViewerEnabled=false
ShowSplashScreen=false
ShowStartupDialog=false
StartupPopupShown=true
[Paths]
ProjectRoot=/home/ga/OpenToonz/projects
[UI]
Language=english
StyleSheet=Default
PREF_EOF
chown -R ga:ga /home/ga/.config/OpenToonz

# Start OpenToonz
echo "Starting OpenToonz..."
su - ga -c "DISPLAY=:1 /usr/local/bin/launch-opentoonz > /tmp/opentoonz.log 2>&1 &"

# Wait for OpenToonz to fully load (it takes a while to initialize)
echo "Waiting for OpenToonz to load..."
sleep 20

# Wait for main window to appear (poll for up to 60 seconds). The startup
# splash, "- Warning", "- Information" and "Startup" dialogs all also have
# OpenToonz-prefixed titles, so explicitly exclude those and require a
# title that does NOT match any dialog form.
TIMEOUT=60
ELAPSED=0
is_main_window_open() {
    DISPLAY=:1 wmctrl -l 2>/dev/null \
      | awk '{ $1=$2=$3=""; sub(/^   /,""); print }' \
      | grep -E "^OpenToonz [0-9]" \
      | grep -vE " - (Warning|Information|Error)$" \
      | grep -vE "^OpenToonz [0-9.]+ - Startup$" \
      | grep -q .
}
while [ $ELAPSED -lt $TIMEOUT ]; do
    if is_main_window_open; then
        echo "OpenToonz main window detected after ${ELAPSED}s"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

# Additional wait for dialogs to appear
sleep 5

# Dismiss startup dialogs. The editor opens with stacked dialogs over the
# main window: an "OpenToonz 1.4 - Information" update notice (which fires
# from an async update check that can pop up many seconds AFTER the main
# window appears) and an "OpenToonz Startup" project picker. Send the
# keypress directly to each window by id (wmctrl -a + global xdotool key
# was unreliable when modal grabs were active). Poll for ~30s so we catch
# late-appearing dialogs.
echo "Dismissing startup dialogs..."

dismiss_one() {
    local title_pattern="$1"
    local key="$2"
    local win_ids
    win_ids=$(DISPLAY=:1 xdotool search --name "$title_pattern" 2>/dev/null || true)
    [ -z "$win_ids" ] && return 0
    for wid in $win_ids; do
        DISPLAY=:1 xdotool windowactivate --sync "$wid" 2>/dev/null || true
        DISPLAY=:1 xdotool key --window "$wid" "$key" 2>/dev/null || true
        DISPLAY=:1 wmctrl -i -c "$wid" 2>/dev/null || true
    done
}

DISMISS_DEADLINE=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$DISMISS_DEADLINE" ]; do
    dismiss_one "OpenToonz [0-9.]+ - Information" Return
    dismiss_one "OpenToonz Startup" Escape
    dismiss_one "OpenToonz [0-9.]+ - (Warning|Error)" Return
    LEFT=$(DISPLAY=:1 wmctrl -l 2>/dev/null \
      | awk '{ $1=$2=$3=""; sub(/^   /,""); print }' \
      | grep -E "(OpenToonz [0-9.]+ - (Warning|Information|Error)|OpenToonz Startup)" || true)
    [ -z "$LEFT" ] && break
    sleep 1
done

# Click somewhere in the middle of the screen to dismiss any popups
DISPLAY=:1 xdotool mousemove 960 540 click 1 2>/dev/null || true
sleep 1

# Close any Firefox windows that may have opened (OpenToonz sometimes opens help pages)
pkill -f firefox 2>/dev/null || true
sleep 2

# Locate the main OpenToonz editor window (not splash/warning/dialog) and
# maximize it.
MAIN_WIN_LINE=$(DISPLAY=:1 wmctrl -l 2>/dev/null \
  | awk '{ id=$1; $1=$2=$3=""; sub(/^   /,""); printf "%s\t%s\n", id, $0 }' \
  | grep -E $'\t'"OpenToonz [0-9]" \
  | grep -vE " - (Warning|Information|Error)$" \
  | grep -vE " - Startup$" \
  | head -n 1)
if [ -n "$MAIN_WIN_LINE" ]; then
    MAIN_WIN_ID=$(printf '%s' "$MAIN_WIN_LINE" | cut -f1)
    DISPLAY=:1 wmctrl -i -r "$MAIN_WIN_ID" -b add,maximized_vert,maximized_horz 2>/dev/null || true
    DISPLAY=:1 wmctrl -i -a "$MAIN_WIN_ID" 2>/dev/null || true
fi

# Final check
echo "Windows after setup:"
DISPLAY=:1 wmctrl -l 2>/dev/null || true

# Fail loudly if the main editor window never appeared — verify_setup uses
# the exit status of this hook to decide PASS/FAIL, so do not let a stuck
# splash or unhandled warning dialog look like success.
if [ -z "$MAIN_WIN_LINE" ]; then
    echo "ERROR: OpenToonz main editor window did not open after setup" >&2
    exit 1
fi

# Also fail if any startup/error dialog survived dismissal — they would block
# the main UI from receiving input.
LEFTOVER_DIALOGS=$(DISPLAY=:1 wmctrl -l 2>/dev/null \
  | awk '{ $1=$2=$3=""; sub(/^   /,""); print }' \
  | grep -E "(OpenToonz [0-9.]+ - (Warning|Information|Error)|OpenToonz Startup)" || true)
if [ -n "$LEFTOVER_DIALOGS" ]; then
    echo "ERROR: dismiss left blocking dialogs:" >&2
    echo "$LEFTOVER_DIALOGS" >&2
    exit 1
fi

echo "=== OpenToonz setup complete ==="
echo "OpenToonz is ready!"
echo "  - Sample data: /home/ga/OpenToonz/samples/"
echo "  - Projects: /home/ga/OpenToonz/projects/"
echo "  - Outputs: /home/ga/OpenToonz/outputs/"
