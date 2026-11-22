#!/usr/bin/env bash
# Waydroid with REAL GPU acceleration (for a native Ubuntu install).
#
# WHY THIS EXISTS
#   In WSL2 the RTX 2080 is exposed only as /dev/dxg (D3D12). Waydroid needs a
#   DRM render node (/dev/dri/renderD*), which WSL2 does not provide. There is
#   no supported DRM passthrough into WSL2: every attempt to force Mesa EGL
#   there ends in "Failed to open any DRM device" and a SIGSEGV crash loop.
#   On a native Linux boot the NVIDIA driver creates /dev/dri/renderD128 and
#   Waydroid can use hardware OpenGL instead of SwiftShader.
#
# USAGE
#   Run this ONLY after booting into Ubuntu 24.04 (not WSL).
#   sudo bash tools/linux-waydroid-gpu-setup.sh
#
# The script is idempotent-ish: safe to re-run after a reboot.

set -euo pipefail

say() { printf '\n== %s ==\n' "$*"; }

say '1/7 Check that a DRM render node exists'
if [ ! -d /dev/dri ]; then
    echo 'ERROR: /dev/dri is missing. Boot into native Linux with the NVIDIA'
    echo 'proprietary driver installed (nvidia-drm.modeset=1) before running this.'
    exit 1
fi
ls -l /dev/dri

say '2/7 Install base packages'
apt-get update
apt-get install -y curl ca-certificates gnupg adb mesa-utils egl-utils

say '3/7 Ensure the NVIDIA proprietary driver is loaded'
if ! command -v nvidia-smi >/dev/null 2>&1; then
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
    echo 'Driver installed. Add nvidia-drm.modeset=1 to the kernel command line,'
    echo 'reboot, then run this script again.'
    exit 0
fi
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
if ! grep -Rqs 'modeset=1' /etc/modprobe.d /proc/cmdline; then
    echo 'options nvidia-drm modeset=1' > /etc/modprobe.d/nvidia-drm.conf
    echo 'Added nvidia-drm modeset=1; reboot and re-run this script.'
    exit 0
fi

say '4/7 Install Waydroid'
if ! command -v waydroid >/dev/null 2>&1; then
    curl -s https://repo.waydro.id | bash
    apt-get install -y waydroid
fi

say '5/7 Initialise Waydroid (GAPPS image) if needed'
if [ ! -f /var/lib/waydroid/waydroid.cfg ]; then
    waydroid init -s GAPPS
fi

say '6/7 Disable software rendering in Waydroid props'
# Waydroid ships these forcing SwiftShader. Remove them everywhere they can be
# re-generated, then explicitly select Mesa EGL + GBM gralloc.
for f in /var/lib/waydroid/waydroid_base.prop /var/lib/waydroid/waydroid.prop; do
    [ -f "$f" ] || continue
    sed -i '/^ro\.hardware\.egl=/d; /^ro\.hardware\.gralloc=/d' "$f"
    echo 'ro.hardware.egl=mesa' >> "$f"
    echo 'ro.hardware.gralloc=minigbm_gbm_mesa' >> "$f"
done
# waydroid.cfg [properties] is merged into the generated props on upgrade.
if [ -f /var/lib/waydroid/waydroid.cfg ]; then
    sed -i '/^ro\.hardware\.egl/d; /^ro\.hardware\.gralloc/d' /var/lib/waydroid/waydroid.cfg
    sed -i '/^\[properties\]/a ro.hardware.egl = mesa\nro.hardware.gralloc = minigbm_gbm_mesa' /var/lib/waydroid/waydroid.cfg
fi
grep -nE 'hardware\.egl|hardware\.gralloc' /var/lib/waydroid/waydroid_base.prop

say '7/7 Start the container and verify the renderer'
systemctl enable --now waydroid-container
for _ in $(seq 1 30); do
    adb connect 192.168.240.112:5555 >/dev/null 2>&1 || true
    if adb -s 192.168.240.112:5555 get-state 2>/dev/null | grep -q device; then
        break
    fi
    sleep 2
done
if ! adb -s 192.168.240.112:5555 get-state 2>/dev/null | grep -q device; then
    echo 'ERROR: Android did not come up. Check: journalctl -u waydroid-container -b'
    exit 1
fi

RENDERER=$(adb -s 192.168.240.112:5555 shell dumpsys SurfaceFlinger | grep -m1 '^GLES:' || true)
echo "OpenGL renderer: $RENDERER"
if echo "$RENDERER" | grep -qi 'swiftshader\|llvmpipe\|software'; then
    echo 'WARNING: still software rendering. Try: waydroid upgrade -o'
    echo 'and make sure /dev/dri/renderD128 belongs to the render group.'
    exit 1
fi

echo
echo 'SUCCESS: Waydroid is using the GPU.'
echo 'Start the game with:'
echo '  waydroid app launch com.ihgames.im.android.google'
echo 'or install it first: adb install-multiple /path/to/base.apk /path/to/splits/*.apk'
exit 0
