#!/usr/bin/env bash
# image/build-iso.sh: build the Ubuntu Ostrich installer image (write it to a USB stick and boot).
#
#   image/build-iso.sh [--tools DIR] [--out FILE] [--portable] [--unattended-test]
#
# It is Ubuntu 26.04's own installer, unchanged: the person picks the language, keyboard, the disk
# and creates their account exactly as usual. The image adds:
#   /ostrich/            this repo at HEAD and a release build (tools + extensions + SHA256SUMS)
#   /autoinstall.yaml    every installer page stays interactive; after the install, late-commands
#                        copy /ostrich to /opt/ubuntu-ostrich and add a first-login finish
# At the first login a terminal opens ("Finishing Ubuntu Ostrich setup") and runs the same
# installer as the one-line command, from /opt/ubuntu-ostrich (only Ubuntu packages download).
#
# --portable is for installing onto a USB drive with image/to-usb.sh: the drive then boots on any
# PC from its boot menu without adding a boot entry to that PC's firmware (image/portable-esp.sh).
#
# --unattended-test answers every installer page (throwaway user, whole disk) for the VM test.
# NEVER write an --unattended-test image to a USB stick: it erases the first disk without asking.
#
# The base ISO is downloaded and verified by tests/vm/vm.sh fetch (Ubuntu's signed SHA256SUMS).
# --tools defaults to the VM build cache ($VM_DIR/tools-bin, from tests/vm/build-tools.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROJECT="ubuntu-ostrich"
VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
BASE_ISO="$VM_DIR/ubuntu-26.04.1-desktop-amd64.iso"
TOOLS="$VM_DIR/tools-bin"
OUT="$ROOT/dist/ubuntu-ostrich-26.04-amd64.iso"
UNATTENDED=0
PORTABLE=0
REPO_HTTPS="https://github.com/thehamandbread/ubuntu-ostrich.git"

die() {
	echo "build-iso: $*" >&2
	exit 1
}
while (($# > 0)); do
	case $1 in
	--tools) TOOLS=$2 && shift ;;
	--out) OUT=$2 && shift ;;
	--portable) PORTABLE=1 ;;
	--unattended-test) UNATTENDED=1 ;;
	*) die "usage: image/build-iso.sh [--tools DIR] [--out FILE] [--portable] [--unattended-test]" ;;
	esac
	shift
done
for c in xorriso git sha256sum; do command -v "$c" >/dev/null || die "$c not found"; done
[[ -x $TOOLS/ostrich ]] || die "no tool binaries in $TOOLS (run tests/vm/build-tools.sh)"
"$ROOT/tests/vm/vm.sh" fetch >&2 # verifies the signature and checksum (downloads if missing)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pay="$work/ostrich"
mkdir -p "$pay"

# The repo at HEAD, with GitHub as its origin so `ostrich update` works later.
branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
git clone --quiet --depth 1 --branch "$branch" "file://$ROOT" "$pay/src"
git -C "$pay/src" remote set-url origin "$REPO_HTTPS"
# The release the tools module installs from (RELEASE_URL=file:///opt/ubuntu-ostrich/release).
DIST="$work/zips" "$ROOT/modules/gnome/extensions/build.sh" >/dev/null
"$ROOT/tools/package.sh" "$TOOLS" "$work/zips" "$pay/release" >&2
cp -r "$HERE/firstboot" "$pay/firstboot"

late='late-commands:
  - cp -a /cdrom/ostrich /target/opt/ubuntu-ostrich
  - chmod -R a+rX /target/opt/ubuntu-ostrich
  - install -D -m 644 /cdrom/ostrich/firstboot/ostrich-firstboot.desktop /target/etc/xdg/autostart/ostrich-firstboot.desktop'
((PORTABLE)) && late+='
  - install -D -m 755 /cdrom/ostrich/src/image/portable-esp.sh /target/usr/local/sbin/ubuntu-ostrich-portable-esp
  - install -D -m 644 /cdrom/ostrich/src/image/portable-apt.conf /target/etc/apt/apt.conf.d/99ubuntu-ostrich-portable
  - /target/usr/local/sbin/ubuntu-ostrich-portable-esp /target'
if ((UNATTENDED)); then
	# VM test only: the same answers tests/vm/vm.sh gives, plus the late-commands above.
	pw=$(openssl passwd -6 -stdin <"$VM_DIR/password")
	cat >"$work/autoinstall.yaml" <<EOF
version: 1
interactive-sections: []
locale: en_US.UTF-8
keyboard: {layout: us}
identity: {hostname: ost-image-test, username: tester, realname: Test User, password: '$pw'}
ssh:
  install-server: true
  allow-pw: false
  authorized-keys:
    - $(cat "$VM_DIR/id_ed25519.pub")
storage: {layout: {name: direct}}
$late
  - echo 'tester ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-test-vm
  # Some networks intercept plain-HTTP apt; the archive is signed either way (as in e2e.sh).
  - sed -i 's|http://|https://|g' /target/etc/apt/sources.list.d/ubuntu.sources
  - printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=tester\n' > /target/etc/gdm3/custom.conf
shutdown: poweroff
EOF
else
	# Every page is the person's choice, including the disk: nothing is erased without it.
	cat >"$work/autoinstall.yaml" <<EOF
version: 1
interactive-sections: ['*']
$late
EOF
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -indev "$BASE_ISO" -outdev "$OUT" \
	-map "$pay" /ostrich \
	-map "$work/autoinstall.yaml" /autoinstall.yaml \
	-boot_image any replay 2>"$work/xorriso.log" || {
	cat "$work/xorriso.log" >&2
	die "xorriso failed"
}
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" >"$(basename "$OUT").sha256")
echo "built $OUT ($(du -h "$OUT" | cut -f1)); checksum in $OUT.sha256"
((PORTABLE)) && echo "  (portable: install it onto a USB drive with image/to-usb.sh)"
((UNATTENDED)) && echo "  (UNATTENDED TEST IMAGE: erases the first disk; VM use only)"
true
