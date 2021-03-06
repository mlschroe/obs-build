################################################################
#
# Copyright (c) 2017 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package Build::Docker;

use Build::SimpleXML;	# to parse the annotation
use Build::SimpleJSON;

use strict;

sub slurp {
  my ($fn) = @_;
  local *F;
  return undef unless open(F, '<', $fn);
  local $/ = undef;	# Perl slurp mode
  my $content = <F>;
  close F;
  return $content;
}

sub quote {
  my ($str, $q, $vars) = @_;
  if ($q ne "'" && $str =~ /\$/) {
    $str =~ s/\$([a-zA-Z0-9_]+|\{([^\}]+)\})/join(' ', @{$vars->{$2 || $1} || []})/ge;
  }
  $str =~ s/([ \t\"\'\$\(\)])/sprintf("%%%02X", ord($1))/ge;
  return $str;
}

sub addrepo {
  my ($ret, $url, $prio) = @_;

  unshift @{$ret->{'imagerepos'}}, { 'url' => $url };
  $ret->{'imagerepos'}->[0]->{'priority'} = $prio if defined $prio;
  if ($Build::Kiwi::urlmapper) {
    my $prp = $Build::Kiwi::urlmapper->($url);
    if (!$prp) {
      $ret->{'error'} = "cannot map '$url' to obs";
      return undef;
    }
    my ($projid, $repoid) = split('/', $prp, 2);
    unshift @{$ret->{'path'}}, {'project' => $projid, 'repository' => $repoid};
    $ret->{'path'}->[0]->{'priority'} = $prio if defined $prio;
    return 1;
  } else {
    # this is just for testing purposes...
    $url =~ s/^\/+$//;
    $url =~ s/:\//:/g;
    my @url = split('/', $url);
    unshift @{$ret->{'path'}}, {'project' => $url[-2], 'repository' => $url[-1]} if @url >= 2;
    $ret->{'path'}->[0]->{'priority'} = $prio if defined $prio;
    return 1;
  }
}

sub cmd_zypper {
  my ($ret, @args) = @_;
  # skip global options
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'in' || $args[0] eq 'install') {
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      shift @args if $args[0] =~ /^--(?:from|repo|type)$/ || $args[0] =~ /^-[tr]$/;
      shift @args;
    }
    my @deps = grep {/^[a-zA-Z_0-9]/} @args;
    s/^([^<=>]+)([<=>]+)/$1 $2 / for @deps;
    push @{$ret->{'deps'}}, @deps;
  } elsif ($args[0] eq 'ar' || $args[0] eq 'addrepo') {
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      shift @args if $args[0] =~ /^--(?:repo|type)$/ || $args[0] =~ /^-[rt]$/;
      shift @args;
    }
    if (@args) {
      my $path = $args[0];
      $path =~ s/\/[^\/]*\.repo$//;
      addrepo($ret, $path);
    }
  }
}

sub cmd_obs_pkg_mgr {
  my ($ret, @args) = @_;
  return unless @args;
  if ($args[0] eq 'add_repo') {
    shift @args;
    addrepo($ret, $args[0]) if @args;
  } elsif ($args[0] eq 'install') {
    shift @args;
    push @{$ret->{'deps'}}, @args;
  }
}

sub cmd_dnf {
  my ($ret, @args) = @_;
  # skip global options
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'in' || $args[0] eq 'install') {
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      shift @args;
    }
    push @{$ret->{'deps'}}, grep {/^[a-zA-Z_0-9]/} @args;
  }
}

sub cmd_apt_get {
  my ($ret, @args) = @_;
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'install') {
    shift @args;
    push @{$ret->{'deps'}}, grep {/^[a-zA-Z_0-9]/} @args;
  }
}

sub parse {
  my ($cf, $fn) = @_;

  my $basecontainer;
  my $unorderedrepos;
  my $useobsrepositories;
  my $nosquash;
  my $dockerfile_data = slurp($fn);
  return { 'error' => 'could not open Dockerfile' } unless defined $dockerfile_data;

  my @lines = split(/\r?\n/, $dockerfile_data);
  my $ret = {
    'name' => 'docker',
    'deps' => [],
    'path' => [],
    'imagerepos' => [],
  };

  while (@lines) {
    my $line = shift @lines;
    $line =~ s/^\s+//;
    if ($line =~ /^#/) {
      if ($line =~ /^#!BuildTag:\s*(.*?)$/) {
	my @tags = split(' ', $1);
	push @{$ret->{'containertags'}}, @tags if @tags;
      }
      if ($line =~ /^#!BuildVersion:\s*(\S+)\s*$/) {
	$ret->{'version'} = $1;
      }
      if ($line =~ /^#!UnorderedRepos\s*$/) {
        $unorderedrepos = 1;
      }
      if ($line =~ /^#!UseOBSRepositories\s*$/) {
        $useobsrepositories = 1;
      }
      if ($line =~ /^#!NoSquash\s*$/) {
        $nosquash = 1;
      }
      next;
    }
    # add continuation lines
    while (@lines && $line =~ s/\\[ \t]*$//) {
      shift @lines while @lines && $lines[0] =~ /^\s*#/;
      $line .= shift(@lines) if @lines;
    }
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    next unless $line;
    my ($cmd, @args);
    ($cmd, $line) = split(' ', $line, 2);
    $cmd = uc($cmd);
    my $vars = {};
    # split line into args
    $line =~ s/%/%25/g;
    $line =~ s/\\(.)/sprintf("%%%02X", ord($1))/ge;
    while ($line =~ /([\"\'])/) {
      my $q = $1;
      last unless $line =~ s/$q(.*?)$q/quote($1, $q, $vars)/e;
    }
    if ($line =~ /\$/) {
      $line =~ s/\$([a-zA-Z0-9_]+|\{([^\}]+)\})/join(' ', @{$vars->{$2 || $1} || []})/ge;
    }
    @args = split(/[ \t]+/, $line);
    s/%([a-fA-F0-9]{2})/chr(hex($1))/ge for @args;
    if ($cmd eq 'FROM') {
      if (@args && !$basecontainer && $args[0] ne 'scratch') {
        $basecontainer = $args[0];
        $basecontainer .= ':latest' unless $basecontainer =~ /:[^:\/]+$/;
      }
    } elsif ($cmd eq 'RUN') {
      $line =~ s/#.*//;	# get rid of comments
      for my $l (split(/(?:\||\|\||\&|\&\&|;|\)|\()/, $line)) {
	$l =~ s/^\s+//;
	$l =~ s/\s+$//;
        @args = split(/[ \t]+/, $l);
	s/%([a-fA-F0-9]{2})/chr(hex($1))/ge for @args;
	next unless @args;
	my $rcmd = shift @args;
	if ($rcmd eq 'zypper') {
	  cmd_zypper($ret, @args);
	} elsif ($rcmd eq 'yum' || $rcmd eq 'dnf') {
	  cmd_dnf($ret, @args);
	} elsif ($rcmd eq 'apt-get') {
	  cmd_apt_get($ret, @args);
	} elsif ($rcmd eq 'obs_pkg_mgr') {
	  cmd_obs_pkg_mgr($ret, @args);
	}
      }
    }
  }
  push @{$ret->{'deps'}}, "container:$basecontainer" if $basecontainer;
  push @{$ret->{'deps'}}, '--unorderedimagerepos' if $unorderedrepos;
  my $version = $ret->{'version'};
  my $release = $cf->{'buildrelease'};
  for (@{$ret->{'containertags'} || []}) {
    s/<VERSION>/$version/g if defined $version;
    s/<RELEASE>/$release/g if defined $release;
  }
  $ret->{'path'} = [ { 'project' => '_obsrepositories', 'repository' => '' } ] if $useobsrepositories;
  $ret->{'basecontainer'} = $basecontainer if $basecontainer;
  $ret->{'nosquash'} = 1 if $nosquash;
  return $ret;
}

sub showcontainerinfo {
  my ($disturl, $release);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--disturl') {
      (undef, $disturl) = splice(@ARGV, 0, 2); 
    } elsif (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2); 
    } else {
      last;
    }   
  }
  my ($fn, $image, $taglist, $annotationfile) = @ARGV;
  local $Build::Kiwi::urlmapper = sub { return $_[0] };
  my $cf = {};
  $cf->{'buildrelease'} = $release if defined $release;
  my $d = {};
  $d = parse($cf, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};
  $image =~ s/.*\/// if defined $image;
  my @tags = split(' ', $taglist);
  for (@tags) {
    $_ .= ':latest' unless /:[^:\/]+$/;
    if (/:([0-9][^:]*)$/) {
      $d->{'version'} = $1 unless defined $d->{'version'};
    }
  }
  my @repos = @{$d->{'imagerepos'} || []};
  if ($annotationfile) {
    my $annotation = slurp($annotationfile);
    $annotation = Build::SimpleXML::parse($annotation) if $annotation;
    $annotation = $annotation && ref($annotation) eq 'HASH' ? $annotation->{'annotation'} : undef;
    $annotation = $annotation && ref($annotation) eq 'ARRAY' ? $annotation->[0] : undef;
    my $annorepos = $annotation && ref($annotation) eq 'HASH' ? $annotation->{'repo'} : undef;
    $annorepos = undef unless $annorepos && ref($annorepos) eq 'ARRAY';
    for my $annorepo (@{$annorepos || []}) {
      next unless $annorepo && ref($annorepo) eq 'HASH' && $annorepo->{'url'};
      push @repos, { 'url' => $annorepo->{'url'}, '_type' => {'priority' => 'number'} };
      $repos[-1]->{'priority'} = $annorepo->{'priority'} if defined $annorepo->{'priority'};
    }
  }
  my $buildtime = time();
  my $containerinfo = {
    'buildtime' => $buildtime,
    '_type' => {'buildtime' => 'number'},
  };
  $containerinfo->{'tags'} = \@tags if @tags;
  $containerinfo->{'repos'} = \@repos if @repos;
  $containerinfo->{'file'} = $image if defined $image;
  $containerinfo->{'disturl'} = $disturl if defined $disturl;
  $containerinfo->{'version'} = $d->{'version'} if defined $d->{'version'};
  $containerinfo->{'release'} = $release if defined $release;
  print Build::SimpleJSON::unparse($containerinfo)."\n";
}

sub show {
  my ($release);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2); 
    } else {
      last;
    }   
  }
  my ($fn, $field) = @ARGV;
  local $Build::Kiwi::urlmapper = sub { return $_[0] };
  my $cf = {};
  $cf->{'buildrelease'} = $release if defined $release;
  my $d = {};
  $d = parse($cf, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

1;
