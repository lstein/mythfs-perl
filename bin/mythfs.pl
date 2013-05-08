#!/usr/bin/perl

use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Semaphore;
use Getopt::Long;
use Fuse 'fuse_get_context';
use File::Spec;
use WWW::Curl::Easy;
use Config;
use POSIX qw(ENOENT EISDIR EINVAL ECONNABORTED setsid);

our $VERSION = '1.10';
use constant CACHE_TIME => 10; # minutes
use constant MAX_GETS   => 8;

my %Cache    :shared;
my $ReadSemaphore = Thread::Semaphore->new(MAX_GETS);
my $Recorded;

my (@FuseOptions,$CacheTime,$Debug,$NoDaemon,$Pattern,
    $LocalMount,$NoThreads,$HasIThreads,$Delimiter);
my $Usage = <<END;
Usage: $0 <Myth backend Host> <mountpoint>

Fuse filesystem to mount recordings from Myth backend running on Host
at the directory indicated by mountpoint: e.g. "mythfs.pl myhost
/tmp/mythfs".

Options:
   --cachetime=<time>            cache time for recording names (minutes)
   --option=allow_other          allow other accounts to access filesystem
   --option=default_permissions  enable permission checking by kernel
   --option=fsname=name          set filesystem name
   --option=use_ino              let filesystem set inode numbers
   --option=nonempty             allow mounts over non-empty file/dir
   --pattern=<patterns>          filename pattern default ("%T/%S")
   --mountpt=<path>              mountpoint/directory for locally stored recordings
   --trim=<char>                 trim redundant occurrences of this character
   --foreground                  remain in foreground
   --debug=<1,2>                 enable debugging. Pass -d 2 to trace Fuse operations (verbose!!)
   --nothreads                   disable threads

Filename patterns consist of regular characters and substitution
patterns beginning with a %. Slashes (\/) will delimit directories and
subdirectories. Empty directory names will be collapsed. The default
is "%T/%S", the recording title followed by the subtitle.  Run this
command with "-p help" to get a list of all the substitution patterns
recognized.

By default, files will be streamed as needed from the myth
backend. However, if the recording files are accessible directly from
the filesystem (e.g. via an NFS mount), you can provide the path to
this directory using the --mountpt option. The filenames will then be
presented as symbolic links.

Command line switches can abbreviated to single letters, so you can
use "-p %T/%S" instead of "--pattern=%/%S".

END
    ;
GetOptions('option:s'   => \@FuseOptions,
	   'cachetime=i'=> \$CacheTime,
	   'foreground' => \$NoDaemon,
	   'pattern=s'  => \$Pattern,
	   'debug:i'    => \$Debug,
	   'separator=s'=> \$Delimiter,
	   'mountpt=s'  => \$LocalMount,
	   'nothreads'  => \$NoThreads,
    ) or die $Usage;

$Pattern   ||= "%T/%S";
list_patterns_and_die() if $Pattern eq 'help';

$HasIThreads = $Config{useithreads};
$NoThreads ||= check_disable_threads();
$CacheTime ||= CACHE_TIME;
$CacheTime *=  60;  # to seconds
$Debug     = 1 if defined $Debug && $Debug==0;

my $Host       = shift or die $Usage;
my $mountpoint = shift or die $Usage;
$mountpoint    = File::Spec->rel2abs($mountpoint);

my $options  = join(',',@FuseOptions,'ro');

$Recorded = Recorded->new($Pattern);

become_daemon() unless $NoDaemon;
start_update_thread();

Fuse::main(mountpoint => $mountpoint,
	   getdir     => 'main::e_getdir',
	   getattr    => 'main::e_getattr',
	   open       => 'main::e_open',
	   read       => 'main::e_read',
	   release    => 'main::e_release',
	   readlink   => 'main::e_readlink',
	   mountopts  => $options,
	   debug      => $Debug>1,
	   threaded   => !$NoThreads,
    );

exit 0;

sub check_disable_threads {
    unless ($HasIThreads) {
	warn "This version of perl is not compiled for ithreads. Running with slower non-threaded version.\n";
	return 1;
    }
    if ($] >= 5.014 && $Fuse::VERSION < 0.15) {
	warn "You need Fuse version 0.15 or higher to run under this version of Perl.\n";
	warn "Threads will be disabled. Running with slower non-threaded version.\n";
	return 1;
    }

    return 0;
}

sub become_daemon {
    fork() && exit 0;
    chdir ('/');
    setsid();
    open STDIN,"</dev/null";
    fork() && exit 0;
}

sub start_update_thread {
    $Recorded->_refresh_recorded;
    return unless $HasIThreads;
    my $thr = threads->create(
	sub {
	    while (1) {
		sleep ($CacheTime);
		$Recorded->_refresh_recorded;
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
    my $r = $Recorded->get_recorded;
    return -ENOENT() unless $r->{paths}{$path} || $r->{directories}{$path};
    return -EISDIR() if $r->{directories}{$path};
    return 0;
}

sub e_release {
    return 0;
}

sub e_read {
    my ($path,$size,$offset) = @_;

    $offset ||= 0;

    $path = fixup($path);
    my $r = $Recorded->get_recorded('use_cached');
    return -ENOENT() unless $r->{paths}{$path};
    return -EINVAL() if $offset > $r->{paths}{$path}{length};

    my $basename = $r->{paths}{$path}{basename};
    my $sg       = $r->{paths}{$path}{storage};
    my $byterange= $offset.'-'.($offset+$size-1);

    $ReadSemaphore->down();
    my $content;
    my $curl = WWW::Curl::Easy->new;
    $curl->setopt(CURLOPT_URL,"http://$Host:6544/Content/GetFile?StorageGroup=$sg&FileName=$basename");
    $curl->setopt(CURLOPT_HTTPHEADER,["Range: $byterange"]);
    $curl->setopt(CURLOPT_WRITEDATA,\$content);
    my $retcode = $curl->perform;
    $ReadSemaphore->up();
    return -ECONNABORTED() unless $retcode==0;
    return -ECONNABORTED() unless $curl->getinfo(CURLINFO_RESPONSE_CODE) =~ /^2\d\d/;
    return $content;
}

sub e_getdir {
    my $path = fixup(shift) || '.';

    my $r = $Recorded->get_recorded;
    my @entries = keys %{$r->{directories}{$path}};
    return -ENOENT() unless @entries;
    return ('.','..',@entries,0);
}

sub e_readlink {
    my $path = fixup(shift) || '.';
    my $r = $Recorded->get_recorded;
    my $e = $r->{paths}{$path} or return -ENOENT();
    $LocalMount                or return -ENOENT();
    my $local_path = "$LocalMount/$r->{paths}{$path}{basename}";
    return $local_path;
}

sub e_getattr {
    my $path = fixup(shift) || '.';

    my $context = fuse_get_context();
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) 
	= (0,0,0,1,@{$context}{'gid','uid'},1,1024);

    my $r = $Recorded->get_recorded;
    my $e = $r->{paths}{$path} or return -ENOENT();

    my $isdir  = $e->{type} eq 'directory';
    my $islink = $e->{type} eq 'file' && $LocalMount && -r "$LocalMount/$e->{basename}";

    my $mode = $isdir ? 0040000|0555 : ($islink ? 0120000|0777 : 0100000|0444);

    my $ctime = $e->{ctime};
    my $mtime = $e->{mtime};
    my $atime = $mtime;
    my $size  = $e->{length};

    return ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
	    $size,$atime,$mtime,$ctime,$blksize,$blocks);
}

sub list_patterns_and_die {
    while (<DATA>) {
	print;
    }
    exit -1;
}

package Recorded;
use strict;
use POSIX 'strftime';
use JSON qw(encode_json decode_json);
use WWW::Curl::Easy;
use Date::Parse 'str2time';
use XML::Simple;

use constant Templates => {
    T  => '{Title}',
    S  => '{SubTitle}',
    R  => '{Description}',
    C  => '{Category}',
    se => '{Season}',
    e  => '{Episode}',
    PI => '{ProgramId}',
    SI => '{SeriesId}',
    st => '{Stars}',
    U  => '{Recording}{RecGroup}',
    hn => '{HostName}',
    c  => '{Channel}{ChanId}',
    cc => '{Channel}{CallSign}',
    cN => '{Channel}{ChannelName}',
    cn => '{Channel}{ChanNum}',

    y  => '%y{StartTime}',
    Y  => '%Y{StartTime}',
    n  => '%m{StartTime}',  # we don't do the non-leading 0 bit
    m  => '%m{StartTime}',
    j  => '%e{StartTime}',
    d  => '%d{StartTime}',
    g  => '%I{StartTime}',
    G  => '%H{StartTime}',
    h  => '%I{StartTime}',
    H  => '%H{StartTime}',
    i  => '%M{StartTime}',
    s  => '%S{StartTime}',
    a  => '%P{StartTime}',
    A  => '%p{StartTime}',
    b  => '%b{StartTime}',
    B  => '%B{StartTime}',

    ey  => '%y{EndTime}',
    eY  => '%Y{EndTime}',
    en  => '%m{EndTime}',
    em  => '%m{EndTime}',
    ej  => '%e{EndTime}',
    ed  => '%d{EndTime}',
    eg  => '%I{EndTime}',
    eG  => '%H{EndTime}',
    eh  => '%I{EndTime}',
    eH  => '%H{EndTime}',
    ei  => '%M{EndTime}',
    es  => '%S{EndTime}',
    ea  => '%P{EndTime}',
    eA  => '%p{EndTime}',
    eb  => '%b{EndTime}',
    eB  => '%B{EndTime}',

    # the API doesn't distinguish between program start time and recording start time
    py  => '%y{StartTime}',
    pY  => '%Y{StartTime}',
    pn  => '%m{StartTime}',
    pm  => '%m{StartTime}',
    pj  => '%e{StartTime}',
    pd  => '%d{StartTime}',
    pg  => '%I{StartTime}',
    pG  => '%H{StartTime}',
    ph  => '%I{StartTime}',
    pH  => '%H{StartTime}',
    pi  => '%M{StartTime}',
    ps  => '%S{StartTime}',
    pa  => '%P{StartTime}',
    pA  => '%p{StartTime}',
    pb  => '%b{StartTime}',
    pB  => '%B{StartTime}',

    pey  => '%y{EndTime}',
    peY  => '%Y{EndTime}',
    pen  => '%m{EndTime}',
    pem  => '%m{EndTime}',
    pej  => '%e{EndTime}',
    ped  => '%d{EndTime}',
    peg  => '%I{EndTime}',
    peG  => '%H{EndTime}',
    peh  => '%I{EndTime}',
    peH  => '%H{EndTime}',
    pei  => '%M{EndTime}',
    pes  => '%S{EndTime}',
    pea  => '%P{EndTime}',
    peA  => '%p{EndTime}',
    peb  => '%b{EndTime}',
    peB  => '%B{EndTime}',

    oy   => '%y{Airdate}',
    oY   => '%Y{Airdate}',
    on   => '%m{Airdate}', # we don't do the non-leading 0 bit
    om   => '%m{Airdate}',
    oj   => '%e{Airdate}',
    od   => '%d{Airdate}',
    ob   => '%b{Airdate}',
    oB   => '%B{Airdate}',

    '%'  => '%',
    };

# cache entries for 10 minutes
# this means that new recordings won't show up in the file system for up to this long
sub new {
    my $class = shift;
    my $pattern = shift;

    return bless {
	pattern => $pattern,
	cache   => undef,
	mtime   => 0,
    },ref $class || $class;
}

sub cache {
    my $self = shift;
    $self->{cache} = shift if @_;
    return $self->{cache};
}

sub mtime {
    my $self = shift;
    $self->{mtime} = shift if @_;
    return $self->{mtime};
}

sub get_recorded {
    my $self = shift;
    my $nocache = shift;
    
    my $cache = $self->cache;

    return $cache if $cache && $nocache;

    $Recorded->_refresh_recorded if !$HasIThreads && (time() - $Cache{mtime} >= $CacheTime);
    return $cache if $cache && $self->mtime >= $Cache{mtime};

    warn scalar localtime()," refreshing thread-level cache, mtime = $Cache{mtime}\n" if $Debug;
    lock %Cache;
    $self->mtime($Cache{mtime});
    return $self->cache(decode_json($Cache{recorded}||''));
}

sub recording2path {
    my $self = shift;
    my $recording = shift;
    my $path     = $self->apply_pattern($recording);
    my @components = split '/',$path;

    # trimming operation
    if ($Delimiter) {
	foreach (@components) {
	    s/${Delimiter}{2,}/$Delimiter/g;
	    s/$Delimiter$//;
	}
    }

    return grep {length} @components;
}

sub apply_pattern {
    my $self = shift;
    my $recording = shift;
    no warnings;

    my $pat_sub   = $self->_compile_pattern_sub();
    my $template  = $self->{pattern};

    my $Templates = Templates();
    my @codes     = sort {length($b)<=>length($a)} keys %$Templates;
    my $match     = join('|',@codes);

    $template =~ s/%($match)/$pat_sub->($recording,$1)/eg;
    return $template;
}

sub _compile_pattern_sub {
    my $self = shift;
    return $self->{pattern_sub} if $self->{pattern_sub};

    my $template = $self->{pattern};
    my $Templates= Templates();

    my $sub = "sub {\n";
    $sub   .= "my (\$recording,\$code) = \@_;\n";

    while ($template =~ /%([a-zA-Z%]{1,3})/g) {
	my $code = $1;
	my $field = $Templates->{$code} or next;
	if ($field eq '%') {
	    $sub .= "return '%' if \$code eq '$code';\n";
	    next;
	}
	if ($field =~ /(%\w+)(\{\w+\})/) { #datetime specifier
	    $sub .= "return strftime('$1',localtime(str2time(\$recording->$2)||0)) if \$code eq '$code';\n";
	    next;
	}
	$sub .= <<END;
if (\$code eq '$code') {
    my \$val = \$recording->$field || '';
    \$val =~ tr!a-zA-Z0-9_.,&\@:* ^\\![]{}(),?#\$=+%-!_!c;
    return \$val;
}
END
    ;
    }
    $sub .= "}\n";
    my $s = eval $sub;
    die $@ if $@;
    return $self->{pattern_sub} = $s;
}

sub _refresh_recorded {
    my $self = shift;

    print  STDERR scalar(localtime())," Refreshing recording list..." if $Debug;

    lock %Cache;
    my $var    = {};
    my $parser = XML::Simple->new(SuppressEmpty=>1);

    my $data;
    my $curl = WWW::Curl::Easy->new;
    $curl->setopt(CURLOPT_URL,"http://$Host:6544/Dvr/GetRecordedList");
    $curl->setopt(CURLOPT_WRITEDATA,\$data);
    if ((my $retcode = $curl->perform) != 0) {
	warn "failed with ",$curl->strerror($retcode),' ',$curl->errbuf;
	return;
    } elsif ((my $response = $curl->getinfo(CURLINFO_RESPONSE_CODE)) !~ /^2\d\d/) {
	warn "failed with response code: $response";
	return;
    }
    
    my $rec = $parser->XMLin($data);
    $self->_build_directory_map($rec,$var);
    $Cache{recorded} = encode_json($var);
    $Cache{mtime}    = time();
    print STDERR "mtime set to $Cache{mtime}\n" if $Debug;
}

sub _build_directory_map {
    my $self = shift;
    my ($rec,$map) = @_;

    my $count = 0;
    my (%recordings,%paths);
    for my $r (@{$rec->{Programs}{Program}}) {
	$count++;

	my $sg = $r->{Recording}{StorageGroup};
	next if $sg eq 'LiveTV';

 	my (@path)              = $self->recording2path($r);
	my $key                 = join('-',$r->{HostName},$r->{FileName});  # we use this as our unique ID
	my $path                = join('/',@path);
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
            my $start = $recordings{$key}{meta}{StartTime};
	    $start =~ s/:\d+Z$//;
            
	    my $fixed_path = sprintf("%s_%s-%s",$path,$recordings{$key}{meta}{Channel}{ChanNum},$start);
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

    print STDERR scalar keys %recordings," recordings retrieved..." if $Debug;
    return $map;
}

__END__
The following substitution patterns can be used in recording paths.

    %T   = Title (show name)
    %S   = Subtitle (episode name)
    %R   = Description
    %C   = Category
    %U   = RecGroup
    %hn  = Hostname of the machine where the file resides
    %PI  = Program ID
    %SI  = Series ID
    %st  = Stars
    %c   = Channel:  MythTV chanid
    %cn  = Channel:  channum
    %cc  = Channel:  callsign
    %cN  = Channel:  channel name
    %y   = Recording start time:  year, 2 digits
    %Y   = Recording start time:  year, 4 digits
    %m   = Recording start time:  month, leading zero
    %b   = Recording start time:  abbreviated month name
    %B   = Recording start time:  full month name
    %d   = Recording start time:  day of month, leading zero
    %h   = Recording start time:  12-hour hour, with leading zero
    %H   = Recording start time:  24-hour hour, with leading zero
    %i   = Recording start time:  minutes
    %s   = Recording start time:  seconds
    %a   = Recording start time:  am/pm
    %A   = Recording start time:  AM/PM
    %ey  = Recording end time:  year, 2 digits
    %eY  = Recording end time:  year, 4 digits
    %em  = Recording end time:  month, leading zero
    %eb  = Recording end time:  abbreviated month name
    %eB  = Recording end time:  full month name
    %ej  = Recording end time:  day of month
    %ed  = Recording end time:  day of month, leading zero
    %eh  = Recording end time:  12-hour hour, with leading zero
    %eH  = Recording end time:  24-hour hour, with leading zero
    %ei  = Recording end time:  minutes
    %es  = Recording end time:  seconds
    %ea  = Recording end time:  am/pm
    %eA  = Recording end time:  AM/PM
    %py  = Program start time:  year, 2 digits
    %pY  = Program start time:  year, 4 digits
    %pm  = Program start time:  month, leading zero
    %pb  = Program start time:  abbreviated month name
    %pB  = Program start time:  full month name
    %pj  = Program start time:  day of month
    %pd  = Program start time:  day of month, leading zero
    %ph  = Program start time:  12-hour hour, with leading zero
    %pH  = Program start time:  24-hour hour, with leading zero
    %pi  = Program start time:  minutes
    %ps  = Program start time:  seconds
    %pa  = Program start time:  am/pm
    %pA  = Program start time:  AM/PM
    %pey = Program end time:  year, 2 digits
    %peY = Program end time:  year, 4 digits
    %pem = Program end time:  month, leading zero
    %peb = Program end time:  abbreviated month name
    %peB = Program end time:  full month name
    %pej = Program end time:  day of month
    %ped = Program end time:  day of month, leading zero
    %peh = Program end time:  12-hour hour, with leading zero
    %peH = Program end time:  24-hour hour, with leading zero
    %pei = Program end time:  minutes
    %pes = Program end time:  seconds
    %pea = Program end time:  am/pm
    %peA = Program end time:  AM/PM
    %oy  = Original Airdate:  year, 2 digits
    %oY  = Original Airdate:  year, 4 digits
    %om  = Original Airdate:  month, leading zero
    %ob  = Original Airdate:  abbreviated month name
    %oB  = Original Airdate:  full month name
    %oj  = Original Airdate:  day of month
    %od  = Original Airdate:  day of month, leading zero
    %%   = a literal % character
 
