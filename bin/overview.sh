#!/bin/sh
#set -o nounset

BASEDIR=/root/jobview_t2
WEBDIR=/var/www/html/ucsd
source $BASEDIR/setup.sh

cd $BASEDIR/bin || { echo Failed to cd to $BASEDIR/bin; exit 1; }
perl -w overview.pl
cp $BASEDIR/html/overview.html $BASEDIR/html/jobview.xml $WEBDIR/
cp $BASEDIR/images/rrd/*.png $WEBDIR/images/
exit $?
