#!/bin/sh
# container_engine.sh
# Detect whether podman is available and prefer it; fall back to docker.
# Scripts can source this file to get the shell variable: DOCKER_CMD

if command -v podman >/dev/null 2>&1; then
    DOCKER_CMD=podman
    # Friendly defaults for rootless podman:
    #  - Keep the current user ID mapped inside the container so mounted host files remain accessible
    #  - When SELinux is enforcing, append :Z to mounts to give the container proper SELinux labels
    DOCKER_RUN_EX_ARGS="--userns=keep-id"
    # When using podman we usually want the container to run as root *inside* the
    # container namespace so builds behave the same as docker. Export an extra
    # argument that scripts can append to their `run` commands. Leave it empty
    # for docker so behavior is unchanged.
    DOCKER_RUN_AS_ROOT_ARGS="--user 0"
    DOCKER_VOLUME_OPT=""
    if command -v getenforce >/dev/null 2>&1; then
        if [ "$(getenforce)" = "Enforcing" ]; then
            DOCKER_VOLUME_OPT=":Z"
        fi
    fi
elif command -v docker >/dev/null 2>&1; then
    DOCKER_CMD=docker
    DOCKER_RUN_EX_ARGS=""
    DOCKER_RUN_AS_ROOT_ARGS=""
    DOCKER_VOLUME_OPT=""
else
    echo "[error]: Neither 'podman' nor 'docker' found in PATH. Please install one of them." >&2
    exit 1
fi

export DOCKER_CMD
export DOCKER_RUN_EX_ARGS
export DOCKER_VOLUME_OPT

# Export podman-only run-as-root args (may be empty for docker)
export DOCKER_RUN_AS_ROOT_ARGS

# For compatibility, also export DOCKER variable which some scripts may expect
DOCKER="$DOCKER_CMD"
export DOCKER
