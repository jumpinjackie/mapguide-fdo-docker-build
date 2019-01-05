# A docker-driven build system for MapGuide and FDO

This is a docker-driven build system for MapGuide and FDO

# Requirements

 * A linux host OS that can run Docker

# Usage

## 1. Clone this repo

```
git clone https://github.com/jumpinjackie/mapguide-fdo-docker-build`
git submodule --init
```

## 2. Set up your desired target environment

Suppose you want to build MapGuide/FDO for Ubuntu 14.04 (64-bit)

```
./env_setup.sh --target fdo --distro ubuntu --tag 14.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 14.04 --cpu x64
```

This will generate a series of `Dockerfile` and `snap.sh` build scripts in:

 * `docker/x64/fdo/ubuntu14/build`
 * `docker/x64/fdo/ubuntu14/develop`
 * `docker/x64/fdo/ubuntu14/run`
 * `docker/x64/mapguide/ubuntu14/build`
 * `docker/x64/mapguide/ubuntu14/develop`
 * `docker/x64/mapguide/ubuntu14/run`

The `--distro` and `--tag` parameters are composed into the base docker image from which our target environment is built on top of, so in the above example, our docker environment will ultimately be based from the `ubuntu:14.04` docker base image

## 3. Run the build

Assuming you set up the target environment for Ubuntu 14.04 (64-bit), then to build FDO, run:

```
docker/x64/fdo/ubuntu14/build/snap.sh
```

Once FDO is built, the tarballs will be copied to the top-level `artifacts` folder.

To build MapGuide, run:

```
docker/x64/fdo/ubuntu14/build/snap.sh
```

NOTE: You must build FDO first (and its SDK tarball present in `artifacts`) before you can build MapGuide.

# Supported build environments

|target  |distro|tag  |x64|x86|
|--------|------|-----|---|---|
|mapguide|centos|7    | N | N |
|mapguide|ubuntu|14.04| Y | N |
|mapguide|ubuntu|16.04| Y | N |
|mapguide|ubuntu|18.04| N | N |
|fdo     |ubuntu|14.04| Y | N |
|fdo     |ubuntu|16.04| Y | N |
|fdo     |ubuntu|18.04| Y | N |
|fdo     |centos|7    | Y | N |

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots