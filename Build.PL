#!/usr/bin/perl

use strict;
use warnings;
use Module::Build;

my $build = Module::Build->new(
    module_name       => 'Mythfs-perl',
    license           => 'perl',
    dist_version_from => 'bin/mythfs.pl',
    dist_abstract     => 'Mount MythTV recordings as a file system',
    dist_author       => 'Lincoln Stein <lincoln.stein@oicr.on.ca>',
    configure_requires => { 'Module::Build' => 0 },
    requires          => {
      'Fuse'         => '0.09',
      'WWW::Curl'    => '4.15',
      'Date::Parse'  => '2.30',
      'XML::Simple'  => '2.18',
      'JSON'         => 0,
      'threads'      => 0,
    },
    build_class        => 'Module::Build',
    );

$build->create_build_script;
exit 0;
