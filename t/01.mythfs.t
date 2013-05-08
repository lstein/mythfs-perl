#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use ExtUtils::MakeMaker;
use File::Temp qw(tempdir);
use FindBin '$Bin';
use constant TEST_COUNT => 1;

use lib "$Bin/lib","$Bin/../lib","$Bin/../blib/lib","$Bin/../blib/arch";
use Test::More tests => 11;

my $test_xml = "gunzip -c $Bin/data/dummy_xml.gz|";
my $mount    = tempdir(CLEANUP=>1);
my $script   = "$Bin/../blib/script/mythfs.pl";

my $result = system $script,"--XML=$test_xml",'dummy_host',$mount;
is($result,0,'mount script ran ok');
sleep 1;
ok(-d  $mount,              "mountpoint exists");
ok(-e "$mount/Hamlet.mpg",  "expected file exists");
ok(-d "$mount/The Simpsons","expected directory exists");
ok(-e "$mount/The Simpsons/Pulpit Friction.mpg","expected subfile exists");
is(-s "$mount/The Simpsons/Pulpit Friction.mpg",3295787392,"file has correct size");
my @stat = stat("$mount/The Simpsons/Pulpit Friction.mpg");
is($stat[9],1367196599,'file has correct mtime');

$result    = system 'fusermount','-u',$mount;
is($result,0,'fusermount ran ok');

# mount with special pattern
$result = system $script,"--XML=$test_xml",'-p=%C/%T:%S','--trim=:','dummy_host',$mount;
is($result,0,'mount script ran ok');
sleep 1;

ok(-e "$mount/Fantasy/Penelope.mpg",'pattern interpolation and trimming worked correctly');

$result    = system 'fusermount','-u',$mount;
is($result,0,'fusermount ran ok');


exit 0;
