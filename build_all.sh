#!/bin/bash
mkdir -p logs
for cpu in x64 x86
do
    for distro in ubuntu18 ubuntu16 ubuntu14 centos7 centos6
    do
        if [ -d ./docker/$cpu/fdo/$distro ];
        then
            echo "Starting FDO build for $distro ($cpu)"
            time ./docker/$cpu/fdo/$distro/build/snap.sh 2>&1 | tee logs/fdo_${distro}_${cpu}.log
            if [ "$?" -ne 0 ] ; then
                echo "ERROR building FDO for $distro ($cpu)"
                exit 1
            fi
        else
            echo "No such FDO docker environment for $distro ($cpu). Skipping"
        fi

        if [ -d ./docker/$cpu/mapguide/$distro ];
        then
            echo "Starting MapGuide build for $distro ($cpu)"
            time ./docker/$cpu/mapguide/$distro/build/snap.sh 2>&1 | tee logs/mapguide_${distro}_${cpu}.log
            if [ "$?" -ne 0 ] ; then
                echo "ERROR building MapGuide for $distro ($cpu)"
                exit 1
            fi
        else
            echo "No such MapGuide docker environment for $distro ($cpu). Skipping"
        fi
    done
done
