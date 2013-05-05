#!/usr/bin/perl

use strict;
use warnings;
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
my (@FuseOptions,$Debug,$NoDaemon);

my $Usage = <<END;
Usage: $0 <Myth Master Host> <mountpoint>

Options:
   -f                      remain in foreground
   -o allow_other          allow other accounts to access filesystem
   -o default_permissions  enable permission checking by kernel
   -o fsname=name          set filesystem name
   -o use_ino              let filesystem set inode numbers
   -o nonempty             allow mounts over non-empty file/dir
   -d                      trace FUSE operations
END

    ;

GetOptions('option:s'   => \@FuseOptions,
	   'foreground' => \$NoDaemon,
	   'debug'      => \$Debug,
    ) or die $Usage;

my $Host       = shift or die $Usage;
my $mountpoint = shift or die $Usage;
$mountpoint    = File::Spec->rel2abs($mountpoint);

my $options = join(',',@FuseOptions,'ro');

become_daemon() unless $NoDaemon;

start_update_thread();

Fuse::main(mountpoint => $mountpoint,
	   getdir     => 'main::e_getdir',
	   getattr    => 'main::e_getattr',
	   open       => 'main::e_open',
	   read       => 'main::e_read',
	   mountopts  => $options,
	   debug      => $Debug||0,
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

sub start_update_thread {
    my $thr = threads->create(
	sub {
	    while (1) {
		print  STDERR scalar(localtime())," Update_thread...";
		Recorded->_refresh_recorded;
		sleep (CACHE_TIME);
	    }
	}
	);
    $thr->detach();
}

sub fixup {
    my $path = shift;
    $path =~ s!^/!!;
    $path;
}

sub e_open {
    my $path = fixup(shift);
    my $r = Recorded->get_recorded;
    return -ENOENT() unless $r->{paths}{$path} || $r->{directories}{$path};
    return -EISDIR() if $r->{directories}{$path};
    return 0;
}

sub e_read {
    my ($path,$size,$offset) = @_;


    $offset ||= 0;

    $path = fixup($path);
    my $r = Recorded->get_recorded('use_cached');
    return -ENOENT() unless $r->{paths}{$path};
    return -EINVAL() if $offset > $r->{paths}{$path}{length};

    my $basename = $r->{paths}{$path}{basename};
    my $sg       = $r->{paths}{$path}{storage};
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
    my @entries = keys %{$r->{directories}{$path}};
    return -ENOENT() unless @entries;
    return ('.','..',@entries,0);
}

sub e_getattr {
    my $path = fixup(shift) || '.';

    my $context = fuse_get_context();
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) 
	= (0,0,0,1,@{$context}{'gid','uid'},1,1024);

    my $r = Recorded->get_recorded;
    my $e = $r->{paths}{$path} or return -ENOENT();

    my $isdir = $e->{type} eq 'directory';

    my $mode = $isdir ? 0040000|0555 : 0100000|0444;

    my $ctime = $e->{ctime};
    my $mtime = $e->{mtime};
    my $atime = $mtime;
    my $size  = $e->{length};

    return ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
	    $size,$atime,$mtime,$ctime,$blksize,$blocks);
}

package Recorded;
use POSIX 'strftime';
use LWP::UserAgent;
use Date::Parse 'str2time';
use XML::Simple;
use Data::Dumper 'Dumper';

# cache entries for 10 minutes
# this means that new recordings won't show up in the file system for up to this long
use constant CACHE_TIME => 60*10;  
my $cache;

sub get_recorded {
    my $self = shift;
    my $nocache = shift;

    return $cache if $cache && $nocache;
    return $cache if $cache && time() - $Cache{mtime} < CACHE_TIME;

    lock %Cache;
    return $cache = eval ($Cache{recorded}||'');
}

sub recording2path {
    my $self = shift;
    my $recording = shift;
    my $title    = $recording->{Title};
    my $subtitle = $recording->{SubTitle};
    return $subtitle ? ($title,$subtitle) : ($title);  # could be more sophisticated
}

sub _refresh_recorded {
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
    $self->_build_directory_map($rec,$var);

    local $Data::Dumper::Terse = 1;
    $Cache{recorded} = Data::Dumper->Dump([$var]);
    $Cache{mtime}    = time();
}

sub _build_directory_map {
    my $self = shift;
    my ($rec,$map) = @_;

    my $ok_chars = 'a-zA-Z0-9_.&@:* ^![]{}(),?#\$=+%-';

    my $count = 0;
    my (%recordings,%paths);
    for my $r (@{$rec->{Programs}{Program}}) {
	$count++;

	my $sg = $r->{Recording}{StorageGroup};
	next if $sg eq 'LiveTV';

	my (@path)              = $self->recording2path($r);
	my $key                 = join('-',$r->{HostName},$r->{FileName});  # we use this as our unique ID
	my $path                = join('/',map {s/[^$ok_chars]/_/g;$_} @path);
	$recordings{$key}{path}{$path}++;
	$recordings{$key}{meta} = $r;
	$paths{$path}{$key}++;
    }
    
    # paths that need fixing to be unique
    for my $path (keys %paths) {
	my @keys = keys %{$paths{$path}};
	next unless @keys > 1;

	my $count = 0;
	for my $key (@keys) {
	    my $fixed_path = sprintf("%s-%s_%s",
				     $path,
				     $recordings{$key}{meta}{Channel}{ChannelName},
				     $recordings{$key}{meta}{StartTime});
				     
	    delete $recordings{$key}{path};
	    $recordings{$key}{path}{$fixed_path}++;
	}
    }

    # at this point, we actually build the map that is passed to FUSE
    for my $key (keys %recordings) {

	my ($path) = keys %{$recordings{$key}{path}}; # should only be one unique path at this point

	# take care of the extension
	my $meta     = $recordings{$key}{meta};
	my ($suffix) = $meta->{FileName}    =~ /\.(\w+)$/;
	$path       .= ".$suffix" unless $path =~ /\.$suffix$/;

	my @path = split('/',$path);
	my $filename = pop @path;
	unshift @path,'.';

	my $ctime = str2time($meta->{StartTime});
	my $mtime = str2time($meta->{LastModified});
	
	$map->{paths}{$path}{type}     = 'file';
	$map->{paths}{$path}{length}   = $meta->{FileSize};
	$map->{paths}{$path}{basename} = $meta->{FileName};
	$map->{paths}{$path}{storage}  = $meta->{Recording}{StorageGroup};
	$map->{paths}{$path}{ctime}    = $ctime;
	$map->{paths}{$path}{mtime}    = $mtime;
	
	# take care of the directories
	my $dir = '';
	while (my $p = shift @path) {
	    $dir .= length $dir ? "/$p" : $p;
	    $dir =~ s!^\./!!;

	    $map->{paths}{$dir}{type}     = 'directory';
	    $map->{paths}{$dir}{length}++;
	    $map->{paths}{$dir}{ctime}    = $ctime if ($map->{paths}{$p}{ctime}||0) < $ctime;
	    $map->{paths}{$dir}{mtime}    = $mtime if ($map->{paths}{$p}{mtime}||0) < $mtime;

	    # subdirectory entry
	    if (defined $path[0]) {
		$map->{directories}{$dir}{$path[0]}++;
	    }
	}
	$map->{directories}{$dir}{$filename}++;
    }

    print STDERR scalar keys %recordings," recordings retrieved\n";
    return $map;
}
