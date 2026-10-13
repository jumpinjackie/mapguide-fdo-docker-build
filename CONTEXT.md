# CONTEXT

Glossary for the `mapguide-fdo-docker-build` repository. This file defines the shared
language only — it contains no implementation details, specs, or decisions.

## Virtual monorepo

A single git repository that orchestrates the build of two externally-versioned source
trees. Unlike a conventional monorepo, the source trees are not versioned by this
repository's own git history.

## Source tree

One of the two externally-versioned trees checked out into this repository:

- `mapguide/MgDev` — MapGuide Open Source
- `fdo` — Feature Data Objects (FDO)

Both are Subversion (SVN) working copies. The working tree may be edited freely, but
changes must never be committed back to SVN (no `svn` write commands).

## API/ABI mode

The phase the source trees are in with respect to their shipped public surface: `freeze` (it
must not change), `additive` (it may grow, but must not change shape) or `free` (it may
change deliberately). The current mode is recorded in `AGENTS.md`.

## Target

The product being built: either `mapguide` or `fdo`.

## Distro

The Linux distribution family a build environment is based on: `ubuntu` or `generic`
(a Rocky Linux base with no system-provided development libraries).

## Tag

The distribution version tag (for example `22.04`). Combined with `distro`, it forms the
`distro label`.

## Baseline distro

The reference distro used to validate source-tree changes: the latest Ubuntu version
supported by the build scripts.

## Distro label

The normalized name for a `distro` + `tag` combination (for example `ubuntu22`, or
`generic`). Used to name container images, generated directories, and artifacts.

## Thin image

A development container image that contains only build tools and libraries — no source
code and no compiler output. Source and output are provided at run time through mounted
host volumes.

## Build environment

The set of generated Dockerfiles and snap scripts for one `target`/`distro label`/`cpu`
combination.

## Build area

The host directory holding all intermediate compiler output, mounted into build
containers.

## Artifacts

The host directory receiving build outputs (tarballs, installers).

## Caches

The host directory holding per-target ccache caches.

## SDKs

The host directory holding third-party SDK downloads and build-time downloads.
