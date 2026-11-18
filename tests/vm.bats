#!/usr/bin/env bats
# tests/vm.bats: tests for the tests/vm/vm.sh harness (no QEMU needed).

setup() {
	VM="$BATS_TEST_DIRNAME/vm/vm.sh"
	export VM_DIR="$BATS_TEST_TMPDIR/vm"
}

@test "help prints usage and exits 0" {
	run "$VM" help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: vm.sh"* ]]
}

@test "no command fails with usage" {
	run "$VM"
	[ "$status" -eq 1 ]
	[[ $output == *"Usage: vm.sh"* ]]
}

@test "unknown command fails" {
	run "$VM" bogus
	[ "$status" -eq 1 ]
	[[ $output == *"unknown command: bogus"* ]]
}

@test "snapshot rejects unsafe names" {
	mkdir -p "$VM_DIR"
	run "$VM" snapshot save 'bad name;rm'
	[ "$status" -eq 1 ]
	[[ $output == *"snapshot names"* ]]
}

@test "ssh refuses when the VM is not running" {
	run "$VM" ssh true
	[ "$status" -eq 1 ]
}

@test "invalid VM_DISPLAY is rejected" {
	VM_DISPLAY=bogus run bash -c 'source <(sed "/^main \"\$@\"$/d" "$0"); display_args' "$VM"
	[ "$status" -eq 1 ]
	[[ $output == *"VM_DISPLAY must be"* ]]
}
