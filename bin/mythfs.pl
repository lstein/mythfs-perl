#!/usr/bin/perl

use strict;
use threads;
use threads::shared;
use Getopt::Long;
use Fuse 'fuse_get_context';
use File::Spec;
use LWP::UserAgent;
use POSIX qw(ENOENT EISDIR EINVAL ECONNABORTED setsid);

our $VERSION = '1.00';

my %Cache :shared;
my $Time = time();
my @FuseOptions;

my $Usage = <<END;
Usage: $0 <Myth Master Host> <mountpoint>

Options:
   -o allow_other          allow other accounts to access filesystem
   -o default_permissions  enable permission checking by kernel
   -o fsname=name          set filesystem name
   -o use_ino              let filesystem set inode numbers
   -o nonempty             allow mounts over non-empty file/dir
END

    ;

GetOptions('option:s' => \@FuseOptions) or die $Usage;

my $Host       = shift or die $Usage;
my $mountpoint = shift or die $Usage;
$mountpoint    = File::Spec->rel2abs($mountpoint);

my $options = join(',',@FuseOptions,'ro');

become_daemon();

Fuse::main(mountpoint => $mountpoint,
	   getdir     => 'main::e_getdir',
	   getattr    => 'main::e_getattr',
	   open       => 'main::e_open',
	   read       => 'main::e_read',
	   mountopts  => $options,
	   debug => 0,
	   threaded   => 1,
    );

exit 0;

sub become_daemon {
    fork() && exit 0;
    chdir ('/');
    setsid();
    open STDIN,"</dev/null";
    fork() && exit 0;
}

sub fixup {
    my $path = shift;
    $path =~ s!^/!!;
    $path =~ s/\.mpg$//;
    $path;
}

sub e_open {
    my $path = fixup(shift);
    my $r = Recorded->get_recorded;
    return -ENOENT() unless $r->{r}{$path} || $r->{d}{$path};
    return -EISDIR() if Recorded->isdir($path);
    return 0;
}

sub e_read {
    my ($path,$size,$offset) = @_;

    $offset ||= 0;

    $path = fixup($path);
    my $r = Recorded->get_recorded;
    return -ENOENT() unless $r->{r}{$path};
    return -EINVAL() if $offset > $r->{r}{$path}{length};

    my $basename = $r->{r}{$path}{basename};
    my $sg       = $r->{r}{$path}{storage};
    my $byterange= $offset.'-'.($offset+$size-1);

    my $ua = LWP::UserAgent->new;
    my $response = $ua->get("http://$Host:6544/Content/GetFile?StorageGroup=$sg&FileName=$basename",
			    'Range'       => $byterange);
    return -ECONNABORTED() unless $response->is_success;
    return $response->decoded_content;
}

sub e_getdir {
    my $path = fixup(shift) || '.';

    my $r = Recorded->get_recorded;
    return ('.','..', map {$r->{r}{$_}{display}||$_} keys %{$r->{d}},0)    if $path eq '.';
    my ($title,$subtitle) = split '/',$path;
    $r->{d}{$title} or return -ENOENT();
    my @entries = map {$r->{r}{"$title/$_"}{display}} grep {length $_} keys %{$r->{d}{$title}};
    return ('.','..',@entries,0);
}

sub e_getattr {
    my $path = fixup(shift) || '.';

    my $context = fuse_get_context();
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) 
	= (0,0,0,1,@{$context}{'gid','uid'},1,1024);

    my $r = Recorded->get_recorded;
    $path eq '.' || exists $r->{r}{$path} || exists $r->{d}{$path} || return -ENOENT();

    my $isdir = $path eq '.' || Recorded->isdir($path);
    my $mode = $isdir ? 0040000|0555 : 0100000|0444;

    my $time = $r->{r}{$path}{mtime} || $r->{m}{$path} || $Time;
    my $size = $isdir ? $isdir : $r->{r}{$path}{length};
    my ($atime,$mtime,$ctime);

    $atime=$mtime=$ctime = $time;

    return ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
	    $size,$atime,$mtime,$ctime,$blksize,$blocks);
}

package Recorded;
use POSIX 'strftime';
use LWP::UserAgent;
use Date::Parse 'str2time';
use XML::Simple;
use Data::Dumper;

# cache entries for 10 minutes
# this means that new recordings won't show up in the file system for up to this long
use constant CACHE_TIME => 60*10;  
my $cache;

sub get_recorded {
    my $self = shift;

    return $cache if $cache && time() - $cache->{mtime} < CACHE_TIME;

    $cache = eval ($Cache{recorded}||'');
    return $cache if $cache && time() - $cache->{mtime} < CACHE_TIME;

    lock %Cache;
    $cache = eval ($Cache{recorded}||'');
    return $cache if $cache && time() - $cache->{mtime} < CACHE_TIME;

    my $result = $self->_get_recorded;

    local $Data::Dumper::Terse = 1;
    $Cache{recorded} = Data::Dumper->Dump([$result]);

    return $cache = $result;
}

sub isdir {
    my $self = shift;
    my $path = shift;
    my $r    = $self->get_recorded;
    my ($title,$subtitle) = split '/',$path;
    return if $subtitle;
    $subtitle ||= '';
    my @subs = grep {length $_} keys %{$r->{d}{$title}};
    return scalar @subs;
}

sub _get_recorded {
    my $self = shift;

    local $SIG{CHLD} = 'IGNORE';
    my $var    = {};
    my $parser = XML::Simple->new(SuppressEmpty=>1);

    my $pid      = open (my $fh,"-|");
    defined $pid or die "Couldn't fork: #!";

    if (!$pid) {
	my $ua     = LWP::UserAgent->new;
	my $response = $ua->get("http://$Host:6544/Dvr/GetRecordedList",
				':content_cb' => sub {
				    my ($chunk,$resp,$prot) = @_;
				    print $chunk;
				}
	    );
	die $response->status_line unless $response->is_success;
	exit 0;
    }

    my $rec = $parser->XMLin($fh);

    my $ok_chars = 'a-zA-Z0-9_.&@:* ^![]{}(),?#\$=+%-';
    my $count = 0;
    my %to_fix;
    for my $r (@{$rec->{Programs}{Program}}) {
	$count++;

	my $sg = $r->{Recording}{StorageGroup};
	next if $sg eq 'LiveTV';

	my ($title,$subtitle,$length,$filename,$datetime) = @{$r}{qw(Title SubTitle FileSize FileName StartTime)};

	my $time = str2time($datetime);
	my $date = strftime('%Y-%m-%d-%H:%M',localtime($time));
	$title    =~ s/[^$ok_chars]/_/g;
	$subtitle ||= '';
	$subtitle =~ s/[^$ok_chars]/_/g;

	my $name  = $subtitle ? "$title/$subtitle" : $title;
	$name    .= " $date";
	(my $display = $name) =~ s!^[^/]+/!!;
	my ($suffix) = $filename =~ /(\.\w+)$/;
	$display .= $suffix;

	($title,$subtitle) = split '/',$name;

	$var->{r}{$name}{dtime}     = $datetime;
	$var->{r}{$name}{mtime}     = $time;
	$var->{r}{$name}{length}    = $length;
	$var->{r}{$name}{basename}  = $filename;
	$var->{r}{$name}{display}   = $display;
	$var->{r}{$name}{storage}   = $sg;
	$var->{d}{$title}{$subtitle||''}++;
	$var->{m}{$title}           = $time if ($var->{m}{$title}||0)<$time;
    }
    $var->{mtime} = time();
    return $var;
}
