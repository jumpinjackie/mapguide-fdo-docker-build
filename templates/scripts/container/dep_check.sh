#!/bin/sh

# Resolve the installed trees instead of pinning their version here: the installer creates exactly
# one tree of each, and a baseline version bump would otherwise leave this check pointed at a path
# that no longer exists. A value the caller already exported (mapguide_smoke_test.sh sets MG_INST)
# wins over the discovery.
FDO_INST=${FDO_INST:-$(ls -d /usr/local/fdo-[0-9]* 2>/dev/null | sort -V | tail -1)}
MG_INST=${MG_INST:-$(ls -d /usr/local/mapguideopensource-[0-9]* 2>/dev/null | sort -V | tail -1)}

if [ -z "$FDO_INST" ] || [ -z "$MG_INST" ]; then
    echo "[dep_check]: FATAL: could not locate the installed trees under /usr/local"
    echo "[dep_check]:   FDO_INST=[$FDO_INST] MG_INST=[$MG_INST]"
    exit 1
fi

find $FDO_INST -type f -exec file --mime-type {} + | grep -E 'application/(x-executable|x-sharedlib)' | awk -v suffix=":" '{ sub(suffix, ""); print $1 }' > /tmp/fdolist
find $MG_INST -type f -exec file --mime-type {} + | grep -E 'application/(x-executable|x-sharedlib)' | awk -v suffix=":" '{ sub(suffix, ""); print $1 }' > /tmp/mglist

good=0
bad=0

check_fdo_deps()
{
    NOT_FOUND=$(env LD_LIBRARY_PATH=$FDO_INST/lib64:$LD_LIBRARY_PATH ldd $1 | grep "not found")
    if [ -n "$NOT_FOUND" ]; then
        case "$1" in
            *KingOracleProvider*) # We expect users to bring their own OCI for legal reasons so we expect dep check to fail for this library
                echo "Skipping dependency check on $1: We're expecting you to bring your own OCI"
                ;;
            *)
                echo "[dep_check]: $1 has missing dependencies:"
                echo "$NOT_FOUND"
                bad=$((bad+1))
                #exit 1
                ;;
        esac
    else
        echo "[dep_check]: $1: All dependencies met"
        good=$((good+1))
    fi
}

check_mapguide_deps()
{
    NOT_FOUND=$(env LD_LIBRARY_PATH=$FDO_INST/lib64:$MG_INST/lib64:$MG_INST/server/lib64:$LD_LIBRARY_PATH ldd $1 | grep "not found")
    if [ -n "$NOT_FOUND" ]; then
        case "$1" in
            *libcoreclrtraceptprovider.so) # The CLR opens this LTTng provider only when LTTng tracing is enabled, so the .NET runtime (and RepositoryAdmin) runs without it
                echo "Skipping dependency check on $1: optional LTTng tracing provider of the .NET runtime"
                ;;
            *)
                echo "[dep_check]: $1 has missing dependencies:"
                echo "$NOT_FOUND"
                bad=$((bad+1))
                #exit 1
                ;;
        esac
    else
        echo "[dep_check]: $1: All dependencies met"
        good=$((good+1))
    fi
}

echo "[dep_check]: Checking FDO binaries"
for f in $(cat /tmp/fdolist)
do
    #echo "[dep_check]: Checking [$f]"
    check_fdo_deps $f
done

echo "[dep_check]: Checking MapGuide binaries"
for f in $(cat /tmp/mglist)
do
    #echo "[dep_check]: Checking [$f]"
    check_mapguide_deps $f
done

echo "Summary:"
echo " $bad binaries have missing dependencies"
echo " $good binaries have their dependencies met"
