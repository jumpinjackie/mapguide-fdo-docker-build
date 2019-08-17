# A docker-driven build system for MapGuide and FDO

This is a docker-driven build system for MapGuide and FDO

# Requirements

 * A linux host OS that can run Docker
 * Git
 * git-lfs

# Usage

## 1. Clone this repo

```
git clone https://github.com/jumpinjackie/mapguide-fdo-docker-build`
git submodule update --init --recursive
cd mapguide/MgDev/Oem/CsMap
git lfs pull
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
 * `docker/x64/fdo/ubuntu14/test`
 * `docker/x64/mapguide/ubuntu14/build`
 * `docker/x64/mapguide/ubuntu14/develop`
 * `docker/x64/mapguide/ubuntu14/run`

The `--distro` and `--tag` parameters are composed into the base docker image from which our target environment is built on top of, so in the above example, our docker environment will ultimately be based from the `ubuntu:14.04` docker base image

A convenience `env_setup_all.sh` is provided that sets up the docker environments for all supported distros

## 3. Run the build

Assuming you set up the target environment for Ubuntu 14.04 (64-bit), then to build FDO, run:

```
docker/x64/fdo/ubuntu14/build/snap.sh
```

Once FDO is built, the tarballs will be copied to the top-level `artifacts` folder.

To build MapGuide, run:

```
docker/x64/mapguide/ubuntu14/build/snap.sh
```

NOTE: You must build FDO first (and its SDK tarball present in `artifacts`) before you can build MapGuide.

## 4. Running test suites

Assuming you set up the target environment for Ubuntu 14.04 (64-bit), then to build FDO, run:

```
docker/x64/fdo/ubuntu14/test/snap.sh
```

This will run all the unit test runner executables within the build image (and build/run this base image first if it doesn't exist) and copies all test logs out to the top-level `logs` folder.

If you know the base build image already exists (and don't want to waste time (re-)building a base image that's already there), you can run:

```
docker/x64/fdo/ubuntu14/test/snap.sh --skip-base-image-build
```

# Supported build environments

|target  |distro|tag  |x64|x86|
|--------|------|-----|---|---|
|mapguide|centos|7    | Y | N |
|mapguide|centos|6    | Y | N |
|mapguide|ubuntu|14.04| Y | N |
|mapguide|ubuntu|16.04| Y | N |
|mapguide|ubuntu|18.04| N | N |
|fdo     |ubuntu|14.04| Y | N |
|fdo     |ubuntu|16.04| Y | N |
|fdo     |ubuntu|18.04| Y | N |
|fdo     |centos|7    | Y | N |
|fdo     |centos|6    | Y | N |

# Known issues

MapGuide will not fully build on Ubuntu 18.04 due to our bundled version of PHP (5.6) requiring OpenSSL <= 1.1.0, which is not not possible on this distro

 * Ubuntu 18.04 provides OpenSSL 1.1.0
 * Ubuntu 18.04 also provides OpenSSL 1.0, but this cannot be installed side-by-side with the default 1.1.0 package. The 1.1.0 package is also a dependency of several build packages.

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots
