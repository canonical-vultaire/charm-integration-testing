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

_sandbox_lxd_state() {
    lxc list "$_sandbox_lxd_remote:" --format=json 2>/dev/null \
        | python3 -c '
import json, sys
name, expected_type = sys.argv[1:]
instances = json.load(sys.stdin)
instance = next(
    (item for item in instances if item["name"] == name and item["type"] == expected_type),
    None,
)
print(instance["status"] if instance else "absent")
' "$1" "$2" 2>/dev/null \
        || echo "absent"
}

_sandbox_lxd_check_instance() {
    local name=$1 expected_type=$2 instance_type
    command -v lxc >/dev/null || {
        echo "ERROR: the LXD client (lxc) is required for this sandbox backend." >&2
        return 1
    }
    if ! lxc info "$_sandbox_lxd_remote:" >/dev/null 2>&1; then
        echo "ERROR: cannot connect to LXD remote '$_sandbox_lxd_remote'. Initialize LXD and ensure your user can access it." >&2
        return 1
    fi
    instance_type=$(_sandbox_lxd_instance_type "$name") || return 1
    if [[ "$instance_type" != absent && "$instance_type" != "$expected_type" ]]; then
        echo "ERROR: LXD instance '$name' is a '$instance_type', not a '$expected_type'; refusing to manage it as the sandbox." >&2
        return 1
    fi
}

_sandbox_lxd_prepare_ubuntu_ids() {
    local target
    target=$(_sandbox_lxd_target "$1")
    echo "==> Matching LXD guest ubuntu UID/GID to host $2:$3..."
    lxc exec "$target" -- bash -c '
set -euo pipefail
host_uid=$1
host_gid=$2
if [[ ! "$host_uid" =~ ^[1-9][0-9]*$ || ! "$host_gid" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LXD checkout sharing requires non-root host UID and GID values." >&2
    exit 1
fi
if ! id ubuntu >/dev/null 2>&1; then
    echo "ERROR: expected an ubuntu account in the LXD instance before UID/GID setup." >&2
    exit 1
fi

identity_file=/var/lib/charm-integration-testing/sandbox-host-identity
identity="$host_uid:$host_gid"
if [[ -f "$identity_file" ]]; then
    current_identity=$(cat "$identity_file")
    if [[ "$current_identity" != "$identity" ]]; then
        echo "ERROR: this LXD sandbox is configured for host UID:GID $current_identity, not $identity." >&2
        echo "       Use a different SANDBOX_VM or recreate this instance for the current host user." >&2
        exit 1
    fi
    if [[ "$(id -u ubuntu):$(id -g ubuntu)" != "$identity" ]]; then
        echo "ERROR: the LXD sandbox user no longer matches its recorded host UID:GID $identity." >&2
        exit 1
    fi
fi

uid_entry=$(getent passwd "$host_uid" || true)
if [[ -n "$uid_entry" && "${uid_entry%%:*}" != ubuntu ]]; then
    echo "ERROR: host UID $host_uid belongs to ${uid_entry%%:*} in the LXD instance; cannot align ubuntu." >&2
    exit 1
fi

if [[ "$(id -u ubuntu)" != "$host_uid" ]]; then
    usermod --uid "$host_uid" ubuntu
fi

ubuntu_gid=$(id -g ubuntu)
if ! getent group "$host_gid" >/dev/null; then
    groupmod --gid "$host_gid" ubuntu
    usermod --gid ubuntu ubuntu
else
    usermod --gid "$host_gid" ubuntu
fi
if [[ "$ubuntu_gid" != "$host_gid" ]]; then
    find /home/ubuntu -xdev -gid "$ubuntu_gid" -exec chgrp -h "$host_gid" {} +
fi

install -d -m 755 /var/lib/charm-integration-testing
printf "%s\n" "$identity" > "$identity_file.tmp"
chmod 600 "$identity_file.tmp"
mv "$identity_file.tmp" "$identity_file"
' bash "$2" "$3"
}
