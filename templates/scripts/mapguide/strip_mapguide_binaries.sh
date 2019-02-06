#!/bin/bash

# Prepare binaries for packaging by removing unnecessary
# .la and .a files and stripping unneeded symbols from the binaries
pushd $1
LIBDIRS="lib server/lib webserverextensions/lib lib64 server/lib64 webserverextensions/lib64" 
echo "Stripping symbols from binaries"
for libdir in ${LIBDIRS}
do
    # Remove any .la and .a files in lib directories
    rm -f ${libdir}/*.la
    rm -f ${libdir}/*.a

    # Remove unneeded symbols from files in the lib directories
    for file in `find ${libdir}/lib*.so* -type f -print`
    do
        strip --strip-unneeded ${file}
        chmod a-x ${file}
    done
done
popd