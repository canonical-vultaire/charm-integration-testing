#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/sandbox-backend-lxd-common.sh"

sandbox_backend_instance_type() {
    printf 'container\n'
}

sandbox_backend_check() {
    _sandbox_lxd_check_instance "$1" container
}

sandbox_backend_state() {
    _sandbox_lxd_state "$1" container
}

sandbox_backend_is_mounted() {
    local target device source path shift
    target=$(_sandbox_lxd_target "$1")
    device=$(_sandbox_lxd_device_name "$3")
    source=$(lxc config device get "$target" "$device" source 2>/dev/null) || return 1
    path=$(lxc config device get "$target" "$device" path 2>/dev/null) || return 1
    shift=$(lxc config device get "$target" "$device" shift 2>/dev/null) || return 1
    [[ "$source" == "$2" && "$path" == "$3" && "$shift" == true ]]
}

sandbox_backend_check_mount_writable() {
    sandbox_backend_exec "$1" test -w "$2"
}

sandbox_backend_launch() {
    local target
    target=$(_sandbox_lxd_target "$1")
    lxc launch ubuntu:24.04 "$target" \
        --config security.privileged=false \
        --config security.nesting=false \
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
    local target
    target=$(_sandbox_lxd_target "$1")
    lxc exec "$target" -- bash -c '
        set -euo pipefail
        if command -v cloud-init >/dev/null 2>&1; then
            cloud-init status --wait
        fi
    '
}

sandbox_backend_prepare_user() {
    local target
    target=$(_sandbox_lxd_target "$1")
    lxc exec "$target" -- bash -c '
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1 || ! command -v snap >/dev/null 2>&1; then
    apt-get update --quiet
    apt-get install --assume-yes --quiet sudo snapd
fi

if ! id ubuntu >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group ubuntu
fi
usermod --append --groups sudo ubuntu
'
    _sandbox_lxd_prepare_ubuntu_ids "$1" "$2" "$3"
    lxc exec "$target" -- bash -c '
set -euo pipefail
home_group=$(id -gn ubuntu)
install -d -m 755 -o ubuntu -g "$home_group" /home/ubuntu
chown -R ubuntu:"$home_group" /home/ubuntu
printf "ubuntu ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/90-sandbox-ubuntu
chmod 0440 /etc/sudoers.d/90-sandbox-ubuntu
visudo -c -f /etc/sudoers.d/90-sandbox-ubuntu
'
}

sandbox_backend_delete() {
    lxc delete --force "$(_sandbox_lxd_target "$1")"
}

sandbox_backend_mount() {
    local target device current_source current_path current_shift
    target=$(_sandbox_lxd_target "$1")
    device=$(_sandbox_lxd_device_name "$3")
    if current_source=$(lxc config device get "$target" "$device" source 2>/dev/null); then
        current_path=$(lxc config device get "$target" "$device" path 2>/dev/null) || return 1
        if [[ "$current_source" != "$2" || "$current_path" != "$3" ]]; then
            echo "ERROR: LXD mount device '$device' already exists with a different source or path." >&2
            return 1
        fi
        current_shift=$(lxc config device get "$target" "$device" shift 2>/dev/null || true)
        if [[ "$current_shift" != true ]]; then
            if ! lxc config device set "$target" "$device" shift true; then
                echo "ERROR: the LXD host cannot enable UID/GID shifting for project mount '$3'." >&2
                return 1
            fi
        fi
        return 0
    fi
    if ! lxc config device add "$target" "$device" disk source="$2" path="$3" shift=true; then
        echo "ERROR: the LXD host cannot create a shifted project mount; its kernel and filesystem must support UID/GID shifting." >&2
        return 1
    fi
}

sandbox_backend_exec() {
    local target
    target=$(_sandbox_lxd_target "$1")
    shift
    lxc exec "$target" -- runuser --user ubuntu -- env HOME=/home/ubuntu \
        bash -c 'cd "$HOME" && exec "$@"' bash "$@"
}
