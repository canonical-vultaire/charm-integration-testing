#!/usr/bin/env bash

sandbox_backend_check() {
    command -v multipass >/dev/null || {
        echo "ERROR: Multipass is required for SANDBOX_BACKEND=multipass." >&2
        return 1
    }
}

sandbox_backend_state() {
    multipass info "$1" --format json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['info'][sys.argv[1]]['state'])" "$1" 2>/dev/null \
        || echo "absent"
}

sandbox_backend_is_mounted() {
    multipass info "$1" --format json 2>/dev/null \
        | python3 -c "import sys,json; mounts=json.load(sys.stdin)['info'][sys.argv[1]].get('mounts',{}); exit(0 if sys.argv[2] in mounts else 1)" "$1" "$3" 2>/dev/null
}

sandbox_backend_check_mount_writable() {
    sandbox_backend_exec "$1" test -w "$2"
}

sandbox_backend_launch() {
    local name=$1 cpus=$2 memory=$3 disk=$4
    multipass launch 24.04 \
        --name "$name" \
        --cpus "$cpus" \
        --memory "$memory" \
        --disk "$disk" \
        --timeout 1800
}

sandbox_backend_start() {
    multipass start "$1"
}

sandbox_backend_stop() {
    multipass stop "$1"
}

sandbox_backend_wait_ready() {
    :
}

sandbox_backend_prepare_user() {
    :
}

sandbox_backend_delete() {
    multipass delete "$1"
    multipass purge
}

sandbox_backend_mount() {
    multipass mount "$2" "$1:$3"
}

sandbox_backend_exec() {
    local name=$1
    shift
    multipass exec "$name" -- "$@"
}
