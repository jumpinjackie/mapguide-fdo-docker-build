#!/bin/bash
mkdir -p logs
for cpu in x64 x86
do
    for distro in ubuntu18 ubuntu16 ubuntu14 centos7 centos6 generic
    do
        if [ -d ./docker/$cpu/fdo/$distro ];
        then
            echo "Starting FDO thin image build for $distro ($cpu)"
            time ./docker/$cpu/fdo/$distro/develop_thin/snap.sh 2>&1 | tee logs/fdo_${distro}_${cpu}.log
            if [ "$?" -ne 0 ] ; then
                echo "ERROR building FDO thin image for $distro ($cpu)"
                exit 1
            fi
        fi

        if [ -d ./docker/$cpu/mapguide/$distro ];
        then
            echo "Starting MapGuide thin image build for $distro ($cpu)"
            time ./docker/$cpu/mapguide/$distro/develop_thin/snap.sh 2>&1 | tee logs/mapguide_${distro}_${cpu}.log
            if [ "$?" -ne 0 ] ; then
                echo "ERROR building MapGuide thin image for $distro ($cpu)"
                exit 1
            fi
        fi
    done
done