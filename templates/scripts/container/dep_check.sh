#!/bin/sh

FDO_INST=/usr/local/fdo-4.2.0
MG_INST=/usr/local/mapguideopensource-4.0.0

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
        echo "[dep_check]: $1 has missing dependencies:"
        echo "$NOT_FOUND"
        bad=$((bad+1))
        #exit 1
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
