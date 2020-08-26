#!/bin/sh

# clean thin images first
docker images | grep _thin_ | awk '{print $3}' | xargs docker rmi --force

# then clean the run images
docker images | grep _run_ | awk '{print $3}' | xargs docker rmi --force