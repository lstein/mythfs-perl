mythfs-perl
===========

This is a FUSE filesystem for MythTV (www.mythtv.org).  It uses the
Myth 0.25 API to mount the TV recordings known to a MythTV master back
end onto a virtual filesystem on the client machine for convenient
playback with mplayer or other video tools. Because this uses the
MythTV network protocol, the recordings do not need to be on a shared
NFS-mounted disk, nor does the Myth database need to be accessible
from the client.

Installation
============

Run the following commands from within the top-level directory of this
distribution:

 <pre> 
 $ <b>./Build.PL</b>
 $ <b>./Build test</b>
 $ <b>sudo ./Build install</b>
</pre>

If you get messages about missing dependencies, run:

<pre>
 $ ./Build installdeps
</pre>

and then "sudo ./Build install".

Your Perl must have been compiled with IThreads in order for this
script to work. To check if this is the case. you may run:

<pre>
 <b>$ perl -V | grep useithreads</b>
    useithreads=define, usemultiplicity=define
</pre>

Usage
=====

To mount the recordings contained on the master backend "MyHost" onto
a local filesystem named "/tmp/mythfs" use this command:

<pre>
 mythfs.pl MyHost /tmp/mythfs
</pre>

The script will fork into the background and should be stopped with
fusermount. The mounted /tmp/mythfs directory will contain a series of
human-readable recordings organized by title (directory) and subtitle
(file). In the case that there is no subtitle, then the recording file
will be placed into the top level of the directory.

To unmount:

<pre>
 fusermount -u /tmp/mythfs
</pre>

Note do NOT try to kill the mythfs.pl process. This will only cause a
hung filesystem that needs to be unmounted with fusermount.

There are a number of options that you can pass to mythfs.pl, the most
useful of which is "-o allow_other". If this is present, then others
on the system (including root) can see the mounted filesystem. Call
with the -h option for more help.

Understanding the Directory Layout
==================================

Recordings that are part of a series usually have a title (the series
name) and subtitle (the episode name). Such recordings are displayed
using a two-tier directory structure in which the top-level directory
is the series name, and the contents are a series of recorded
episodes.

For recordings that do not have a subtitle, typically one-off movie
showings, the recording is placed at the top level.

In all cases, the time the recorded was started is attached to the
filename, along with an extension indicating the recording type (.mpg
or .nuv). The file create and modification times correspond to the
recording start time. For directories, the times are set to the most
recent recording contained within the directgory.

Here is an example directory listing:

<pre>
 % <b>ls -lR  /tmp/mythfs</b>
 total 35
 -r--r--r-- 1 lstein lstein 12298756208 Dec 30 00:00 A Funny Thing Happened on the Way to the Forum 2012-12-30-00:00.mpg
 -r--r--r-- 1 lstein lstein 14172577964 Dec 25 16:00 A Heartland Christmas 2012-12-25-16:00.mpg
 dr-xr-xr-x 1 lstein lstein           5 Mar 11 03:00 Alfred Hitchcock Presents
 dr-xr-xr-x 1 lstein lstein           8 May  2 00:00 American Dad
 ...

 /home/lstein/Myth/Alfred Hitchcock Presents:
 total 3
 -r--r--r-- 1 lstein lstein 647625408 Dec 25 15:30 Back for Christmas 2012-12-25-15:30.mpg
 -r--r--r-- 1 lstein lstein 647090360 Dec  7 00:00 Dead Weight 2012-12-07-00:00.mpg
 -r--r--r-- 1 lstein lstein 660841056 Mar 11 03:00 Rose Garden 2013-03-11-03:00.mpg
 -r--r--r-- 1 lstein lstein 647524452 Dec 25 00:00 Santa Claus and the 10th Ave. Kid 2012-12-25-00:00.mpg
 -r--r--r-- 1 lstein lstein 649819932 Dec 27 00:00 The Contest of Aaron Gold 2012-12-27-00:00.mpg

 /home/lstein/Myth/American Dad:
 total 4
 -r--r--r-- 1 lstein lstein 3512038152 Apr 24 00:00 Flirting With Disaster 2013-04-24-00:00.mpg
</pre>

Troubleshooting
===============

This script has not yet undergone diligent testing. Try running with
the -debug flag to see where the problems are occurring and report
issues to https://github.com/lstein/mythfs-perl.

Author
======

Lincoln Stein <lincoln.stein@gmail.com>
3 May 2013
