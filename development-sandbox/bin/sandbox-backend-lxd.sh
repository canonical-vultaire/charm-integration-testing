#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/sandbox-backend-lxd-common.sh"

sandbox_backend_instance_type() {
    printf 'vm\n'
}

sandbox_backend_check() {
    _sandbox_lxd_check_instance "$1" virtual-machine
}

sandbox_backend_state() {
    _sandbox_lxd_state "$1" virtual-machine
}

sandbox_backend_is_mounted() {
    local target
    target=$(_sandbox_lxd_target "$1")
    local device source path
    device=$(_sandbox_lxd_device_name "$3")
    source=$(lxc config device get "$target" "$device" source 2>/dev/null) || return 1
    path=$(lxc config device get "$target" "$device" path 2>/dev/null) || return 1
    [[ "$source" == "$2" && "$path" == "$3" ]]
}

sandbox_backend_check_mount_writable() {
    sandbox_backend_exec "$1" test -w "$2"
}

sandbox_backend_launch() {
    local target
    target=$(_sandbox_lxd_target "$1")
    lxc launch ubuntu:24.04 "$target" \
        --vm \
        --config "limits.cpu=$2" \
        --config "limits.memory=$(_sandbox_lxd_size "$3")" \
        --device "root,size=$(_sandbox_lxd_size "$4")"
}

sandbox_backend_start() {
    lxc start "$(_sandbox_lxd_target "$1")"
}

sandbox_backend_stop() {
    lxc stop "$(_sandbox_lxd_target "$1")"
}

sandbox_backend_wait_ready() {
    local target start timeout=300
    target=$(_sandbox_lxd_target "$1")
    start=$SECONDS
    echo "==> Waiting for LXD VM agent..."
    # LXD can return from launch before its guest agent is ready to accept exec.
    until lxc exec "$target" -- true >/dev/null 2>&1; do
        if (( SECONDS - start >= timeout )); then
            echo "ERROR: LXD VM agent did not become ready within ${timeout}s." >&2
            return 1
        fi
        sleep 2
    done
    echo "==> LXD VM agent is ready."
    lxc exec "$target" -- cloud-init status --wait
}

sandbox_backend_prepare_user() {
    _sandbox_lxd_prepare_ubuntu_ids "$1" "$2" "$3"
}

sandbox_backend_delete() {
    lxc delete --force "$(_sandbox_lxd_target "$1")"
}

sandbox_backend_mount() {
    local target device current_source current_path
    target=$(_sandbox_lxd_target "$1")
    device=$(_sandbox_lxd_device_name "$3")
    if current_source=$(lxc config device get "$target" "$device" source 2>/dev/null); then
        current_path=$(lxc config device get "$target" "$device" path 2>/dev/null) || return 1
        if [[ "$current_source" == "$2" && "$current_path" == "$3" ]]; then
            return 0
        fi
        echo "ERROR: LXD mount device '$device' already exists with a different source or path." >&2
        return 1
    fi
    lxc config device add "$target" "$device" disk source="$2" path="$3"
}

sandbox_backend_exec() {
    local target
    target=$(_sandbox_lxd_target "$1")
    shift
    lxc exec "$target" -- runuser --user ubuntu -- env HOME=/home/ubuntu \
        bash -c 'cd "$HOME" && exec "$@"' bash "$@"
}
