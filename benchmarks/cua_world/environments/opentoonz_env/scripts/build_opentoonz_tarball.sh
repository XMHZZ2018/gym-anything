#!/bin/bash
#
# Build a self-contained OpenToonz 1.5.0 runtime tarball that
# install_opentoonz.sh extracts at env-install time.
#
# Why we need this: the upstream env relies on `snap install opentoonz`,
# which fails in sysbox-runc (no kernel squashfs / no snapd). The snap blob
# itself ships Qt 5.9.5 whose XCB GL integration crashes on modern Mesa+Xvnc.
# So we source-build OpenToonz 1.5.0 against the Noble host's Qt 5.15, then
# bundle the Qt5/OpenCV/etc runtime .so files + Qt platform plugins into the
# tarball so the env container needs no Qt/OpenCV apt packages.
#
# Usage (run on any Linux host with Docker):
#
#     ./build_opentoonz_tarball.sh
#
# Output: opentoonz-1.5.0-linux-x86_64.tar.gz in the same directory
# (next to install_opentoonz.sh). Run once on a new VM if the tarball is
# missing — install_opentoonz.sh exits early with a clear error message
# pointing here.
#
# Build takes ~10-15min on 16 cores. Output is ~55MB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="$SCRIPT_DIR/opentoonz-1.5.0-linux-x86_64.tar.gz"
BUILD_IMAGE="ubuntu:24.04"
CONTAINER_NAME="opentoonz_tarball_builder"

if [ -f "$ARTIFACT" ]; then
    echo "Artifact already exists at $ARTIFACT (skipping)."
    echo "Delete it first if you want to rebuild."
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required on the build host." >&2
    exit 1
fi

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [1/4] Launching Noble build container ==="
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" "$BUILD_IMAGE" sleep infinity >/dev/null

ex() { docker exec "$CONTAINER_NAME" bash -c "$*"; }

echo "=== [2/4] Installing build dependencies ==="
ex "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq \
    build-essential git cmake pkg-config \
    libboost-all-dev \
    qtbase5-dev libqt5svg5-dev qtscript5-dev qttools5-dev qttools5-dev-tools \
    libqt5opengl5-dev qtmultimedia5-dev libqt5multimedia5-plugins \
    libqt5serialport5-dev qt5-image-formats-plugins \
    libsuperlu-dev liblz4-dev libusb-1.0-0-dev liblzo2-dev \
    libpng-dev libjpeg-dev libglew-dev freeglut3-dev libfreetype6-dev \
    libjson-c-dev qtwayland5 libmypaint-dev libopencv-dev libturbojpeg0-dev \
    libegl1-mesa-dev libgles2-mesa-dev libglib2.0-dev liblzma-dev \
    libopenblas-dev libtiff-dev"

echo "=== [3/4] Building OpenToonz 1.5.0 from source ==="
ex "git clone --depth 1 -b v1.5.0 https://github.com/opentoonz/opentoonz.git /tmp/opentoonz"
# OpenToonz cmake hard-requires its bundled libtiff 4.0.3 (not system libtiff).
ex "cd /tmp/opentoonz/thirdparty/tiff-4.0.3 && ./configure --with-pic --disable-jbig --quiet && make -j\$(nproc) -s"
# WITH_TRANSLATION=OFF: avoids cmake-error from duplicate qt5_create_translation
#   custom commands on cmake >= 3.20.
# -Wno-changes-meaning: works around a hard error from g++14 on tcg/hash.h
#   `typedef ... size_t` declaration.
ex "mkdir -p /tmp/opentoonz/toonz/build && cd /tmp/opentoonz/toonz/build && \
    cmake ../sources -DCMAKE_BUILD_TYPE=Release -DWITH_TRANSLATION=OFF \
        -DCMAKE_CXX_FLAGS='-Wno-changes-meaning -Wno-error=changes-meaning' \
        > /tmp/cmake.log 2>&1"
ex "cd /tmp/opentoonz/toonz/build && make -j\$(nproc) > /tmp/make.log 2>&1"
ex "cd /tmp/opentoonz/toonz/build && make install > /tmp/install.log 2>&1"

echo "=== [4/4] Bundling Qt5/OpenCV runtime libs + plugins ==="
# Walk the binary + bundled libs, find every dynamic dep, copy the ones the
# env container won't have via apt (Qt5 t64-renamed pkgs, OpenCV 406, etc.)
# into /opt/opentoonz/lib/opentoonz/. Resolve symlink chains so dlopen(soname)
# works against the real file.
ex "cd /opt/opentoonz && \
    ALL=\$(ldd bin/OpenToonz lib/opentoonz/*.so 2>/dev/null | awk '/=>/ {print \$3}' | sort -u | grep -v '^\$') && \
    for lib in \$ALL; do \
        bn=\$(basename \"\$lib\"); \
        case \"\$bn\" in \
            libQt5*|libopencv*|libmypaint*|libsuperlu*|libglut*|libGLEW*|libavcodec*|libavformat*|libavutil*|libswscale*|libswresample*|libturbojpeg*) \
                real=\$(readlink -f \"\$lib\"); \
                cp -n \"\$real\" /opt/opentoonz/lib/opentoonz/\$(basename \"\$real\"); \
                ln -sf \"\$(basename \"\$real\")\" /opt/opentoonz/lib/opentoonz/\$bn; \
                ;; \
        esac; \
    done"
# Qt platform plugin (libqxcb.so) + image format plugins. install_opentoonz.sh's
# launcher exports QT_PLUGIN_PATH/QT_QPA_PLATFORM_PLUGIN_PATH at this location.
ex "mkdir -p /opt/opentoonz/qt5_plugins/{platforms,imageformats,iconengines} && \
    cp /usr/lib/x86_64-linux-gnu/qt5/plugins/platforms/libqxcb.so /opt/opentoonz/qt5_plugins/platforms/ && \
    cp /usr/lib/x86_64-linux-gnu/qt5/plugins/imageformats/*.so /opt/opentoonz/qt5_plugins/imageformats/ 2>/dev/null || true && \
    cp /usr/lib/x86_64-linux-gnu/qt5/plugins/iconengines/*.so /opt/opentoonz/qt5_plugins/iconengines/ 2>/dev/null || true"
# Wrapper that the env's install_opentoonz.sh hard-links from
# /usr/local/bin/opentoonz. Sets LD_LIBRARY_PATH + Qt plugin paths to bundled.
ex "cat > /opt/opentoonz/bin/opentoonz <<'WRAP'
#!/bin/sh
OPENTOONZ_BASE=\$(dirname \"\$0\")/..
mkdir -p \$HOME/.config/OpenToonz
if [ ! -d \$HOME/.config/OpenToonz/stuff ]; then
    cp -r \$OPENTOONZ_BASE/share/opentoonz/stuff \$HOME/.config/OpenToonz
fi
mkdir -p \$HOME/.config/OpenToonz/stuff/projects/library
mkdir -p \$HOME/.config/OpenToonz/stuff/projects/fxs
if [ ! -e \$HOME/.config/OpenToonz/SystemVar.ini ]; then
    cat > \$HOME/.config/OpenToonz/SystemVar.ini <<EOF
[General]
OPENTOONZROOT=\"\$HOME/.config/OpenToonz/stuff\"
OpenToonzPROFILES=\"\$HOME/.config/OpenToonz/stuff/profiles\"
TOONZCACHEROOT=\"\$HOME/.config/OpenToonz/stuff/cache\"
TOONZCONFIG=\"\$HOME/.config/OpenToonz/stuff/config\"
TOONZFXPRESETS=\"\$HOME/.config/OpenToonz/stuff/fxs\"
TOONZLIBRARY=\"\$HOME/.config/OpenToonz/stuff/library\"
TOONZPROFILES=\"\$HOME/.config/OpenToonz/stuff/profiles\"
TOONZPROJECTS=\"\$HOME/.config/OpenToonz/stuff/projects\"
TOONZROOT=\"\$HOME/.config/OpenToonz/stuff\"
TOONZSTUDIOPALETTE=\"\$HOME/.config/OpenToonz/stuff/studiopalette\"
EOF
fi
export LD_LIBRARY_PATH=\$OPENTOONZ_BASE/lib/opentoonz:\$LD_LIBRARY_PATH
export QT_PLUGIN_PATH=\$OPENTOONZ_BASE/qt5_plugins
export QT_QPA_PLATFORM_PLUGIN_PATH=\$OPENTOONZ_BASE/qt5_plugins/platforms
exec \$OPENTOONZ_BASE/bin/OpenToonz \"\$@\"
WRAP
chmod +x /opt/opentoonz/bin/opentoonz"

echo "=== Packaging tarball ==="
ex "cd / && tar czf /tmp/opentoonz-1.5.0.tar.gz opt/opentoonz"
docker exec "$CONTAINER_NAME" cat /tmp/opentoonz-1.5.0.tar.gz > "$ARTIFACT"

echo "=== Done ==="
echo "Artifact: $ARTIFACT ($(du -h "$ARTIFACT" | cut -f1))"
