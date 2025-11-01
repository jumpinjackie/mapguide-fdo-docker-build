#!/bin/sh
# container_engine.sh
# Detect whether podman is available and prefer it; fall back to docker.
# Scripts can source this file to get the shell variable: DOCKER_CMD

if command -v podman >/dev/null 2>&1; then
    DOCKER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
    DOCKER_CMD=docker
else
    echo "[error]: Neither 'podman' nor 'docker' found in PATH. Please install one of them." >&2
    exit 1
fi

export DOCKER_CMD

# For compatibility, also export DOCKER variable which some scripts may expect
DOCKER="$DOCKER_CMD"
export DOCKER
