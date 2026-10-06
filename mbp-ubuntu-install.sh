#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Ubuntu 24.04 hardware setup for the Intel 15-inch A1707 (2016 / 2017).
# Version 2026.10.06
#
# Install Ubuntu Desktop 24.04 LTS first. Keep the Apple EFI firmware intact.
# Internet access is required; USB Ethernet or phone USB tethering is useful.
# Run: sudo bash mbp-ubuntu-install.sh --country AU
# Then reboot and run: sudo mbp-ubuntu --check
#
# Based on:
# https://github.com/kubojion/macbook-pro-2017-ubuntu-24.04
# https://github.com/almas/macbook12-spi-driver/tree/touchbar-driver-hid-driver
# https://github.com/davidjo/snd_hda_macbookpro
# The installer is MIT-licensed; downloaded drivers retain their own licences.
#
# This installs hardware support into an EXISTING Ubuntu installation. It does
# not install the OS, repartition disks, remove macOS, erase EFI firmware, or
# remove an existing kernel. Actual sound, Wi-Fi association, Touch Bar lighting
# and reliable suspend require testing on the physical Mac.
#
# Differences from the guide:
# - Follow the maintained 6.8 GA meta-package, not a frozen kernel ABI.
# - Build for the explicit target kernel even when HWE is currently running.
# - Detect the USB port, HID interfaces, GPU and backlight dynamically.
# - fnmode=1 is media first / Fn for F1-F12 in this driver's actual source.
# - Use in-tree Bluetooth support; the linked patch is for non-Touch-Bar Macs.
# - Tune LE latency; BlueZ ignores the guide's zero BR sniff values.
# - Set the local Wi-Fi regulatory country. Do not use ccode=ALL.
# - The guide's generic NVRAM is optional (--wifi-nvram), preserving the real
#   adapter MAC and existing board calibration where an NVRAM file is present.
# - Leave global sensor-proxy and suspend policy alone.
# - Back up changed files once and provide a restore command.
#
# MIT License
# Copyright (c) 2026
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 022
shopt -s nullglob

readonly VERSION=2026.10.06
readonly STATE=/var/lib/mbp-ubuntu
readonly INSTALLED=/usr/local/sbin/mbp-ubuntu
readonly T1_SHA=526bbe977a979534b0e4d1331eff3facae9bd04a
readonly AUDIO_SHA=89b22ff90b86468b186706861dd18663562defa7
readonly T1_NAME=mbp-t1
readonly AUDIO_NAME=mbp-cs8409
readonly DRIVER_VERSION=0.1
readonly NVRAM_URL=https://gist.githubusercontent.com/cristianmiranda/ba9d64b4324f0803d9422d765de62252/raw/fa8c3db4ece70e21b9619d918a5e5bfb6a28d72b/brcmfmac43602-pcie.txt
ACTION=install
COUNTRY=AU
FNMODE=1
IDLE_TIMEOUT=60
WIFI_NVRAM=0
DO_REBOOT=0
GPU_MODE=
HID_ID=
MODEL=
TARGET_KERNEL=
LOG=

say() { printf '[mbp-ubuntu] %s\n' "$*"; }
warn() { printf '[mbp-ubuntu] WARNING: %s\n' "$*" >&2; }
die() { printf '[mbp-ubuntu] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Ubuntu 24.04 support for MacBookPro13,3 / MacBookPro14,3 (15-inch A1707).

  sudo bash mbp-ubuntu-install.sh --country AU
  sudo reboot
  sudo mbp-ubuntu --check

Options:
  --country CODE       Physical Wi-Fi country, two letters (default: AU).
  --fn-mode MODE       media (default), function, or function-only.
  --idle-timeout N     Touch Bar sleep timeout in seconds, 1..3600 (default 60).
  --wifi-nvram         Also apply the guide's experimental BCM43602 NVRAM fix.
                       Uses your real MAC and local country; keep it optional
                       if the normal firmware already connects correctly.
  --reboot             Reboot after successful installation.
  --check              Read-only runtime and DKMS health report.
  --uninstall          Remove this installer's DKMS modules and restore files.
                       Installed Ubuntu packages and recovery kernels remain.
  --gpu-mode MODE      Set AMD GPU to auto, low, or high. Requires sudo.
  --help               Show this help.

Installs the maintained Ubuntu 6.8 GA kernel and headers, T1 Touch Bar/ambient
light DKMS modules, Cirrus CS8409 audio DKMS, Wi-Fi/BT firmware and tools,
Bluetooth LE latency settings, brightness support, automatic boot selection
of the newest installed 6.8 GA kernel, and a dynamically detected AMD GPU
control. No Touch ID driver exists in these sources. Suspend is not promised.

Run from Ubuntu installed on the internal disk, not the live USB. Connect to
the internet before starting. A build failure stops the install and prints the
log path; fix the cause and rerun the same command. No automatic reboot occurs
unless --reboot is supplied. Keep a working recovery boot option.

State, backups and reports: /var/lib/mbp-ubuntu
Installation logs:          /var/log/mbp-ubuntu
Rebind/boot/refresh actions are used internally by systemd, udev and kernel hooks.
HELP
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --check|--uninstall|--boot|--refresh-boot)
                [[ "$ACTION" == install ]] || die 'Choose one action.'
                ACTION="${1#--}" ;;
            --country)
                (( $# >= 2 )) || die '--country needs a two-letter code.'
                COUNTRY="${2^^}"; shift ;;
            --fn-mode)
                (( $# >= 2 )) || die '--fn-mode needs media, function or function-only.'
                case "$2" in
                    media) FNMODE=1 ;;
                    function) FNMODE=2 ;;
                    function-only) FNMODE=0 ;;
                    *) die 'Invalid --fn-mode.' ;;
                esac
                shift ;;
            --idle-timeout)
                (( $# >= 2 )) || die '--idle-timeout needs a number.'
                [[ "$2" =~ ^[0-9]{1,4}$ ]] || die 'Invalid timeout.'
                IDLE_TIMEOUT=$((10#$2)); shift
                (( IDLE_TIMEOUT >= 1 && IDLE_TIMEOUT <= 3600 )) || die 'Timeout must be 1..3600.' ;;
            --wifi-nvram) WIFI_NVRAM=1 ;;
            --reboot) DO_REBOOT=1 ;;
            --gpu-mode|--rebind-hid)
                [[ "$ACTION" == install ]] || die 'Choose one action.'
                (( $# >= 2 )) || die "$1 needs a value."
                ACTION="${1#--}"
                if [[ "$ACTION" == gpu-mode ]]; then GPU_MODE=$2; else HID_ID=$2; fi
                shift ;;
            *) die "Unknown argument: $1 (use --help)." ;;
        esac
        shift
    done
    [[ "$COUNTRY" =~ ^[A-Z]{2}$ && "$COUNTRY" != XX ]] || die 'Use a real two-letter country, e.g. AU.'
    if [[ "$ACTION" != install ]] && (( WIFI_NVRAM || DO_REBOOT )); then
        die '--wifi-nvram and --reboot are installation options.'
    fi
}

read_model() {
    if [[ -r /sys/class/dmi/id/product_name ]]; then
        IFS= read -r MODEL < /sys/class/dmi/id/product_name
    else
        MODEL=unknown
    fi
}

require_root() { (( EUID == 0 )) || die 'Run this action with sudo.'; }

require_platform() {
    local id= version= vendor=
    read_model
    [[ "$MODEL" == MacBookPro13,3 || "$MODEL" == MacBookPro14,3 ]] ||
        die "Detected $MODEL. This installer supports only the 2016/2017 15-inch A1707."
    [[ $(uname -m) == x86_64 ]] || die 'An Intel x86_64 Mac is required.'
    IFS= read -r vendor < /sys/class/dmi/id/sys_vendor
    [[ "$vendor" == 'Apple Inc.' || "$vendor" == 'Apple Computer, Inc.' ]] ||
        die "Unexpected hardware vendor: $vendor"
    # Read values without executing /etc/os-release.
    id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
    [[ "$id" == ubuntu && "$version" == 24.04 ]] ||
        die "Use Ubuntu 24.04 LTS; detected $id $version."
    [[ -d /run/systemd/system ]] || die 'Boot the installed Ubuntu system using systemd.'
    [[ ! -d /run/live/medium && ! -d /rofs && ! -d /cdrom/casper ]] ||
        die 'Install Ubuntu onto the internal disk first; this is a live USB session.'
    [[ -d /sys/firmware/efi && -e /boot/grub/grub.cfg ]] ||
        die 'An installed EFI Ubuntu system using GRUB is required.'
}

setup_state() {
    install -d -m 0700 "$STATE" "$STATE/backups" "$STATE/sources"
    install -d -m 0755 /var/log/mbp-ubuntu
    LOG="/var/log/mbp-ubuntu/install-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    exec 9>"$STATE/install.lock"
    flock -n 9 || die 'Another install or uninstall is running.'
    say "Version $VERSION; model $MODEL; running kernel $(uname -r)."
    say "Log: $LOG"
}

on_error() {
    local rc=$1 line=$2
    trap - ERR
    warn "Stopped at line $line (exit $rc); installation is incomplete."
    [[ -z "$LOG" ]] || warn "Read $LOG and the DKMS build logs under /var/lib/dkms."
    warn 'The current kernel was not removed. Fix the reported error and rerun, or use --uninstall.'
    exit "$rc"
}

backup_file() {
    local path=$1
    [[ "$path" == /* && "$path" != *$'\n'* ]] || die 'Invalid managed path.'
    if [[ -f "$STATE/managed-files.list" ]] &&
        grep -Fxq -- "$path" "$STATE/managed-files.list"; then return; fi
    if [[ -e "$path" || -L "$path" ]]; then
        [[ ! -d "$path" ]] || die "Refusing to overwrite directory $path"
        mkdir -p -- "$(dirname -- "$STATE/backups$path")"
        cp -a -- "$path" "$STATE/backups$path"
    else
        printf '%s\n' "$path" >> "$STATE/absent-files.list"
    fi
    printf '%s\n' "$path" >> "$STATE/managed-files.list"
}

write_file() {
    local path=$1 mode=${2:-0644} tmp
    backup_file "$path"
    mkdir -p -- "$(dirname -- "$path")"
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -L "$path" ]] || ! cmp -s -- "$tmp" "$path"; then
        # Remove an old symlink before install so a replacement cannot alter its target.
        [[ ! -L "$path" ]] || rm -- "$path"
        install -m "$mode" -- "$tmp" "$path"
    else
        chmod "$mode" "$path"
    fi
    rm -f -- "$tmp"
}

source_dir() { printf '/usr/src/%s-%s' "$1" "$DRIVER_VERSION"; }

check_conflicting_drivers() {
    local status path name
    if command -v dkms >/dev/null; then
        status=$(dkms status)
        if printf '%s\n' "$status" | grep -Eiq '^(applespi|apple-ib[^/,]*|snd_hda_macbookpro|macbook12-bluetooth)[/,]'; then
            die 'Older guide/custom DKMS drivers already exist. Remove those using their original uninstall instructions before running this installer.'
        fi
    fi
    for name in "$T1_NAME" "$AUDIO_NAME"; do
        path=$(source_dir "$name")
        if [[ -e "$path" || -L "$path" ]]; then
            [[ ! -L "$path" && -f "$path/.mbp-ubuntu-owned" ]] ||
                die "Unmanaged driver source exists at $path; it will not be overwritten."
        fi
    done
}

check_secure_boot() {
    if command -v mokutil >/dev/null &&
        mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
        die 'UEFI Secure Boot is enabled. This setup requires a module-signing/MOK workflow before its custom modules can load.'
    fi
}

remember_services() {
    local unit status
    [[ ! -f "$STATE/service-states.tsv" ]] || return 0
    for unit in bluetooth.service systemd-backlight@.service mbp-ubuntu-hardware.service; do
        status=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        printf '%s\t%s\n' "$unit" "$status" >> "$STATE/service-states.tsv"
    done
}

restore_services() {
    local unit status
    [[ -f "$STATE/service-states.tsv" ]] || return 0
    while IFS=$'\t' read -r unit status; do
        case "$status" in
            masked) systemctl mask "$unit" ;;
            masked-runtime) systemctl mask --runtime "$unit" ;;
            disabled) systemctl disable "$unit" 2>/dev/null || true ;;
            enabled) systemctl enable "$unit" ;;
            enabled-runtime) systemctl enable --runtime "$unit" ;;
            *) : ;; # Static/indirect/missing units need no enable-state change.
        esac
    done < "$STATE/service-states.tsv"
}

preflight() {
    local free_root free_boot mount_root mount_boot path
    require_root
    require_platform
    check_conflicting_drivers
    check_secure_boot
    free_root=$(df -Pk / | awk 'NR==2 {print $4}')
    free_boot=$(df -Pk /boot | awk 'NR==2 {print $4}')
    (( free_root >= 6291456 )) || die 'At least 6 GiB free on / is needed for kernel sources and DKMS builds.'
    mount_root=$(findmnt -n -o SOURCE --target /)
    mount_boot=$(findmnt -n -o SOURCE --target /boot)
    if [[ "$mount_root" != "$mount_boot" ]]; then
        (( free_boot >= 409600 )) || die 'At least 400 MiB free on the separate /boot partition is needed.'
    fi
    for path in /sys/bus/usb/devices/*; do
        [[ -r "$path/idVendor" && -r "$path/idProduct" ]] || continue
        if [[ $(< "$path/idVendor") == 05ac && $(< "$path/idProduct") == 1281 ]]; then
            die 'Apple T1 is in recovery mode (05ac:1281). Restore its firmware using macOS before configuring the Touch Bar.'
        fi
    done
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 \
        install -y --no-install-recommends "$@"
}

install_packages() {
    say 'Installing the supported GA kernel, firmware, build tools and hardware utilities.'
    apt-get -o Acquire::Retries=3 update
    # Universe provides DKMS, pavucontrol and other standard Ubuntu packages.
    apt_install software-properties-common
    add-apt-repository -y universe
    apt-get -o Acquire::Retries=3 update
    # On a rerun, kernel post-install hooks may build the audio DKMS driver.
    # Update Ubuntu's matching source archive before configuring new kernels.
    apt_install linux-source-6.8.0
    apt_install linux-generic linux-headers-generic \
        linux-firmware dkms build-essential git ca-certificates curl wget \
        make patch bison flex bc libelf-dev libssl-dev python3 \
        pciutils usbutils iw ethtool rfkill iso-codes wireless-regdb \
        bluez blueman alsa-utils pavucontrol mesa-utils mokutil v4l-utils zstd \
        network-manager \
        initramfs-tools grub-common
    TARGET_KERNEL=$(latest_ga_kernel)
    [[ -n "$TARGET_KERNEL" ]] || die 'No installed Ubuntu 6.8 GA kernel was found.'
    apt_install "linux-headers-$TARGET_KERNEL" "linux-modules-extra-$TARGET_KERNEL"
    [[ -f /usr/src/linux-source-6.8.0.tar.bz2 ]] ||
        die 'Ubuntu linux-source-6.8.0 archive is missing.'
    python3 - "$COUNTRY" <<'PY'
import json, pathlib, sys
code = sys.argv[1]
path = pathlib.Path("/usr/share/iso-codes/json/iso_3166-1.json")
if path.exists():
    valid = {entry["alpha_2"] for entry in json.loads(path.read_text())["3166-1"]}
    if code not in valid:
        raise SystemExit(f"Unknown ISO country: {code}")
PY
    say "Target kernel: $TARGET_KERNEL (future 6.8 security updates remain enabled)."
}

latest_ga_kernel() {
    local path kernels=()
    for path in /boot/vmlinuz-6.8.0-*-generic; do
        [[ -f "$path" ]] || continue
        kernels+=("${path##*/vmlinuz-}")
    done
    (( ${#kernels[@]} )) || return 0
    printf '%s\n' "${kernels[@]}" | sort -V | tail -n 1
}

fetch_driver() {
    local name=$1 repo=$2 sha=$3 tree target
    tree="$STATE/sources/$name"
    target=$(source_dir "$name")
    if [[ -d "$tree/.git" ]]; then
        [[ $(git -C "$tree" remote get-url origin) == "$repo" ]] ||
            die "Unexpected source origin in $tree"
    else
        [[ ! -e "$tree" ]] || die "Unexpected source directory: $tree"
        git init -q "$tree"
        git -C "$tree" remote add origin "$repo"
    fi
    if ! git -C "$tree" cat-file -e "$sha^{commit}" 2>/dev/null; then
        GIT_TERMINAL_PROMPT=0 git -C "$tree" fetch --depth=1 origin "$sha"
    fi
    [[ $(git -C "$tree" rev-parse "$sha^{commit}") == "$sha" ]] ||
        die "Source revision verification failed for $name"
    if [[ -f "$target/.mbp-ubuntu-owned" ]]; then
        [[ $(< "$target/.mbp-ubuntu-owned") == "$sha" ]] ||
            die "A different managed $name source is installed; uninstall it first."
        return
    fi
    install -d -m 0755 "$target"
    git -C "$tree" archive "$sha" | tar -xf - -C "$target"
    printf '%s\n' "$sha" > "$target/.mbp-ubuntu-owned"
    chmod -R go-w "$target"
}

build_driver() {
    local name=$1 status module module_path
    status=$(dkms status -m "$name" -v "$DRIVER_VERSION" -k "$TARGET_KERNEL" 2>/dev/null || true)
    if [[ "$status" != *': installed'* ]]; then
        if [[ -z $(dkms status -m "$name" -v "$DRIVER_VERSION" 2>/dev/null) ]]; then
            dkms add -m "$name" -v "$DRIVER_VERSION"
        fi
        dkms install -m "$name" -v "$DRIVER_VERSION" -k "$TARGET_KERNEL"
    fi
    depmod -a "$TARGET_KERNEL"
    if [[ "$name" == "$T1_NAME" ]]; then
        for module in apple_ibridge apple_ib_tb apple_ib_als; do
            module_path=$(modinfo -k "$TARGET_KERNEL" -n "$module")
            [[ "$module_path" == */updates/dkms/* ]] ||
                die "$module is not being resolved to the installed DKMS driver: $module_path"
        done
    else
        module_path=$(modinfo -k "$TARGET_KERNEL" -n snd_hda_codec_cs8409)
        [[ "$module_path" == */updates/dkms/* ]] ||
            die "Cirrus audio is not being resolved to DKMS: $module_path"
    fi
}

install_drivers() {
    local target
    say 'Downloading the reviewed, pinned T1 and Cirrus driver revisions.'
    fetch_driver "$T1_NAME" https://github.com/almas/macbook12-spi-driver.git "$T1_SHA"
    fetch_driver "$AUDIO_NAME" https://github.com/davidjo/snd_hda_macbookpro.git "$AUDIO_SHA"
    target=$(source_dir "$T1_NAME")
    # Explicit KERNELRELEASE is essential when the running kernel is still HWE.
    cat > "$target/dkms.conf" <<'DKMS'
PACKAGE_NAME="mbp-t1"
PACKAGE_VERSION="0.1"
MAKE[0]="make KERNELRELEASE=$kernelver"
CLEAN="make clean KERNELRELEASE=$kernelver"
BUILT_MODULE_NAME[0]="apple-ibridge"
BUILT_MODULE_NAME[1]="apple-ib-tb"
BUILT_MODULE_NAME[2]="apple-ib-als"
DEST_MODULE_LOCATION[0]="/updates/dkms"
DEST_MODULE_LOCATION[1]="/updates/dkms"
DEST_MODULE_LOCATION[2]="/updates/dkms"
BUILD_EXCLUSIVE_KERNEL="^6[.]8[.]0-[0-9]+-generic$"
AUTOINSTALL="yes"
DKMS
    target=$(source_dir "$AUDIO_NAME")
    cat > "$target/dkms.conf" <<'DKMS'
PACKAGE_NAME="mbp-cs8409"
PACKAGE_VERSION="0.1"
PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"
MAKE[0]="make KERNELRELEASE=$kernelver"
CLEAN="true"
BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"
BUILT_MODULE_LOCATION[0]="build/hda"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILD_EXCLUSIVE_KERNEL="^6[.]8[.]0-[0-9]+-generic$"
AUTOINSTALL="yes"
DKMS
    say 'Building T1 Touch Bar and ambient-light modules.'
    build_driver "$T1_NAME"
    say 'Building the Cirrus CS8409 audio module against Ubuntu kernel sources.'
    build_driver "$AUDIO_NAME"
    # Preserve enough provenance to inspect exactly what was installed.
    cat > "$STATE/sources.txt" <<EOF
guide=https://github.com/kubojion/macbook-pro-2017-ubuntu-24.04
touchbar=https://github.com/almas/macbook12-spi-driver
touchbar_commit=$T1_SHA
audio=https://github.com/davidjo/snd_hda_macbookpro
audio_commit=$AUDIO_SHA
kernel=$TARGET_KERNEL
EOF
}

write_bluetooth_config() {
    local tmp
    backup_file /etc/bluetooth/main.conf
    tmp=$(mktemp)
    python3 - /etc/bluetooth/main.conf "$tmp" <<'PY'
import pathlib, re, sys
src, dst = map(pathlib.Path, sys.argv[1:])
updates = {
    "LE": {"MinConnectionInterval": "6", "MaxConnectionInterval": "9",
           "ConnectionLatency": "0", "ConnectionSupervisionTimeout": "200"}
}
lines = src.read_text().splitlines() if src.exists() else []
out, section, written = [], None, {}
def finish():
    if section in updates:
        for key, value in updates[section].items():
            if key not in written.get(section, set()):
                out.append(f"{key}={value}")
for line in lines:
    match = re.match(r"^\s*\[([^]]+)\]\s*$", line)
    if match:
        finish()
        section = match[1]
        written.setdefault(section, set())
        out.append(line)
        continue
    if section in updates:
        key = re.match(r"^\s*#?\s*([A-Za-z][A-Za-z0-9]*)\s*=", line)
        if key and key[1] in updates[section]:
            name = key[1]
            if name not in written[section]:
                out.append(f"{name}={updates[section][name]}")
                written[section].add(name)
            continue
    out.append(line)
finish()
for name in updates:
    if name not in written:
        out.extend(["", f"[{name}]", *[f"{k}={v}" for k, v in updates[name].items()]])
dst.write_text("\n".join(out) + "\n")
PY
    write_file /etc/bluetooth/main.conf < "$tmp"
    rm -f "$tmp"
}

permanent_wifi_mac() {
    local net vendor device mac
    for net in /sys/class/net/*; do
        [[ -r "$net/device/vendor" && -r "$net/device/device" ]] || continue
        vendor=$(< "$net/device/vendor"); device=$(< "$net/device/device")
        [[ "$vendor" == 0x14e4 && "$device" == 0x43ba ]] || continue
        mac=$(ethtool -P "${net##*/}" 2>/dev/null | awk '{print tolower($NF)}')
        if [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ &&
            "$mac" != 00:00:00:00:00:00 && "$mac" != 00:90:4c:0d:f4:3e ]]; then
            printf '%s\n' "$mac"; return 0
        fi
        # A permanent address of length 6 is authoritative even if the active
        # address has been randomized by NetworkManager.
        if [[ -r "$net/perm_address" ]]; then
            mac=$(< "$net/perm_address")
            [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ &&
                "$mac" != 00:00:00:00:00:00 && "$mac" != 00:90:4c:0d:f4:3e ]] &&
                { printf '%s\n' "$mac"; return 0; }
        fi
    done
    return 1
}

install_nvram() {
    local dest tmp base mac
    (( WIFI_NVRAM )) || return 0
    say 'Applying the optional BCM43602 NVRAM configuration for this model.'
    mac=$(permanent_wifi_mac) ||
        die 'Cannot read the real permanent BCM43602 MAC. Omit --wifi-nvram; the template MAC will never be installed.'
    dest="/lib/firmware/brcm/brcmfmac43602-pcie.Apple Inc.-$MODEL.txt"
    tmp=$(mktemp); base=$(mktemp)
    if [[ -f "$dest" ]]; then
        cp -- "$dest" "$base"
    elif [[ -f "$dest.zst" ]] && command -v zstd >/dev/null; then
        zstd -dc -- "$dest.zst" > "$base"
    elif [[ -f /lib/firmware/brcm/brcmfmac43602-pcie.txt ]]; then
        cp /lib/firmware/brcm/brcmfmac43602-pcie.txt "$base"
    else
        curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
            --connect-timeout 20 --max-time 120 "$NVRAM_URL" -o "$base"
    fi
    python3 - "$base" "$tmp" "$COUNTRY" "$mac" <<'PY'
import pathlib, re, sys
source, target, country, mac = sys.argv[1:]
data = pathlib.Path(source).read_text()
if not 100 <= len(data) <= 32768 or "\x00" in data:
    raise SystemExit("NVRAM payload has an unexpected size or format.")
if not re.search(r"(?mi)^\s*(?:devid\s*=\s*0x43ba|sromrev\s*=\s*11)\s*$", data):
    raise SystemExit("NVRAM payload does not match the reviewed BCM43602 layout.")
values = {"ccode": country, "macaddr": mac}
lines, seen = [], set()
for line in data.splitlines():
    item = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", line)
    if item and item[1] in values:
        key = item[1]
        if key not in seen:
            lines.append(f"{key}={values[key]}")
            seen.add(key)
    else:
        lines.append(line)
lines += [f"{k}={v}" for k, v in values.items() if k not in seen]
pathlib.Path(target).write_text("\n".join(lines) + "\n")
PY
    write_file "$dest" < "$tmp"
    rm -f -- "$tmp" "$base"
}

install_config() {
    say 'Installing hardware configuration, boot service and USB/HID binding rule.'
    write_file /etc/mbp-ubuntu.conf <<EOF
# Managed by mbp-ubuntu; installation choices.
COUNTRY=$COUNTRY
FNMODE=$FNMODE
IDLE_TIMEOUT=$IDLE_TIMEOUT
EOF
    write_file /etc/modprobe.d/mbp-ubuntu-touchbar.conf <<EOF
# In the pinned T1 driver: 1=media first; 2=function first; 0=function only.
options apple_ib_tb fnmode=$FNMODE idle_timeout=$IDLE_TIMEOUT
EOF
    write_file /etc/modules-load.d/mbp-ubuntu.conf <<'EOF'
applespi
intel_lpss_pci
spi_pxa2xx_platform
apple_ibridge
apple_ib_tb
apple_ib_als
hci_uart
btbcm
btusb
uvcvideo
EOF
    backup_file /etc/initramfs-tools/modules
    python3 - /etc/initramfs-tools/modules <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text() if path.exists() else ""
modules = ("intel_lpss_pci", "spi_pxa2xx_platform", "applespi",
           "apple_ibridge", "apple_ib_tb", "apple_ib_als")
existing = {line.split("#", 1)[0].strip().split()[0]
            for line in text.splitlines() if line.split("#", 1)[0].strip()}
missing = [name for name in modules if name not in existing]
if missing:
    path.write_text(text.rstrip() + "\n# mbp-ubuntu T1 support\n" + "\n".join(missing) + "\n")
PY
    write_file /etc/NetworkManager/conf.d/99-mbp-ubuntu-wifi.conf <<'EOF'
[connection]
wifi.powersave=2
EOF
    write_bluetooth_config
    write_file /etc/udev/rules.d/90-mbp-ubuntu-ibridge.rules <<'EOF'
# Let the T1 driver claim the display interface instead of hid-sensor-hub.
ACTION=="add", SUBSYSTEM=="hid", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8600", ENV{HID_PHYS}=="*/input3", RUN+="/usr/local/sbin/mbp-ubuntu --rebind-hid %k"
EOF
    write_file /etc/systemd/system/mbp-ubuntu-hardware.service <<'EOF'
[Unit]
Description=MacBook Pro A1707 T1 and hardware initialization
After=systemd-udev-trigger.service NetworkManager.service bluetooth.service
Before=display-manager.service
ConditionPathExists=/etc/mbp-ubuntu.conf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mbp-ubuntu --boot
RemainAfterExit=yes
TimeoutStartSec=45

[Install]
WantedBy=multi-user.target
EOF
    write_file /etc/kernel/postinst.d/zzzz-mbp-ubuntu 0755 <<'EOF'
#!/bin/sh
set -e
# Standard kernel/DKMS hooks run first. Re-select the newest compatible GA
# kernel without removing a recovery or HWE kernel.
if [ -x /usr/local/sbin/mbp-ubuntu ] && [ -f /etc/mbp-ubuntu.conf ]; then
    /usr/local/sbin/mbp-ubuntu --refresh-boot
fi
EOF
    systemctl daemon-reload
    systemctl unmask bluetooth.service
    systemctl enable mbp-ubuntu-hardware.service
    systemctl enable bluetooth.service
    udevadm control --reload-rules
    # Avoid disconnecting an in-progress install by restarting NetworkManager.
    nmcli general reload conf 2>/dev/null || warn 'NetworkManager will read the new settings at reboot.'
}

grub_entry_id() {
    python3 - /boot/grub/grub.cfg "$TARGET_KERNEL" <<'PY'
import pathlib, shlex, sys
path, kernel = sys.argv[1:]
submenu = None
for line in pathlib.Path(path).read_text().splitlines():
    stripped = line.lstrip()
    if not stripped.startswith(("submenu ", "menuentry ")):
        continue
    try:
        tokens = shlex.split(stripped, comments=False)
    except ValueError:
        continue
    entry_id = None
    for marker in ("$menuentry_id_option", "--id"):
        if marker in tokens and tokens.index(marker) + 1 < len(tokens):
            entry_id = tokens[tokens.index(marker) + 1]
            break
    if tokens[0] == "submenu":
        submenu = entry_id
    elif (len(tokens) > 1 and f"with Linux {kernel}" in tokens[1]
          and "recovery mode" not in tokens[1] and entry_id):
        if line[:1].isspace() and submenu:
            print(f"{submenu}>{entry_id}")
        else:
            print(entry_id)
        raise SystemExit(0)
raise SystemExit(f"No normal GRUB entry exists for {kernel}.")
PY
}

refresh_boot() {
    local entry temp target
    require_root
    TARGET_KERNEL=$(latest_ga_kernel)
    [[ -n "$TARGET_KERNEL" ]] || die 'Cannot select a boot kernel: no installed Ubuntu 6.8 GA image.'
    # Keep the last working default if the newest GA kernel has a failed DKMS
    # build. A kernel package installation must not silently choose a broken one.
    for target in apple_ib_tb snd_hda_codec_cs8409; do
        temp=$(modinfo -k "$TARGET_KERNEL" -n "$target" 2>/dev/null || true)
        [[ "$temp" == */updates/dkms/* ]] ||
            die "New kernel $TARGET_KERNEL lacks DKMS $target. The previous GRUB default has been kept."
    done
    update-grub
    entry=$(grub_entry_id)
    [[ "$entry" =~ ^[a-zA-Z0-9_.,:+\>-]+$ ]] || die 'Unexpected GRUB entry identifier.'
    write_file /etc/default/grub.d/99-mbp-ubuntu.cfg <<EOF
# Managed by mbp-ubuntu. Security updates to the 6.8 GA series remain enabled.
GRUB_DEFAULT='$entry'
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
EOF
    update-grub
    say "GRUB default selects $TARGET_KERNEL; other kernels remain in Advanced options."
}

load_boot_config() {
    # Parse only the three simple values rather than source a configuration file.
    if [[ -r /etc/mbp-ubuntu.conf ]]; then
        COUNTRY=$(sed -n 's/^COUNTRY=//p' /etc/mbp-ubuntu.conf)
        FNMODE=$(sed -n 's/^FNMODE=//p' /etc/mbp-ubuntu.conf)
        IDLE_TIMEOUT=$(sed -n 's/^IDLE_TIMEOUT=//p' /etc/mbp-ubuntu.conf)
        [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || die 'Invalid saved country.'
    fi
}

rebind_hid() {
    local device parent driver
    [[ "$HID_ID" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}[.][0-9A-Fa-f]{4}$ ]] ||
        die 'Unexpected HID device identifier.'
    device="/sys/bus/hid/devices/$HID_ID"
    [[ -d "$device" ]] || return 0
    # Check the real USB ancestor before writing any binding controls.
    parent=$(readlink -f "$device")
    while [[ "$parent" != / ]]; do
        if [[ -r "$parent/idVendor" && -r "$parent/idProduct" ]]; then break; fi
        parent=$(dirname -- "$parent")
    done
    [[ "$parent" != / && $(< "$parent/idVendor") == 05ac &&
        $(< "$parent/idProduct") == 8600 ]] || return 0
    driver=
    [[ ! -L "$device/driver" ]] || driver=$(readlink -f "$device/driver")
    [[ "${driver##*/}" == apple-ibridge-hid ]] && return 0
    modprobe apple_ibridge
    [[ -d /sys/bus/hid/drivers/apple-ibridge-hid ]] || return 1
    if [[ "${driver##*/}" == hid-sensor-hub ]]; then
        printf '%s' "$HID_ID" > "$driver/unbind"
    elif [[ -n "$driver" ]]; then
        # Do not detach an unrelated custom HID driver.
        return 0
    fi
    printf '%s' "$HID_ID" > /sys/bus/hid/drivers/apple-ibridge-hid/bind
}

initialize_touchbar() {
    local path port found=0 hid failed=0
    for path in intel_lpss_pci spi_pxa2xx_platform applespi apple_ibridge apple_ib_tb apple_ib_als; do
        modprobe "$path" || return 1
    done
    sleep 5
    for path in /sys/bus/usb/devices/*; do
        [[ -r "$path/idVendor" && -r "$path/idProduct" ]] || continue
        [[ $(< "$path/idVendor") == 05ac && $(< "$path/idProduct") == 8600 ]] || continue
        found=1
        port="${path##*/}"
        if [[ -L "$path/driver" ]] &&
            [[ $(readlink -f "$path/driver") == /sys/bus/usb/drivers/usb ]]; then
            if ! printf '%s' "$port" > /sys/bus/usb/drivers/usb/unbind; then
                warn "Could not cycle T1 USB device $port."
                failed=1
                continue
            fi
            sleep 1
            # Always bind the same identified Apple USB device back.
            if ! printf '%s' "$port" > /sys/bus/usb/drivers/usb/bind; then
                warn "Could not rebind T1 USB device $port."
                failed=1
            fi
        fi
    done
    (( found )) || { warn 'T1 USB 05ac:8600 is absent; Apple EFI/T1 firmware may need repair in macOS.'; return 1; }
    sleep 2
    # Resolve the upstream SPI initialization race before the display manager.
    if modprobe -r applespi; then
        modprobe applespi || failed=1
    else
        warn 'applespi is busy; its reload was skipped.'
    fi
    for hid in /sys/bus/hid/devices/*; do
        [[ -r "$hid/uevent" ]] || continue
        grep -q '^HID_PHYS=.*/input3$' "$hid/uevent" || continue
        HID_ID="${hid##*/}"
        rebind_hid || failed=1
    done
    return "$failed"
}

apply_wifi_runtime() {
    local path iface
    if command -v iw >/dev/null; then
        iw reg set "$COUNTRY" || warn 'The Wi-Fi driver rejected the local regulatory-domain request.'
        for path in /sys/class/net/*; do
            [[ -d "$path/phy80211" ]] || continue
            iface="${path##*/}"
            iw dev "$iface" set power_save off ||
                warn "Could not disable power saving for $iface."
        done
    fi
}

initialize_brightness() {
    local path current maximum tool
    systemctl unmask systemd-backlight@.service
    tool=/usr/lib/systemd/systemd-backlight
    [[ -x "$tool" ]] || tool=/lib/systemd/systemd-backlight
    for path in /sys/class/backlight/*; do
        [[ -r "$path/brightness" && -r "$path/max_brightness" ]] || continue
        current=$(< "$path/brightness"); maximum=$(< "$path/max_brightness")
        [[ "$current" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ ]] || continue
        # Preserve a sensible current setting; only recover a nearly dark panel.
        if (( maximum > 0 && current * 100 < maximum * 10 )); then
            printf '%s\n' "$((maximum * 68 / 100))" > "$path/brightness"
        fi
        if [[ -x "$tool" ]]; then
            "$tool" save "backlight:${path##*/}" || warn "Could not save ${path##*/} brightness."
        fi
    done
}

boot_hardware() {
    local failed=0 module
    require_root
    require_platform
    [[ $(uname -r) == 6.8.0-*-generic ]] || die 'Boot the configured Ubuntu 6.8 GA kernel.'
    load_boot_config
    # Do not short-circuit Wi-Fi/backlight setup if Touch Bar initialization fails.
    initialize_touchbar || failed=1
    for module in hci_uart btbcm btusb uvcvideo; do
        modprobe "$module" || warn "Module $module could not be loaded."
    done
    apply_wifi_runtime
    initialize_brightness
    if (( failed )); then
        warn 'Touch Bar initialization needs attention; other hardware setup was applied.'
        return 1
    fi
    say 'Boot hardware initialization completed; use --check to inspect live drivers.'
}

set_gpu_mode() {
    local path driver found=0
    require_root
    read_model
    [[ "$MODEL" == MacBookPro13,3 || "$MODEL" == MacBookPro14,3 ]] ||
        die "Unsupported hardware: $MODEL"
    [[ "$GPU_MODE" == auto || "$GPU_MODE" == low || "$GPU_MODE" == high ]] ||
        die '--gpu-mode needs auto, low or high.'
    for path in /sys/class/drm/card[0-9]*; do
        [[ "${path##*/}" =~ ^card[0-9]+$ && -e "$path/device/power_dpm_force_performance_level" ]] || continue
        driver=$(readlink -f "$path/device/driver" 2>/dev/null || true)
        [[ "${driver##*/}" == amdgpu ]] || continue
        printf '%s\n' "$GPU_MODE" > "$path/device/power_dpm_force_performance_level"
        say "${path##*/}: $(< "$path/device/power_dpm_force_performance_level")"
        found=1
    done
    (( found )) || die 'No AMD GPU with runtime power control was detected.'
    say 'This choice lasts until reboot; auto is the normal driver-managed mode.'
}

check_hardware() {
    local failed=0 kernel module path hid_count=0 bt=0 audio=0 wifi=0 gpu=0 backlight=0
    read_model
    printf 'mbp-ubuntu %s live hardware report\n' "$VERSION"
    printf 'Model: %s\nKernel: %s\n\n' "$MODEL" "$(uname -r)"
    [[ "$MODEL" == MacBookPro13,3 || "$MODEL" == MacBookPro14,3 ]] ||
        { warn 'This machine is not a supported A1707.'; return 2; }
    kernel=$(uname -r)
    [[ "$kernel" == 6.8.0-*-generic ]] || { warn 'Not running the configured 6.8 GA kernel.'; failed=1; }
    if command -v dkms >/dev/null; then dkms status; else warn 'DKMS is missing.'; failed=1; fi
    for module in applespi apple_ibridge apple_ib_tb apple_ib_als brcmfmac snd_hda_codec_cs8409 amdgpu; do
        if [[ -d "/sys/module/$module" ]]; then
            printf 'PASS module: %s\n' "$module"
        else
            printf 'FAIL module: %s is not loaded\n' "$module"
            failed=1
        fi
    done
    if command -v modinfo >/dev/null; then
        for module in apple_ibridge apple_ib_tb apple_ib_als snd_hda_codec_cs8409; do
            path=$(modinfo -k "$kernel" -n "$module" 2>/dev/null || true)
            printf 'Module path [%s]: %s\n' "$module" "${path:-missing}"
            [[ "$path" == */updates/dkms/* ]] || failed=1
        done
    else failed=1; fi
    for path in /sys/bus/hid/devices/*; do
        [[ "${path##*/}" == *:05AC:8600.* ]] || continue
        module=$(readlink -f "$path/driver" 2>/dev/null || true)
        printf 'T1 HID %s: %s\n' "${path##*/}" "${module##*/}"
        [[ "${module##*/}" == apple-ibridge-hid ]] && hid_count=$((hid_count+1))
    done
    (( hid_count >= 2 )) || { warn 'Both T1 HID interfaces are not bound to apple-ibridge-hid.'; failed=1; }
    for path in /sys/class/net/*; do
        [[ -d "$path/phy80211" ]] || continue
        printf 'Wi-Fi interface: %s\n' "${path##*/}"; wifi=1
        if command -v iw >/dev/null; then
            iw dev "${path##*/}" get power_save || true
            iw dev "${path##*/}" link || true
        fi
    done
    (( wifi )) || { warn 'No Wi-Fi interface was detected.'; failed=1; }
    for path in /sys/class/bluetooth/hci*; do
        printf 'Bluetooth controller: %s\n' "${path##*/}"; bt=1
    done
    (( bt )) || { warn 'No Bluetooth controller was detected.'; failed=1; }
    for path in /proc/asound/card*/codec*; do
        if grep -qi 'CS8409' "$path"; then
            printf 'Cirrus codec: %s\n' "$path"; audio=1
        fi
    done
    (( audio )) || { warn 'No active Cirrus CS8409 codec was detected.'; failed=1; }
    for path in /sys/class/drm/card[0-9]*; do
        [[ "${path##*/}" =~ ^card[0-9]+$ ]] || continue
        module=$(readlink -f "$path/device/driver" 2>/dev/null || true)
        if [[ "${module##*/}" == amdgpu ]]; then
            printf 'AMD GPU: %s\n' "${path##*/}"; gpu=1
        fi
    done
    (( gpu )) || { warn 'AMD graphics driver was not detected.'; failed=1; }
    for path in /sys/class/backlight/*; do
        printf 'Backlight: %s\n' "${path##*/}"; backlight=1
    done
    (( backlight )) || { warn 'No backlight control was detected.'; failed=1; }
    if command -v v4l2-ctl >/dev/null; then v4l2-ctl --list-devices || true; fi
    if [[ -d /sys/class/video4linux ]]; then
        for path in /sys/class/video4linux/*; do
            printf 'Video device: %s\n' "${path##*/}"
        done
    fi
    printf '\n'
    if systemctl is-active --quiet mbp-ubuntu-hardware.service; then
        printf 'PASS boot initialization service\n'
    else
        warn 'The boot initialization service is not active.'
        failed=1
    fi
    printf '\nTouch ID: unsupported. Suspend/resume: requires physical testing.\n'
    printf 'Verify visible Touch Bar keys, Wi-Fi connection, quiet speaker playback and mic recording.\n'
    printf 'Driver presence cannot prove those hardware behaviours.\n'
    if (( failed )); then
        printf 'RESULT: ATTENTION REQUIRED; inspect journalctl -b -u mbp-ubuntu-hardware.service\n'
    else
        printf 'RESULT: driver and hardware enumeration checks passed.\n'
    fi
    return "$failed"
}

uninstall_setup() {
    local name path index files=() kernel
    require_root
    require_platform
    [[ -f "$STATE/managed-files.list" ]] || die 'No managed installation or backup manifest was found.'
    setup_state
    say 'Removing managed DKMS modules and restoring the original configuration.'
    systemctl disable --now mbp-ubuntu-hardware.service 2>/dev/null || true
    for name in "$T1_NAME" "$AUDIO_NAME"; do
        if command -v dkms >/dev/null &&
            [[ -n $(dkms status -m "$name" -v "$DRIVER_VERSION" 2>/dev/null) ]]; then
            dkms remove -m "$name" -v "$DRIVER_VERSION" --all
        fi
        path=$(source_dir "$name")
        if [[ ! -L "$path" && -f "$path/.mbp-ubuntu-owned" ]]; then
            rm -rf -- "$path"
        fi
    done
    mapfile -t files < "$STATE/managed-files.list"
    install -d -m 0700 "$STATE/before-uninstall"
    for ((index=${#files[@]}-1; index>=0; index--)); do
        path="${files[index]}"
        [[ "$path" == /* && "$path" != / ]] || die 'Invalid backup manifest path.'
        # Preserve the current file too, including later user edits.
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p -- "$(dirname -- "$STATE/before-uninstall$path")"
            cp -a -- "$path" "$STATE/before-uninstall$path"
        fi
        if [[ -f "$STATE/absent-files.list" ]] &&
            grep -Fxq -- "$path" "$STATE/absent-files.list"; then
            rm -f -- "$path"
        elif [[ -e "$STATE/backups$path" || -L "$STATE/backups$path" ]]; then
            rm -f -- "$path"
            cp -a -- "$STATE/backups$path" "$path"
        else
            die "Backup missing for $path; refusing to discard it."
        fi
    done
    systemctl daemon-reload
    restore_services
    udevadm control --reload-rules
    for kernel in /boot/vmlinuz-6.8.0-*-generic; do
        kernel="${kernel##*/vmlinuz-}"
        depmod -a "$kernel"
        update-initramfs -u -k "$kernel"
    done
    update-grub
    mv -- "$STATE/managed-files.list" "$STATE/uninstalled-files-$(date -u +%Y%m%dT%H%M%SZ).list"
    [[ ! -f "$STATE/absent-files.list" ]] ||
        mv -- "$STATE/absent-files.list" "$STATE/uninstalled-absent-$(date -u +%Y%m%dT%H%M%SZ).list"
    [[ ! -f "$STATE/service-states.tsv" ]] ||
        mv -- "$STATE/service-states.tsv" "$STATE/uninstalled-services-$(date -u +%Y%m%dT%H%M%SZ).tsv"
    say 'Restored. Reboot to unload the custom drivers. Ubuntu packages and all kernels were retained.'
}

install_setup() {
    local source
    preflight
    setup_state
    trap 'on_error "$?" "$LINENO"' ERR
    remember_services
    source=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f "$source" ]] || die 'Save this installer to a file before running it.'
    if [[ "$source" != "$INSTALLED" ]]; then
        write_file "$INSTALLED" 0755 < "$source"
    fi
    install_packages
    check_secure_boot
    install_drivers
    install_nvram
    install_config
    say 'Updating the target kernel initramfs.'
    update-initramfs -u -k "$TARGET_KERNEL"
    refresh_boot
    # Make runtime Wi-Fi more stable without cycling the active network card.
    apply_wifi_runtime
    printf 'configured\n' > "$STATE/install-status"
    say 'Installation completed. Reboot to load the configured kernel and drivers.'
    say 'After reboot: sudo mbp-ubuntu --check'
    say 'GPU control: sudo mbp-ubuntu --gpu-mode low (or auto / high)'
    say 'Restore: sudo mbp-ubuntu --uninstall'
    say 'A built driver is not a hardware test; check the real Touch Bar, Wi-Fi and audio after reboot.'
    if (( DO_REBOOT )); then
        sync
        systemctl reboot
    fi
}

main() {
    parse_args "$@"
    case "$ACTION" in
        install) install_setup ;;
        check) check_hardware ;;
        uninstall) uninstall_setup ;;
        boot) boot_hardware ;;
        refresh-boot) refresh_boot ;;
        rebind-hid) require_root; rebind_hid ;;
        gpu-mode) set_gpu_mode ;;
        *) die 'Invalid action.' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
