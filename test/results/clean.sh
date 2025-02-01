#!/bin/sh
this_dir=$(pwd)
for d in ./*/
do
    cd "$d" || exit
    rm -f *.json
    rm -f *.xml
    rm -f *.html
    rm -f *.png
    rm -f *.txt
    cd "$this_dir" || exit
done