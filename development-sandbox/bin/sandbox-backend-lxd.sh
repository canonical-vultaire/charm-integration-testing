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
    local target
    target=$(_sandbox_lxd_target "$1")
    echo "==> Checking LXD VM ubuntu identity against host UID:GID $2:$3..."
    lxc exec "$target" -- bash -c '
set -euo pipefail
host_uid=$1
host_gid=$2
if [[ ! "$host_uid" =~ ^[1-9][0-9]*$ || ! "$host_gid" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LXD checkout sharing requires non-root host UID and GID values." >&2
    exit 1
fi

identity_file=/var/lib/charm-integration-testing/sandbox-host-identity
identity="$host_uid:$host_gid"
if [[ -f "$identity_file" ]]; then
    current_identity=$(cat "$identity_file")
    if [[ "$current_identity" != "$identity" ]]; then
        echo "ERROR: this LXD sandbox is configured for host UID:GID $current_identity, not $identity." >&2
        echo "       Use a different SANDBOX_VM or recreate this VM for the current host user." >&2
        exit 1
    fi
    if [[ "$(id -u ubuntu):$(id -g ubuntu)" != "$identity" ]]; then
        echo "ERROR: the LXD sandbox user no longer matches its recorded host UID:GID $identity." >&2
        exit 1
    fi
    exit 0
fi

uid_entry=$(getent passwd "$host_uid" || true)
if [[ -n "$uid_entry" && "${uid_entry%%:*}" != ubuntu ]]; then
    echo "ERROR: host UID $host_uid belongs to ${uid_entry%%:*} in the LXD VM; cannot align ubuntu." >&2
    exit 1
fi

if ! getent group "$host_gid" >/dev/null; then
    group_name="sandbox-host-$host_gid"
    while getent group "$group_name" >/dev/null; do
        group_name="${group_name}-shared"
    done
    groupadd --gid "$host_gid" "$group_name"
fi

if [[ "$(id -u ubuntu)" != "$host_uid" ]]; then
    usermod --uid "$host_uid" ubuntu
fi
if [[ "$(id -g ubuntu)" != "$host_gid" ]]; then
    usermod --gid "$host_gid" ubuntu
fi

install -d -m 755 /var/lib/charm-integration-testing
printf "%s\n" "$identity" > "$identity_file.tmp"
chmod 600 "$identity_file.tmp"
mv "$identity_file.tmp" "$identity_file"
' bash "$2" "$3"
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
