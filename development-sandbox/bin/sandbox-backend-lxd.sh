#!/usr/bin/env bash

_sandbox_lxd_remote="${SANDBOX_LXD_REMOTE:-local}"

_sandbox_lxd_target() {
    printf '%s:%s' "$_sandbox_lxd_remote" "$1"
}

_sandbox_lxd_device_name() {
    local mount_hash
    mount_hash=$(printf '%s' "$1" | sha256sum)
    printf 'sandbox-project-%s' "${mount_hash:0:12}"
}

_sandbox_lxd_size() {
    if [[ "$1" =~ ^([0-9]+)([KMGTPE])$ ]]; then
        printf '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}iB"
    else
        printf '%s' "$1"
    fi
}

_sandbox_lxd_instance_type() {
    lxc list "$_sandbox_lxd_remote:" --format=json 2>/dev/null \
        | python3 -c '
import json, sys
name = sys.argv[1]
instances = json.load(sys.stdin)
instance = next((item for item in instances if item["name"] == name), None)
print(instance["type"] if instance else "absent")
' "$1" 2>/dev/null
}

sandbox_backend_check() {
    command -v lxc >/dev/null || {
        echo "ERROR: the LXD client (lxc) is required for SANDBOX_BACKEND=lxd." >&2
        return 1
    }
    if ! lxc info "$_sandbox_lxd_remote:" >/dev/null 2>&1; then
        echo "ERROR: cannot connect to LXD remote '$_sandbox_lxd_remote'. Initialize LXD and ensure your user can access it." >&2
        return 1
    fi
    local instance_type
    instance_type=$(_sandbox_lxd_instance_type "$1") || return 1
    if [[ "$instance_type" != absent && "$instance_type" != virtual-machine ]]; then
        echo "ERROR: LXD instance '$1' exists but is not a VM; refusing to manage it as the sandbox." >&2
        return 1
    fi
}

sandbox_backend_state() {
    lxc list "$_sandbox_lxd_remote:" --format=json 2>/dev/null \
        | python3 -c '
import json, sys
name = sys.argv[1]
instances = json.load(sys.stdin)
instance = next((item for item in instances if item["name"] == name and item["type"] == "virtual-machine"), None)
print(instance["status"] if instance else "absent")
' "$1" 2>/dev/null \
        || echo "absent"
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

sandbox_backend_launch() {
    local target
    target=$(_sandbox_lxd_target "$1")
    lxc launch ubuntu:24.04 "$target" \
        --vm \
        --config "limits.cpu=$2" \
        --config "limits.memory=$(_sandbox_lxd_size "$3")" \
        --device "root,size=$(_sandbox_lxd_size "$4")"
    lxc exec "$target" -- cloud-init status --wait
}

sandbox_backend_start() {
    lxc start "$(_sandbox_lxd_target "$1")"
}

sandbox_backend_stop() {
    lxc stop "$(_sandbox_lxd_target "$1")"
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
