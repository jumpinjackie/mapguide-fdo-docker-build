# A docker-driven build system for MapGuide and FDO

This is a docker-driven build system for MapGuide and FDO

# Requirements

 * A linux host OS that can run Docker
 * Git
 * Subversion

# Usage

## 1. Clone this repo and checkout MapGuide/FDO repositories

```
git clone https://github.com/jumpinjackie/mapguide-fdo-docker-build`
./svn_checkout.sh
```

## 2. Set up your desired target environment

Suppose you want to build MapGuide/FDO for Ubuntu 22.04 (64-bit)

```
./env_setup.sh --target fdo --distro ubuntu --tag 22.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 22.04 --cpu x64
```

This will generate a series of `Dockerfile` and `snap.sh` build scripts in:

 * `docker/x64/fdo/ubuntu22/build`
 * `docker/x64/fdo/ubuntu22/develop_thin`
 * `docker/x64/fdo/ubuntu22/run`
 * `docker/x64/mapguide/ubuntu22/build`
 * `docker/x64/mapguide/ubuntu22/develop_thin`
 * `docker/x64/mapguide/ubuntu22/run`

The `--distro` and `--tag` parameters are composed into the base docker image from which our target environment is built on top of, so in the above example, our docker environment will ultimately be based from the `ubuntu:22.04` docker base image

A convenience `env_setup_all.sh` is provided that sets up the docker environments for all supported distros

The `--distro` and `--tag` combinations we currently recognise in this script are:

 * `ubuntu` and `22.04`
 * `generic` and no tag

The `generic` distro is a `rockylinux` container geared towards building MapGuide and FDO without any system-provided development libraries and allows for maximally portable linux binaries. This distro target also produces the "common libs subset" of MapGuide, whose `.so` binaries are bundled with a multi-platform .net API binding nuget package.

## 3. Run the build

Assuming you set up the target environment for Ubuntu 22.04 (64-bit), then to build FDO, run:

```
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64
```

Once FDO is built, the tarballs will be copied to the top-level `artifacts` folder.

To build MapGuide, run:

```
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64
```

NOTE: You must build FDO first (and its SDK tarball present in `artifacts`) before you can build MapGuide.

A convenience `build_all_thin.sh` is provided that will build MapGuide/FDO for all supported distros

All MapGuide/FDO build containers are "thin" in the sense that source code and compiler output is not added to these docker images, only the development tools and libraries are added to the image. Source code and compiler output are read and written to directories referenced outside from the docker host via mounted volumes.

 * `/build_area` is the root of all intermediate compiler output
 * `/fdo` is the `svn` checkout of FDO trunk
 * `/mapguide` is the `svn` checkout of MapGuide trunk

All MapGuide/FDO build containers also leverage the use of `ccache` to store their compilation output to a volume mounted ccache cache directory (the `/caches` sub-directory in this repo)

These 2 combined, result in a build pipeline that is very fast for builds after the first build, allowing for a rapid developer/iteration inner-loop.

## 4. Running test suites

Open 2 separate terminal sessions

In terminal 1 (to install the MapGuide installer package into the target distro docker container and start the MapGuide Server in interactive mode):

```
./mapguide_image_install.sh --target [generic|ubuntu] --target-distro [distro] --tag [latest|version]
```

In terminal 2 (to run the integration test suite):

> NOTE: You must have node.js installed

> `--output headers` option is specified as some test cases output binary response content which certain shells/terminals may try to interpet the content as extra commands/control sequences/audio cues. This option was the best one that provides some level of chatter without being too quiet or too verbose.

```
cd tests
# Run all mapagent test suites
npx httpyac *_api.http --all --bail --output headers
# Run post install sanity check
npx httpyac post_install_checks.http --all --bail --output headers
# Run teardown
npx httpyac _teardown.http --all --bail --output headers
```

# A special note for Ubuntu 22.04 docker hosts

ASAN in llvm 14 provided in ubuntu 22.04 is incompatible with high-entropy ASLR in much newer
kernels to random crashes: https://reviews.llvm.org/D148280

This issue is most prevalent in debug builds as the build process has a random, but high chance
of crashing and infinitely looping with `AddressSanitizer:DEADLYSIGNAL`

To workaround this, restore the older entropy setting like so

> sudo sysctl vm.mmap_rnd_bits=28

To check if your entroy is at the right level, run the following command:

> sudo sysctl -a | grep vm.mmap.rnd

It should report something like this

```
vm.mmap_rnd_bits = 28
vm.mmap_rnd_compat_bits = 8
```

This setting does not persist, so it must be done and checked before starting a build

# Supported build environments

|target  |distro|tag  |
|--------|------|-----|
|mapguide|generic|    |
|mapguide|ubuntu|22.04|
|fdo     |ubuntu|22.04|
|fdo     |ubuntu|16.04|
|fdo     |ubuntu|18.04|
|fdo     |generic|    |

Building for 32-bit Linux distros is not supported.

Our canonical distros for building MapGuide releases for Linux are:

 * Rocky Linux 8 (for `generic`)
 * Ubuntu 22.04

# FDO Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | GDAL             | OpenSSL         | libcurl         | mysqlclient | mariadbclient   | libpq           | xalan-c          | xerces-c          |
|----------|------------------|-----------------|-----------------|-------------|-----------------|-----------------|------------------|-------------------|
| generic  | Internal/dynamic | Internal/static | Internal/static | N/A         | Internal/static | Internal/static | Internal/dynamic | Internal/dynamic  |
| ubuntu22 | System           | System          | System          | System      | N/A             | System          | System           | System            |

# MapGuide Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | ACE              | dbxml            | berkely db       | xqilla           | geos            | gd              | libpng          | freetype        | libjpeg         | zlib            | xerces-c         |
|----------|------------------|------------------|------------------|------------------|-----------------|-----------------|-----------------|-----------------|-----------------|-----------------|------------------|
| generic  | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/dynamic |
| ubuntu22 | System           | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/static^| System          | System          | System          | System          | System          | System           |

^ The version of GEOS library shipped with Ubuntu 22.04 has an incompatible C++ API that is too difficult to #ifdef around. Until MapGuide switches to using GEOS's C API we will have to build MapGuide against our internal copy for the foreseeable future

# Known issues

MapGuide has not been tested to build on Ubuntu versions older than 22.04

# WSL2 Notes

You must use Docker Desktop for Windows as the docker engine when going the WSL2 route. Alternatives like Rancher Desktop are not suitable yet due to various unresolved bugs around volume mounting that breaks building MapGuide/FDO code within dev containers.

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots
