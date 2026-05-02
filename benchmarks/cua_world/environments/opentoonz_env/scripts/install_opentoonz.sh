#!/bin/bash
set -e

echo "=== Installing OpenToonz 1.5.0 (source-built, self-contained tarball) ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update
# Only low-level system libs are needed at runtime — Qt5, OpenCV, mypaint,
# superlu, glew, glut, ffmpeg, turbojpeg are bundled inside the tarball under
# /opt/opentoonz/lib/opentoonz/ (on LD_LIBRARY_PATH via the launcher).
apt-get install -y \
    scrot \
    wmctrl \
    xdotool \
    imagemagick \
    ffmpeg \
    python3-pip \
    python3-pil \
    wget \
    git \
    libfontconfig1 \
    libfreetype6 \
    libpng16-16 \
    libdbus-1-3 \
    libxkbcommon-x11-0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-xinerama0 \
    libxcb-xkb1 \
    libglu1-mesa \
    libusb-1.0-0 \
    liblz4-1 \
    liblzo2-2 \
    libjson-c5 \
    libpulse0 \
    libopenblas0

# Source-built OpenToonz 1.5.0 artifact (bind-mounted via /workspace/scripts).
# Built on a Noble build host using `make install` to /opt/opentoonz with
# OpenToonz v1.5.0 + thirdparty libtiff-4.0.3, then bundled with Qt5/OpenCV/etc
# runtime .so files under lib/opentoonz/ and Qt platform plugins under
# qt5_plugins/. This avoids the snap path which fails inside sysbox-runc:
# - no kernel squashfs / no snapd in container
# - snap's bundled Qt5 5.9.5 fails GLX init on modern Mesa/Xvnc
ARTIFACT=/workspace/scripts/opentoonz-1.5.0-linux-x86_64.tar.gz
if [ ! -f "$ARTIFACT" ]; then
    echo "ERROR: missing $ARTIFACT" >&2
    echo "Run scripts/build_opentoonz_tarball.sh on a host with Docker to" >&2
    echo "produce the tarball, then re-launch the env." >&2
    exit 1
fi

echo "Extracting OpenToonz 1.5.0 to /opt/opentoonz..."
rm -rf /opt/opentoonz
tar xzf "$ARTIFACT" -C /

# Drop a top-level wrapper at /usr/local/bin/opentoonz that delegates to the
# installed /opt/opentoonz/bin/opentoonz launcher (which seeds ~/.config and
# sets LD_LIBRARY_PATH + QT_PLUGIN_PATH for the bundled libs/plugins).
cat > /usr/local/bin/opentoonz <<'WRAPPER'
#!/bin/bash
exec /opt/opentoonz/bin/opentoonz "$@"
WRAPPER
chmod +x /usr/local/bin/opentoonz

# Block the async update-check that pops a "new version available" dialog
# over the editor mid-setup (host is reachable on this VM).
if ! grep -q "opentoonz.github.io" /etc/hosts; then
    echo "127.0.0.1 opentoonz.github.io" >> /etc/hosts
fi

# Install Python packages for verification
pip3 install pillow numpy || true

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== OpenToonz 1.5.0 installation complete ==="
