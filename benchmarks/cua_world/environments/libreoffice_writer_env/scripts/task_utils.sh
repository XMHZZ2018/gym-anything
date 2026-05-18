#!/bin/bash
# Shared utilities for LibreOffice Writer task setup and export scripts

# Set display for X11 commands
export DISPLAY=:1
export XAUTHORITY=/home/ga/.Xauthority

# Wait for a window with specified title to appear
# Args: $1 - window title pattern (grep pattern)
#       $2 - timeout in seconds (default: 30)
# Returns: 0 if found, 1 if timeout
wait_for_window() {
    local window_pattern="$1"
    local timeout=${2:-30}
    local elapsed=0

    echo "Waiting for window matching '$window_pattern'..."

    while [ $elapsed -lt $timeout ]; do
        if wmctrl -l | grep -qi "$window_pattern"; then
            echo "Window found after ${elapsed}s"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    echo "Timeout: Window not found after ${timeout}s"
    return 1
}

# Wait for a file to be created or modified
# Args: $1 - file path
#       $2 - timeout in seconds (default: 10)
# Returns: 0 if file exists and was recently modified, 1 if timeout
wait_for_file() {
    local filepath="$1"
    local timeout=${2:-10}
    local start=$(date +%s)

    echo "Waiting for file: $filepath"

    while [ $(($(date +%s) - start)) -lt $timeout ]; do
        if [ -f "$filepath" ]; then
            if [ $(find "$filepath" -mmin -0.2 2>/dev/null | wc -l) -gt 0 ] || \
               [ $(($(date +%s) - start)) -lt 2 ]; then
                echo "File ready: $filepath"
                return 0
            fi
        fi
        sleep 0.5
    done

    echo "Timeout: File not updated: $filepath"
    return 1
}

# Wait for a process to start
# Args: $1 - process name pattern (pgrep pattern)
#       $2 - timeout in seconds (default: 20)
# Returns: 0 if process found, 1 if timeout
wait_for_process() {
    local process_pattern="$1"
    local timeout=${2:-20}
    local elapsed=0

    echo "Waiting for process matching '$process_pattern'..."

    while [ $elapsed -lt $timeout ]; do
        if pgrep -f "$process_pattern" > /dev/null; then
            echo "Process found after ${elapsed}s"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    echo "Timeout: Process not found after ${timeout}s"
    return 1
}

# Focus a window and verify it was focused
# Args: $1 - window ID or name pattern
# Returns: 0 if focused successfully, 1 otherwise
focus_window() {
    local window_id="$1"

    if wmctrl -ia "$window_id" 2>/dev/null || wmctrl -a "$window_id" 2>/dev/null; then
        sleep 0.3
        echo "Window focused: $window_id"
        return 0
    fi

    echo "Failed to focus window: $window_id"
    return 1
}

# Get the window ID for LibreOffice Writer
# Returns: window ID or empty string
get_writer_window_id() {
    wmctrl -l | grep -i 'LibreOffice Writer\|\.docx\|\.odt' | awk '{print $1; exit}'
}

# Safe xdotool command with display and user context
# Args: $1 - user (e.g., "ga")
#       $2 - display (e.g., ":1")
#       rest - xdotool arguments
safe_xdotool() {
    local user="$1"
    local display="$2"
    shift 2

    su - "$user" -c "DISPLAY=$display xdotool $*" 2>&1 | grep -v "^$"
    return ${PIPESTATUS[0]}
}

# Maximize a window by ID
# Args: $1 - window ID (e.g. 0x...)
maximize_window_id() {
    local wid="$1"
    [ -z "$wid" ] && return 1
    DISPLAY=:1 wmctrl -ia "$wid" 2>/dev/null || true
    DISPLAY=:1 wmctrl -ir "$wid" -b add,maximized_vert,maximized_horz 2>/dev/null || true
}

# Kill all LibreOffice processes
kill_libreoffice() {
    pkill -f "soffice" 2>/dev/null || true
    sleep 1
    pkill -9 -f "soffice" 2>/dev/null || true
    sleep 1
}

# Dismiss LibreOffice startup dialogs (Recovery, Template, What's New, Tip)
dismiss_dialogs() {
    for attempt in 1 2 3; do
        if DISPLAY=:1 wmctrl -l 2>/dev/null | grep -qi "Recovery\|Template\|What\|Tip of the Day"; then
            echo "Dismissing dialog (attempt $attempt)..."
            su - ga -c "DISPLAY=:1 xdotool key Escape" 2>/dev/null || true
            sleep 2
        else
            break
        fi
    done
    su - ga -c "DISPLAY=:1 xdotool key Escape" 2>/dev/null || true
    sleep 1
}

# Ensure LibreOffice Writer is fully loaded, focused, and maximized.
# Robust against:
#   - splash/empty Writer window appearing before doc finishes loading
#   - Document Recovery / Tip-of-the-Day dialogs
#   - Writer self-resizing shortly after window first appears
# Idempotent: safe to call at the end of any setup_task.sh that has
# already launched soffice.
ensure_writer_loaded() {
    echo "ensure_writer_loaded: waiting for soffice process..."
    wait_for_process "soffice" 30 || true

    echo "ensure_writer_loaded: waiting for Writer/document window..."
    # Match either the generic Writer window title or any open doc file.
    local start=$(date +%s)
    local timeout=90
    while true; do
        local elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "ensure_writer_loaded: timeout waiting for Writer window"
            break
        fi
        if DISPLAY=:1 wmctrl -l 2>/dev/null | grep -qiE "LibreOffice Writer|\.docx|\.odt|\.doc "; then
            echo "ensure_writer_loaded: Writer window detected after ${elapsed}s"
            break
        fi
        sleep 1
    done

    # Initial settle delay so the doc has time to render before we touch it
    sleep 4

    # Dismiss any stray startup dialogs
    dismiss_dialogs

    # Find the Writer window ID (prefer doc-file title over splash)
    local wid
    wid=$(DISPLAY=:1 wmctrl -l 2>/dev/null | grep -iE "\.docx|\.odt|\.doc " | head -1 | awk '{print $1}')
    if [ -z "$wid" ]; then
        wid=$(DISPLAY=:1 wmctrl -l 2>/dev/null | grep -i "LibreOffice Writer" | head -1 | awk '{print $1}')
    fi

    if [ -z "$wid" ]; then
        echo "ensure_writer_loaded: no Writer window found, giving up"
        return 1
    fi

    # Re-apply maximize a few times — Writer sometimes resizes itself
    # after first appearing.
    local i
    for i in 1 2 3; do
        maximize_window_id "$wid"
        sleep 1
    done

    # Final Escape in case a popup re-appeared during activation
    su - ga -c "DISPLAY=:1 xdotool key Escape" 2>/dev/null || true
    # Extra settle so the screenshot taken right after this returns
    # captures the fully-rendered document.
    sleep 3
    return 0
}

# Take a screenshot of the current desktop. Tolerates missing scrot or X
# unavailability so callers under `set -e` are not killed.
# Args: $1 - output path
take_screenshot() {
    local out="$1"
    [ -z "$out" ] && return 0
    su - ga -c "DISPLAY=:1 scrot '$out'" 2>/dev/null \
        || DISPLAY=:1 scrot "$out" 2>/dev/null \
        || true
    return 0
}

# Export these functions for use in other scripts
export -f wait_for_window
export -f wait_for_file
export -f wait_for_process
export -f focus_window
export -f get_writer_window_id
export -f safe_xdotool
export -f maximize_window_id
export -f kill_libreoffice
export -f dismiss_dialogs
export -f ensure_writer_loaded
export -f take_screenshot
