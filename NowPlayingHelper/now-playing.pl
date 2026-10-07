#!/usr/bin/perl
# Runs Liland's Now Playing helper inside Perl, a system program that macOS still lets
# use MediaRemote (see NowPlayingHelper.m). Adapted from mediaremote-adapter by
# Jonas van den Berg and contributors (BSD 3-Clause, see LICENSE).
#
# Usage: now-playing.pl /path/to/NowPlayingHelper.framework stream
#        now-playing.pl /path/to/NowPlayingHelper.framework command NAME [VALUE]

use strict;
use warnings;
use DynaLoader;

my ($framework, $function) = @ARGV;
die "Usage: $0 FRAMEWORK stream|command [NAME [VALUE]]\n"
  unless defined $function && ($function eq "stream" || $function eq "command");

my ($name) = $framework =~ m{([^/]+)\.framework/?$} or die "Not a framework: $framework\n";
my $handle = DynaLoader::dl_load_file("$framework/$name", 0)
  or die "Could not load $framework: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "liland_$function")
  or die "No liland_$function in $framework\n";

DynaLoader::dl_install_xsub("main::run", $symbol);
run();
