# Custom SDKs and tools

Put [Oracle Instant/MySQL] Client SDK and other thirdparty lib contents here

## For all

Download ninja: https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip

## For FDO (all distros)

Download Oracle Instant Client (registration required): https://www.oracle.com/database/technologies/instant-client.html

 * Download the 12cR2 version

## For FDO (generic)

Download MySQL Connector/C: https://downloads.mysql.com/archives/get/p/19/file/mysql-connector-c-6.1.11-linux-glibc2.12-x86_64.tar.gz

Download unixODBC: https://www.unixodbc.org/

 * Download version: `2.3.12`

Download postgresql: https://ftp.postgresql.org/pub/source/v16.1/postgresql-16.1.tar.gz

Download MariaDB Connector/C: https://dlm.mariadb.com/3677127/Connectors/c/connector-c-3.3.8/mariadb-connector-c-3.3.8-src.tar.gz

## For MapGuide (generic)

Download OpenJDK 8 (64-bit Linux): https://adoptium.net/temurin/releases/?os=linux&arch=x64&package=jdk&version=8

 * Download version: `8u422-b05`
 * Save tarball as `openjdk8.tar.gz`

Download ant: https://dlcdn.apache.org//ant/binaries/apache-ant-1.10.14-bin.tar.gz

 * Save tarball as: `ant.tar.gz`

Download pcre2: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz

 * Save tarball as: `pcre2.tar.gz`

Download expat: https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz

 * Save tarball as: `expat.tar.gz`

Download libxml2: https://gitlab.gnome.org/GNOME/libxml2/-/archive/v2.13.3/libxml2-v2.13.3.tar.gz

 * Save tarball as: `libxml2.tar.gz`

Download oniguruma: https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz

 * Save tarball as: `onig.tar.gz`

# Expected structure

```
 $ROOT
    sdks
        tools
            ninja [extracted from ninja-linux.zip]
        mysql
            x64
                bin
                docs
                include
                lib
        oracle
            x64
                instantclient_11_2
                    sdk
                        include
                        ...
                instantclient_12_2
                    sdk
                        include
                        ...
```