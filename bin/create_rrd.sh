#!/bin/sh
#set -o nounset

BASEDIR=/root/jobview_t2
source $BASEDIR/setup.sh

perl -w create_rrd.pl
perl -w create_vo_rrd.pl

exit $?

