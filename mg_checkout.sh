#!/bin/bash
svn cleanup mapguide
svn update mapguide
while [ $? -ne 0 ]
do
	echo "SVN update interrupted. Retrying after 5s"
	sleep 5s
	svn cleanup mapguide
	svn update mapguide
done
echo "SVN update complete"
