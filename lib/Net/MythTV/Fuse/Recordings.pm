package Net::MythTV::Fuse::Recordings;

use strict;
use POSIX 'strftime';
use HTTP::Lite;
use JSON qw(encode_json decode_json);
use Date::Parse 'str2time';
use XML::Simple;
use threads;
use threads::shared;
use Config;
use Carp 'croak';

my %Cache    :shared;
my $Package = __PACKAGE__;

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

foreach (qw(debug backend port dummy_data cache cachetime threaded
            pattern deliiter mtime)) {
    eval <<END;
sub ${Package}::${_} {
    my \$self = shift;
    \$self->{$_} = shift if \@_;
    return \$self->{$_};
}
END
}



sub new {
    my $class   = shift;
    my $backend = shift or croak "Usage: $class->new(\$backend_hostname)";

    my $self =  bless {
	backend   => $backend,
	port      => 6544,
	pattern   => '%T/%S',
	cachetime => 60*10,
	threaded  => $Config{useithreads},
	delimiter => undef,
	debug     => 0,
	mtime     => 0,
	cache     => undef,
    },ref $class || $class;

    return $self;
}

sub load_dummy_data {
    my $self = shift;
    my $dummy_data_path = shift;
    open my $fh,$dummy_data_path or croak "$dummy_data_path: $!";
    local $/;
    my $dummy_data = <$fh>;
    $self->dummy_data($dummy_data) if $dummy_data;
}

sub start_update_thread {
    my $self = shift;

    $self->_refresh_recorded 
	or croak "Could not contact backend at ",$self->backend,':',$self->port;
    return unless $self->threaded;
    my $thr = threads->create(
	sub {
	    while (1) {
		sleep ($self->cachetime);
		$self->_refresh_recorded;
	    }
	}
	);
    $thr->detach();
}

sub get_recorded {
    my $self = shift;
    my $nocache = shift;
    
    my $cache = $self->cache;

    return $cache if $cache && $nocache;

    $self->_refresh_recorded if !$self->threaded && (time() - $Cache{mtime} >= $self->cachetime);
    return $cache            if $cache && $self->mtime >= $Cache{mtime};

    warn scalar localtime()," refreshing thread-level cache, mtime = $Cache{mtime}\n" if $self->debug;
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
    if (my $delimiter = $self->delimiter) {
	foreach (@components) {
	    s/${delimiter}{2,}/$delimiter/g;
	    s/${delimiter}(\s+)/$1/g;
	    s/$delimiter$//;
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

    print  STDERR scalar(localtime())," Refreshing recording list..." if $self->debug;

    lock %Cache;
    my $var    = {};
    my $parser = XML::Simple->new(SuppressEmpty=>1);
    my $data = $self->_fetch_recorded_data() or return;
    my $rec = $parser->XMLin($data);
    $self->_build_directory_map($rec,$var);
    $Cache{recorded} = encode_json($var);
    $Cache{mtime}    = time();
    print STDERR "mtime set to $Cache{mtime}\n" if $self->debug;

    return 1;
}

sub _fetch_recorded_data {
    my $self = shift;

    return $self->_dummy_data if $self->_dummy_data;

    my $host = $self->backend;
    my $port = $self->port;

    my $http     = HTTP::Lite->new;
    my $retcode  = $http->request("http://$host:$port/Dvr/GetRecordedList");
    unless ($retcode && $retcode =~ /^2\d\d/) {
	warn "request failed with $retcode ",$http->status_message;
	return;
    }

    return $http->body;
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
	$map->{paths}{$path}{host}     = $meta->{HostName};
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

    print STDERR scalar keys %recordings," recordings retrieved..." if $self->debug;
    return $map;
}

