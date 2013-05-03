mythfs-perl
===========

This is a FUSE filesystem for MythTV (www.mythtv.org).  It uses the
Myth 0.25 API to mount a read only virtual filesystem on a local or
remote Myth master host, for convenient playback with mplayer or other
video tools.

To install:

<pre>
 ./Build.PL
 ./Build test
 ./Build install
</pre>

Use it like this:

<pre>
 mythfs.pl MyHost /tmp/mythfs
</pre>

replacing "MyHost" with the name of your master backend. This will
populate a read-only /tmp/mythfs directory with human-readable
recordings organized by title (directory) and subtitle (file). In the
case that there is no subtitle, then the recording file will be placed
into the top level of the directory. 

To unmount:

<pre>
 fusermount -u /tmp/mythfs
</pre>

Here is an example directory listing:

<pre>
 % <b>ls -lR  /tmp/mythfs</b>
 total 35
 -rw-r--r-- 1 lstein lstein 14172577964 Dec 25 16:00 A Heartland Christmas 2012-12-25-16:00.mpg
 -rw-r--r-- 1 lstein lstein 17591877032 Mar 10 11:00 A Knight's Tale 2013-03-10-11:00.mpg
 drwxr-xr-x 1 lstein lstein           5 May  3 15:25 Alfred Hitchcock Presents
 drwxr-xr-x 1 lstein lstein           8 May  3 15:25 American Dad
 ...

 /home/lstein/Myth/Alfred Hitchcock Presents:
 total 3
 -rw-r--r-- 1 lstein lstein 647625408 Dec 25 15:30 Back for Christmas 2012-12-25-15:30.mpg
 -rw-r--r-- 1 lstein lstein 647090360 Dec  7 00:00 Dead Weight 2012-12-07-00:00.mpg
 -rw-r--r-- 1 lstein lstein 660841056 Mar 11 03:00 Rose Garden 2013-03-11-03:00.mpg
 -rw-r--r-- 1 lstein lstein 647524452 Dec 25 00:00 Santa Claus and the 10th Ave. Kid 2012-12-25-00:00.mpg
 -rw-r--r-- 1 lstein lstein 649819932 Dec 27 00:00 The Contest of Aaron Gold 2012-12-27-00:00.mpg

 /home/lstein/Myth/American Dad:
 total 4
 -rw-r--r-- 1 lstein lstein 3512038152 Apr 24 00:00 Flirting With Disaster 2013-04-24-00:00.mpg
</pre>

