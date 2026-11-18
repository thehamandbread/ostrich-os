#!/usr/bin/env bash
# tests/vm/vm.sh: scripted QEMU/KVM test VM (Ubuntu 26.04 desktop) for pre/post testing.
set -euo pipefail

readonly PROJECT="ubuntu-ostrich"
readonly ISO_RELEASE="26.04"
readonly ISO_NAME="ubuntu-26.04.1-desktop-amd64.iso"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly ISO_BASE_URL="https://releases.ubuntu.com/${ISO_RELEASE}"
# Ubuntu CD Image Automatic Signing Key (2012), shipped in ubuntu-keyring.
readonly CDIMAGE_KEY_FPR="843938DF228D22F7B3742BC0D94AA3F0EFE21092" # gitleaks:allow (public key fingerprint)
readonly UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
readonly OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
readonly OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"

VM_DIR="${VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/vm}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEM="${VM_MEM:-6G}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_USER="${VM_USER:-tester}"
# The guest renders with llvmpipe (software), so GPU work such as blur shows up as CPU time.
# none: headless, fixed VM_WIDTHxVM_HEIGHT (default; used for measurements and screenshots);
# std: a GTK window (the guest follows the window size); gl: virtio-vga-gl (no screenshots).
VM_DISPLAY="${VM_DISPLAY:-none}"
# 1 adds a virtual multitouch screen (for touchscreen-toggle tests).
VM_TOUCH="${VM_TOUCH:-0}"
# VM_OUTPUTS=2 gives the guest a second display (holder-monitor tests). QEMU only connects it
# when it has a window to show it in, so use it with VM_DISPLAY=std.
VM_RES="max_outputs=${VM_OUTPUTS:-1},edid=on,xres=${VM_WIDTH:-1920},yres=${VM_HEIGHT:-1080}"

DISK="$VM_DIR/disk.qcow2"
VARS="$VM_DIR/OVMF_VARS.fd"
SSH_KEY="$VM_DIR/id_ed25519"
KNOWN_HOSTS="$VM_DIR/known_hosts"
PIDFILE="$VM_DIR/qemu.pid"
MONITOR="$VM_DIR/monitor.sock"
QMP="$VM_DIR/qmp.sock"

usage() {
	cat <<EOF
Usage: vm.sh <command> [args]

Scripted test VM. Images live in: $VM_DIR (override with VM_DIR).

Commands:
  check                  Check host prerequisites
  fetch                  Download the Ubuntu $ISO_RELEASE ISO and verify checksum + signature
  create                 Create the VM disk ($VM_DISK_SIZE thin qcow2) and UEFI vars
  install                Unattended install from the ISO (VM-only user and SSH key)
  start                  Boot the VM (SSH on 127.0.0.1:$VM_SSH_PORT)
  stop                   Shut the VM down cleanly
  ssh [cmd...]           Run a command in the VM (interactive shell if none)
  copy <src> <dest>      Copy a host file into the VM
  screenshot <file.png>  Save the VM screen as PNG (works during install too)
  click <x> <y> [right]  Click at screen pixel x,y (works headless, via QMP)
  move <x> <y>           Move the pointer to screen pixel x,y (absolute)
  drag <x1> <y1> <x2> <y2>  Press, move, release (left button)
  scroll <x> <y> up|down [n]  Wheel clicks at screen pixel x,y
  nudge <dx> <dy> [n]    Relative pointer motion, n times (pushes against edge barriers)
  key <combo>...         Send key presses, e.g. key ctrl-alt-t ret
  snapshot save <name>   Save a snapshot (VM must be off)
  snapshot restore <name>
  snapshot list
  snapshot delete <name>
  view <snapshot>        Open a snapshot in a window on your desktop to look around (try it out)
  destroy                Delete the VM disk, vars, keys and seed (keeps the ISO)

Environment: VM_DIR VM_DISK_SIZE VM_CPUS VM_MEM VM_SSH_PORT VM_USER VM_DISPLAY(none|std|gl) VM_WIDTH VM_HEIGHT VM_TOUCH(0|1) VM_AUDIO(0|1)
EOF
}

log() { printf '[vm] %s\n' "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

need() {
	local missing=() c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "missing: ${missing[*]} (run: vm.sh check)"
}

cmd_check() {
	local ok=1 c
	for c in qemu-system-x86_64 qemu-img cloud-localds xorriso gpgv ssh ssh-keygen openssl curl; do
		if command -v "$c" >/dev/null 2>&1; then
			log "ok: $c"
		else
			log "missing: $c"
			ok=0
		fi
	done
	for c in "$OVMF_CODE" "$OVMF_VARS_TEMPLATE" "$UBUNTU_KEYRING"; do
		if [[ -r $c ]]; then log "ok: $c"; else
			log "missing: $c"
			ok=0
		fi
	done
	if [[ -r /dev/kvm && -w /dev/kvm ]]; then log "ok: /dev/kvm"; else
		log "missing: access to /dev/kvm (sudo usermod -aG kvm \$USER, then log out and in)"
		ok=0
	fi
	if ((!ok)); then
		log "install with: sudo apt install qemu-system-x86 qemu-utils ovmf cloud-image-utils xorriso"
		return 1
	fi
	log "all prerequisites present"
}

vm_running() {
	[[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

require_stopped() {
	! vm_running || die "VM is running; run: vm.sh stop"
}

cmd_fetch() {
	need curl gpgv sha256sum
	mkdir -p "$VM_DIR"
	local sums="$VM_DIR/SHA256SUMS"
	curl -fsSL -o "$sums" "$ISO_BASE_URL/SHA256SUMS"
	curl -fsSL -o "$sums.gpg" "$ISO_BASE_URL/SHA256SUMS.gpg"

	local status
	status=$(gpgv --status-fd 1 --keyring "$UBUNTU_KEYRING" "$sums.gpg" "$sums" 2>/dev/null) ||
		die "SHA256SUMS signature did not verify"
	grep -q "VALIDSIG $CDIMAGE_KEY_FPR" <<<"$status" ||
		die "SHA256SUMS is not signed by the Ubuntu CD Image key ($CDIMAGE_KEY_FPR)"
	log "SHA256SUMS signature ok"

	local iso="$VM_DIR/$ISO_NAME"
	if [[ ! -f $iso ]]; then
		log "downloading $ISO_NAME (about 6 GB)"
		curl -fL --continue-at - -o "$iso.part" "$ISO_BASE_URL/$ISO_NAME"
		mv "$iso.part" "$iso"
	fi
	(cd "$VM_DIR" && grep " \*$ISO_NAME\$" SHA256SUMS | sha256sum -c -) ||
		die "ISO checksum mismatch; delete $iso and fetch again"
	log "ISO verified: $iso"
}

cmd_create() {
	need qemu-img
	require_stopped
	[[ -f $DISK ]] && die "disk already exists: $DISK (vm.sh destroy to start over)"
	mkdir -p "$VM_DIR"
	qemu-img create -q -f qcow2 "$DISK" "$VM_DISK_SIZE"
	cp "$OVMF_VARS_TEMPLATE" "$VARS"
	log "created $DISK ($VM_DISK_SIZE, thin)"
}

write_seed() {
	need cloud-localds ssh-keygen openssl
	[[ -f $SSH_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "$PROJECT-test-vm" -f "$SSH_KEY"
	# Throwaway password for the VM-only user (console login / sudo inside the VM).
	local pwfile="$VM_DIR/password" hash
	[[ -f $pwfile ]] || (umask 077 && openssl rand -base64 18 >"$pwfile")
	hash=$(openssl passwd -6 -stdin <"$pwfile")

	local seed_dir="$VM_DIR/seed"
	mkdir -p "$seed_dir"
	cat >"$seed_dir/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []
  locale: en_US.UTF-8
  keyboard: {layout: us}
  identity:
    hostname: ost-test-vm
    username: $VM_USER
    realname: Test User
    password: '$hash'
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - $(cat "$SSH_KEY.pub")
  storage:
    layout: {name: direct}
  packages: [powertop, sysstat]
  late-commands:
    - |
      cat > /target/etc/gdm3/custom.conf <<'GDM'
      [daemon]
      AutomaticLoginEnable=true
      AutomaticLogin=$VM_USER
      GDM
    # No first-login welcome app in the test VM (it would skew measurements).
    - mkdir -p /target/home/$VM_USER/.config/systemd/user
    - ln -sf /dev/null /target/home/$VM_USER/.config/systemd/user/gnome-initial-setup-first-login.service
    - ln -sf /dev/null /target/home/$VM_USER/.config/systemd/user/gnome-initial-setup-upgrade-login.service
    - chroot /target chown -R $VM_USER:$VM_USER /home/$VM_USER/.config
    - echo '$VM_USER ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-test-vm
    - chmod 440 /target/etc/sudoers.d/90-test-vm
  shutdown: poweroff
EOF
	printf 'instance-id: %s-vm\n' "$PROJECT" >"$seed_dir/meta-data"
	cloud-localds "$VM_DIR/seed.img" "$seed_dir/user-data" "$seed_dir/meta-data"
}

display_args() {
	case $VM_DISPLAY in
	gl) printf '%s\n' -device "virtio-vga-gl,$VM_RES" -display gtk,gl=on ;;
	std) printf '%s\n' -device "virtio-vga,$VM_RES" -display gtk ;;
	none) printf '%s\n' -device "virtio-vga,$VM_RES" -display none ;;
	*) die "VM_DISPLAY must be none, std or gl" ;;
	esac
}

qemu_base() {
	local -a disp
	mapfile -t disp < <(display_args)
	((VM_TOUCH)) && disp+=(-device virtio-multitouch-pci)
	# VM_RTC=2026-10-25T08:00:00 starts the guest clock at that time (tests of boots after a time gap).
	[[ -n ${VM_RTC:-} ]] && disp+=(-rtc "base=$VM_RTC")
	# VM_AUDIO=0: a silent sound card (the lab VMs: nothing they play reaches the host speakers).
	local audio=pipewire
	[[ ${VM_AUDIO:-1} == 0 ]] && audio=none
	# The critique inbox (tests/vm/critique.sh): a host folder the VM mounts at ~/critiques, so
	# notes land on the host at once and survive snapshot restores.
	mkdir -p "$VM_DIR/critiques"
	disp+=(-virtfs "local,path=$VM_DIR/critiques,mount_tag=critiques,security_model=none,id=critiques")
	printf '%s\n' \
		-name "$PROJECT-test" \
		-machine q35,accel=kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$VARS" \
		-drive "file=$DISK,if=virtio,format=qcow2,discard=unmap" \
		-nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22" \
		-audiodev "$audio,id=snd" -device intel-hda -device hda-duplex,audiodev=snd \
		-device virtio-tablet-pci \
		-monitor "unix:$MONITOR,server,nowait" \
		-qmp "unix:$QMP,server,nowait" \
		"${disp[@]}"
}

cmd_install() {
	need qemu-system-x86_64 xorriso
	require_stopped
	# VM_ISO: another installer image (the Ostrich image test); VM_SEED=0: no seed disk, so the
	# image's own /autoinstall.yaml answers the installer.
	local iso="${VM_ISO:-$VM_DIR/$ISO_NAME}"
	[[ -f $iso ]] || die "no ISO; run: vm.sh fetch"
	[[ -f $DISK ]] || die "no disk; run: vm.sh create"
	local -a seed=()
	if ((${VM_SEED:-1})); then
		write_seed
		seed=(-drive "file=$VM_DIR/seed.img,if=virtio,format=raw,readonly=on")
	fi

	# Direct kernel boot from the ISO so the 'autoinstall' flag skips the confirmation prompt.
	local boot="$VM_DIR/boot"
	mkdir -p "$boot"
	xorriso -osirrox on -indev "$iso" \
		-extract /casper/vmlinuz "$boot/vmlinuz" \
		-extract /casper/initrd "$boot/initrd" 2>/dev/null
	chmod u+w "$boot"/*

	local -a base
	mapfile -t base < <(qemu_base)
	log "installing unattended; the VM powers off when done (20-40 min)"
	qemu-system-x86_64 "${base[@]}" \
		-cdrom "$iso" \
		"${seed[@]}" \
		-kernel "$boot/vmlinuz" -initrd "$boot/initrd" \
		-append "autoinstall --- quiet" \
		-no-reboot
	rm -rf "$boot"
	log "install finished; next: vm.sh snapshot save stock"
}

cmd_start() {
	need qemu-system-x86_64
	vm_running && die "VM is already running"
	[[ -f $DISK ]] || die "no disk; run: vm.sh create && vm.sh install"
	local -a base
	mapfile -t base < <(qemu_base)
	qemu-system-x86_64 "${base[@]}" -daemonize -pidfile "$PIDFILE"
	log "started; waiting for SSH on port $VM_SSH_PORT"
	local i
	for ((i = 0; i < 90; i++)); do
		# Wait for GNOME Shell too: stopping the VM while the shell is still starting crashes it,
		# and after a crash GNOME switches off every user extension (disable-user-extensions).
		if vm_ssh 'gdbus introspect --session --dest org.gnome.Shell --object-path /org/gnome/Shell >/dev/null' 2>/dev/null; then
			log "VM is up"
			return 0
		fi
		sleep 2
	done
	die "SSH or GNOME Shell did not come up within 3 minutes"
}

vm_ssh() {
	ssh -i "$SSH_KEY" -p "$VM_SSH_PORT" \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o ConnectTimeout=5 -o BatchMode=yes \
		"$VM_USER@127.0.0.1" "$@"
}

cmd_ssh() {
	need ssh
	vm_running || die "VM is not running; run: vm.sh start"
	vm_ssh "$@"
}

cmd_copy() {
	(($# == 2)) || die "usage: vm.sh copy <src> <dest>"
	vm_running || die "VM is not running"
	scp -i "$SSH_KEY" -P "$VM_SSH_PORT" -q -r \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
		"$1" "$VM_USER@127.0.0.1:$2"
}

cmd_screenshot() {
	(($# == 1)) || die "usage: vm.sh screenshot <file.png>"
	need socat
	[[ -S $MONITOR ]] || die "no monitor socket; is the VM running?"
	local out
	out=$(realpath -m "$1")
	printf 'screendump %s -f png\n' "$out" | socat -t 3 - "UNIX-CONNECT:$MONITOR" >/dev/null
	local i
	for ((i = 0; i < 10; i++)); do
		[[ -s $out ]] && {
			log "saved $out"
			return 0
		}
		sleep 0.5
	done
	die "screendump failed"
}

# Sends QMP commands (one JSON object per argument) after the capabilities handshake.
qmp() {
	need socat
	[[ -S $QMP ]] || die "no QMP socket; is the VM running?"
	{
		printf '{"execute":"qmp_capabilities"}\n'
		local c
		for c in "$@"; do
			printf '%s\n' "$c"
			sleep 0.05
		done
		sleep 0.2
	} | socat -t 1 - "UNIX-CONNECT:$QMP" >/dev/null
}

cmd_click() {
	(($# >= 2)) || die "usage: vm.sh click <x> <y> [right]"
	local x=$1 y=$2 button=left
	[[ ${3:-} == right ]] && button=right
	[[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]] || die "x and y must be pixel numbers"
	# Absolute axes run 0..32767 across the screen.
	local ax=$((x * 32767 / ${VM_WIDTH:-1920})) ay=$((y * 32767 / ${VM_HEIGHT:-1080}))
	local move btn_down btn_up
	move=$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":%d}},{"type":"abs","data":{"axis":"y","value":%d}}]}}' "$ax" "$ay")
	btn_down=$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"%s","down":true}}]}}' "$button")
	btn_up=$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"%s","down":false}}]}}' "$button")
	qmp "$move" "$btn_down" "$btn_up"
}

# Wheel clicks at a point: QMP sends the wheel as the wheel-up/wheel-down buttons.
cmd_scroll() {
	(($# >= 3)) || die "usage: vm.sh scroll <x> <y> up|down [n]"
	local x=$1 y=$2 dir=$3 n=${4:-1} i events=()
	[[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ && $n =~ ^[0-9]+$ ]] || die "x, y and n must be numbers"
	[[ $dir == up || $dir == down ]] || die "scroll direction is up or down"
	events+=("$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":%d}},{"type":"abs","data":{"axis":"y","value":%d}}]}}' $((x * 32767 / ${VM_WIDTH:-1920})) $((y * 32767 / ${VM_HEIGHT:-1080})))")
	for ((i = 0; i < n; i++)); do
		events+=("$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"wheel-%s","down":true}}]}}' "$dir")")
		events+=("$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"wheel-%s","down":false}}]}}' "$dir")")
	done
	qmp "${events[@]}"
}

# Press at one point, move there in steps, release: a drag (resize grips, sliders).
cmd_drag() {
	(($# == 4)) || die "usage: vm.sh drag <x1> <y1> <x2> <y2>"
	local a
	for a in "$@"; do [[ $a =~ ^[0-9]+$ ]] || die "drag coordinates must be pixel numbers"; done
	local w=${VM_WIDTH:-1920} h=${VM_HEIGHT:-1080} steps=10 i events=()
	abs() { printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":%d}},{"type":"abs","data":{"axis":"y","value":%d}}]}}' $(($1 * 32767 / w)) $(($2 * 32767 / h)); }
	btn() { printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":%s}}]}}' "$1"; }
	events+=("$(abs "$1" "$2")" "$(btn true)")
	for ((i = 1; i <= steps; i++)); do
		events+=("$(abs $(($1 + ($3 - $1) * i / steps)) $(($2 + ($4 - $2) * i / steps)))")
	done
	events+=("$(btn false)")
	qmp "${events[@]}"
}

cmd_move() {
	(($# == 2)) && [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || die "usage: vm.sh move <x> <y>"
	local ax=$(($1 * 32767 / ${VM_WIDTH:-1920})) ay=$(($2 * 32767 / ${VM_HEIGHT:-1080}))
	qmp "$(printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":%d}},{"type":"abs","data":{"axis":"y","value":%d}}]}}' "$ax" "$ay")"
}

# Relative pointer motion from a temporary uinput mouse inside the guest (rel-pointer.py); GNOME's
# pressure barriers react only to relative motion, unlike the absolute tablet.
cmd_nudge() {
	(($# >= 2)) && [[ $1 =~ ^-?[0-9]+$ && $2 =~ ^-?[0-9]+$ ]] || die "usage: vm.sh nudge <dx> <dy> [n]"
	local n=${3:-1}
	[[ $n =~ ^[0-9]+$ ]] || die "usage: vm.sh nudge <dx> <dy> [n]"
	vm_ssh "sudo python3 - $1 $2 $n" <"$HERE/rel-pointer.py"
}

cmd_key() {
	(($# > 0)) || die "usage: vm.sh key <combo>..."
	need socat
	local k
	for k in "$@"; do
		[[ $k =~ ^[a-z0-9_-]+$ ]] || die "bad key: $k"
		printf 'sendkey %s\n' "$k" | socat -t 0.3 - "UNIX-CONNECT:$MONITOR" >/dev/null
		sleep 0.15
	done
}

cmd_stop() {
	vm_running || {
		log "VM is not running"
		return 0
	}
	vm_ssh sudo systemctl poweroff 2>/dev/null || true
	local i
	for ((i = 0; i < 60; i++)); do
		vm_running || {
			rm -f "$PIDFILE"
			log "stopped"
			return 0
		}
		sleep 2
	done
	log "clean shutdown timed out; killing qemu"
	kill "$(cat "$PIDFILE")"
	rm -f "$PIDFILE"
}

# Restore a snapshot and boot it in a window, for a person to use (log in as the test user; the
# password is in $VM_DIR/password). Changes are lost at the next restore.
cmd_view() {
	(($# == 1)) || die "usage: vm.sh view <snapshot>   (see: vm.sh snapshot list)"
	vm_running && cmd_stop
	# The critique tool (Super+Alt+C) goes into the snapshot the first time, and when it changes.
	"$HERE/critique.sh" ensure "$1"
	cmd_snapshot restore "$1"
	# GPU graphics (virgl) by default: without hardware rendering GNOME Shell switches every
	# animation off (main.js, is_rendering_hardware_accelerated), so a review would show none.
	# VM_DISPLAY=std for a host without GL. Critique shots are taken inside the guest, so they work.
	[[ $VM_DISPLAY == none ]] && VM_DISPLAY=gl
	cmd_start
	log "the VM is in a window; close it or run: vm.sh stop"
}

cmd_snapshot() {
	local action=${1:-} name=${2:-}
	case $action in
	list)
		need qemu-img
		qemu-img snapshot -l "$DISK"
		;;
	delete)
		[[ -n $name && $name =~ ^[A-Za-z0-9._-]+$ ]] || die "usage: vm.sh snapshot delete <name>"
		need qemu-img
		require_stopped
		qemu-img snapshot -d "$name" "$DISK"
		rm -f "$VM_DIR/OVMF_VARS.$name.fd"
		log "deleted snapshot: $name"
		;;
	save | restore)
		[[ -n $name ]] || die "usage: vm.sh snapshot $action <name>"
		[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "snapshot names: letters, digits, . _ -"
		need qemu-img
		require_stopped
		if [[ $action == save ]]; then
			qemu-img snapshot -l "$DISK" | awk '{print $2}' | grep -qx "$name" &&
				qemu-img snapshot -d "$name" "$DISK"
			qemu-img snapshot -c "$name" "$DISK"
			cp "$VARS" "$VM_DIR/OVMF_VARS.$name.fd"
			log "saved snapshot: $name"
		else
			qemu-img snapshot -a "$name" "$DISK"
			[[ -f $VM_DIR/OVMF_VARS.$name.fd ]] && cp "$VM_DIR/OVMF_VARS.$name.fd" "$VARS"
			log "restored snapshot: $name"
		fi
		;;
	*) die "usage: vm.sh snapshot save|restore|list [name]" ;;
	esac
}

cmd_destroy() {
	require_stopped
	rm -f "$DISK" "$VARS" "$VM_DIR"/OVMF_VARS.*.fd "$SSH_KEY" "$SSH_KEY.pub" \
		"$KNOWN_HOSTS" "$VM_DIR/password" "$VM_DIR/seed.img"
	rm -rf "$VM_DIR/seed"
	log "destroyed VM (ISO kept)"
}

main() {
	local cmd=${1:-}
	(($# > 0)) && shift
	case $cmd in
	check) cmd_check ;;
	fetch) cmd_fetch ;;
	create) cmd_create ;;
	install) cmd_install ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	ssh) cmd_ssh "$@" ;;
	copy) cmd_copy "$@" ;;
	screenshot) cmd_screenshot "$@" ;;
	click) cmd_click "$@" ;;
	scroll) cmd_scroll "$@" ;;
	move) cmd_move "$@" ;;
	drag) cmd_drag "$@" ;;
	nudge) cmd_nudge "$@" ;;
	key) cmd_key "$@" ;;
	snapshot) cmd_snapshot "$@" ;;
	view) cmd_view "$@" ;;
	destroy) cmd_destroy ;;
	-h | --help | help) usage ;;
	"")
		usage >&2
		exit 1
		;;
	*)
		usage >&2
		die "unknown command: $cmd"
		;;
	esac
}

main "$@"
