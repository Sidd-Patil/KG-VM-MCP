#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# prepare_image.sh
# Downloads Ubuntu 22.04 ARM64 cloud image, converts to raw, and builds a
# cloud-init seed ISO with serial-getty autologin on hvc0.
# ---------------------------------------------------------------------------

if ! command -v qemu-img &>/dev/null; then
    echo "Error: qemu-img is required. Install with:"
    echo "  brew install qemu"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_DIR/images"
mkdir -p "$IMAGES_DIR"

QCOW2_PATH="$IMAGES_DIR/ubuntu-22.04-arm64.qcow2"
RAW_PATH="$IMAGES_DIR/ubuntu-22.04-arm64.img"
SEED_ISO="$IMAGES_DIR/seed.iso"

# ── Download Ubuntu 22.04 ARM64 cloud image (QCOW2) ─────────────────────────
if [ ! -f "$QCOW2_PATH" ]; then
    echo "Downloading Ubuntu 22.04 ARM64 cloud image (~600 MB)..."
    curl -L --progress-bar -o "$QCOW2_PATH" \
        "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img"
else
    echo "QCOW2 image already exists, skipping download."
fi

# ── Convert QCOW2 → raw (required by Virtualization.framework) ──────────────
if [ ! -f "$RAW_PATH" ]; then
    echo "Converting to raw format (this expands to ~2.5 GB)..."
    qemu-img convert -p -O raw "$QCOW2_PATH" "$RAW_PATH"
else
    echo "Raw image already exists, skipping conversion."
fi

# ── Build cloud-init seed ISO ────────────────────────────────────────────────
CIDATA_DIR="$(mktemp -d)"
trap "rm -rf $CIDATA_DIR" EXIT

cat > "$CIDATA_DIR/meta-data" << 'EOF'
instance-id: vm-mcp-001
local-hostname: ubuntu-vm
EOF

# user-data: autologin ubuntu user on hvc0, passwordless sudo
cat > "$CIDATA_DIR/user-data" << 'EOF'
#cloud-config

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false

write_files:
  - path: /etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I $TERM

runcmd:
  - mkdir -p /etc/systemd/system/serial-getty@hvc0.service.d
  - systemctl daemon-reload
  - systemctl enable serial-getty@hvc0.service
  - systemctl start serial-getty@hvc0.service
  - touch /etc/cloud/cloud-init.disabled
  - echo "cloud-init done" > /tmp/cloud-init-complete
EOF

# vendor-data must exist for NoCloud; empty is fine
touch "$CIDATA_DIR/vendor-data"

# Create seed ISO using hdiutil makehybrid.
# Produces an ISO 9660 volume labeled "cidata" — cloud-init's NoCloud data
# source finds it by that label. Linux VMs don't mount HFS+, so the hybrid
# layer is harmless.
echo "Building seed ISO..."
hdiutil makehybrid -quiet \
    -o "$SEED_ISO" \
    -joliet -iso \
    -default-volume-name cidata \
    "$CIDATA_DIR"

echo ""
echo "Done! Files in $IMAGES_DIR:"
echo "  Ubuntu raw image : $RAW_PATH"
echo "  Seed ISO         : $SEED_ISO"
echo ""
echo "Next — build the Swift binary:"
echo "  cd vm-helper && swift build -c release"
echo ""
echo "Then create a test VM:"
echo "  ./vm-helper/.build/release/VMHelper create myvm $SEED_ISO"
