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

Suppose you want to build MapGuide/FDO for Ubuntu 16.04 (64-bit)

```
./env_setup.sh --target fdo --distro ubuntu --tag 16.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 16.04 --cpu x64
```

This will generate a series of `Dockerfile` and `snap.sh` build scripts in:

 * `docker/x64/fdo/ubuntu16/build`
 * `docker/x64/fdo/ubuntu16/develop_thin`
 * `docker/x64/fdo/ubuntu16/run`
 * `docker/x64/mapguide/ubuntu16/build`
 * `docker/x64/mapguide/ubuntu16/develop_thin`
 * `docker/x64/mapguide/ubuntu16/run`

The `--distro` and `--tag` parameters are composed into the base docker image from which our target environment is built on top of, so in the above example, our docker environment will ultimately be based from the `ubuntu:16.04` docker base image

A convenience `env_setup_all.sh` is provided that sets up the docker environments for all supported distros

## 3. Run the build

Assuming you set up the target environment for Ubuntu 14.04 (64-bit), then to build FDO, run:

```
./build_thin.sh --target fdo --distro ubuntu --tag 14 --cpu x64
```

Once FDO is built, the tarballs will be copied to the top-level `artifacts` folder.

To build MapGuide, run:

```
./build_thin.sh --target mapguide --distro ubuntu --tag 14 --cpu x64
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

TBD

# Supported build environments

|target  |distro|tag  |x64|x86|
|--------|------|-----|---|---|
|mapguide|centos|7    | Y | N |
|mapguide|ubuntu|16.04| Y | N |
|mapguide|ubuntu|18.04| N | N |
|fdo     |ubuntu|16.04| Y | N |
|fdo     |ubuntu|18.04| Y | N |
|fdo     |centos|7    | Y | N |

# FDO Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | GDAL             | OpenSSL         | libcurl         | mysqlclient | mariadbclient   | libpq           | xalan-c          | xerces-c          |
|----------|------------------|-----------------|-----------------|-------------|-----------------|-----------------|------------------|-------------------|
| centos7  | Internal/dynamic | Internal/static | Internal/static | N/A         | Internal/static | Internal/static | Internal/dynamic | Internal/dynamic  |
| ubuntu16 | System           | System          | System          | System      | N/A             | System          | System           | System            |
| ubuntu18 | System           | System          | System          | System      | N/A             | System          | System           | System            |

# MapGuide Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | ACE              | dbxml            | berkely db       | xqilla           | geos            | gd              | libpng          | freetype        | libjpeg         | zlib            | xerces-c         |
|----------|------------------|------------------|------------------|------------------|-----------------|-----------------|-----------------|-----------------|-----------------|-----------------|------------------|
| centos7  | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/dynamic |
| ubuntu16 | System           | Internal/dynamic | Internal/dynamic | Internal/dynamic | System          | System          | System          | System          | System          | System          | System           |
| ubuntu18 | System           | Internal/dynamic | Internal/dynamic | Internal/dynamic | System          | System          | System          | System          | System          | System          | System           |

# Known issues

MapGuide will not fully build on Ubuntu 18.04 (and likely newer versions) due to our bundled version of PHP (5.6) requiring OpenSSL <= 1.1.0, which is not not possible on this distro

 * Ubuntu 18.04 provides OpenSSL 1.1.0
 * Ubuntu 18.04 also provides OpenSSL 1.0, but this cannot be installed side-by-side with the default 1.1.0 package. The 1.1.0 package is also a dependency of several build packages.

# WSL2 Notes

`centos` based images/containers may fail to build/run. To address this, edit `%USERPROFILE%\.wslconfig` as follows:

```
[wsl2]
kernelCommandLine = vsyscall=emulate
```

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots
