#! /usr/bin/perl

#** @file git_modules_to_json.pl
# @brief Build tree of json files for the web site api to read.
#
# Scans the FreeRADIUS git repository for all sorts of goodies and writes it
# out in json files for the lua API to read.
#
# Written in perl to make Arran happy.
#
# @author Matthew Newton
# @date 2017-07-11
#*

use strict;
use Data::Dumper;
use File::Path qw(make_path);
use JSON;

use Git::Repository;

my $gitdir = "/srv/freeradius-server";
my $outdir = "/tmp/wsbuild"; # TODO make this a temp dir and then move into place

my $repo = Git::Repository->new( work_tree => $gitdir );


my $RELBRANCHES = [
	{
		# release means find the latest release tag for this branch
		type => "release",
		branch => "3.0.x",
		description => "Latest stable branch",
		status => "stable",
	},
	{
		type => "release",
		branch => "2.x.x",
		description => "Old stable branch",
		status => "end of life",
	},
	{
		type => "release",
		branch => "1.x.x",
		description => "Obsolete stable branch",
		status => "obsolete",
	},
	{
		type => "release",
		branch => "0.x.x",
		description => "Obsolete stable branch",
		status => "obsolete",
	},
	{
		# development means just download this actual branch HEAD
		type => "development",
		branch => "4.0.x",
		description => "Development branch",
		status => "development",
	},
];


#** @function component_url ($component)
# @brief Get relative URL for a component
#
# @params $component	Module or protocol name
#
# @retval $url		Relative URL
#*

sub component_url
{
	my $component = shift;

	return "/api/info/component/$component/";
}


#** @function version_compare ($version_a, $version_b)
# @brief Compare two version numbers
#
# Equivalent to perl's "<=>" and "cmp" operators for FreeRADIUS version
# numbers. Given two version numbers (e.g. "3.0.5" and "2.2.8") returns -1, 0
# or 1 depending on whether the first is less than, equal to or greater than
# the second.
#
# @params $version_a	Version number
# @params $version_b	Version number
#
# @retval $cmp		-1, 0 or 1
#*

sub version_compare
{
	my ($va, $vb) = @_;

	# $va and $vb are in the form "1.2.3"
	#
	my @sa = split /\./, $va;
	my @sb = split /\./, $vb;

	# go through each component of the version number, if they are the
	# same then jump to the next, otherwise comparison can stop here.
	#
	for (my $i = 0; $i < 3; $i++) {
		# do a string comparison to see if they're the same
		# (we sometimes have 'x', so not numerical here)
		next if $sa[$i] eq $sb[$i];

		# they're not both 'x', so if one is then it's newer
		return 1 if $sa[$i] eq "x";
		return -1 if $sb[$i] eq "x";

		# must be numbers then, so just do a numerical comparison
		return $sa[$i] <=> $sb[$i];
	}

	# both versions are the same
	#
	return 0;
}


#** @function get_component_readme ($repo, $blob)
# @brief Retrieve component README.md and parse it
#
# Given a git blob of a README.md file, pulls it from the git repository and
# parses it into a usable data structure.
#
# README.md file format is "# module_name" on the first line, followed by
# sections delimited by "## section_name".
#
# @params $repo		Git::Repository reference
# @params $blob		Git blob
#
# @retval $readme	Hash reference of README data
#*

sub get_component_readme
{
	my ($repo, $blob) = @_;
	my $readme = {};

	# read the blob from git
	#
	my $data = $repo->command("show" => $blob)->stdout;
	return undef unless $data;

	#my @lines;
	my $state = "header";
	my $sectionname;
	my $sectiondata;

	while (my $line = $data->getline()) {
		chomp $line;
		#push @lines, $line;

		# at the start, look for a header with a module name
		#
		if ($state eq "header") {
			next if ($line =~ /^\s*$/);

			unless ($line =~ /^#\s+([a-z0-9_]+)$/) {
				die "malformed README header '$line'\n";
			}
			$$readme{componentname} = $1;
			$state = "section";
			next;
		}

		if ($state eq "section") {
			if ($line =~ /^##\s+([A-Za-z]+)$/) {
				if ($sectionname) {
					$$readme{lc $sectionname} = $sectiondata;
				}

				$sectionname = $1;
				$sectiondata = "";
				$state = "section";
				next;
			}
		}

		if ($state eq "section") {
			$sectiondata .= "$line\n";
		}
	}

	if ($state eq "section" and $sectionname) {
		$$readme{lc $sectionname} = $sectiondata;
	}

	return $readme;
}


#** @function get_versions ($repo)
# @brief Get all release tags and dev branches from the git repository
#
# Scans the git repository for all standard development branches and release
# tags (that begin 'release_') and returns them in a hash where the keys are
# the version number and the values are the release tag and type of branch.
#
# @params $repo		Git::Repository reference
#
# @retval $%versions	Hash reference of version => hashref of branch and type
#*

sub get_versions
{
	my $repo = shift;

	# get all tags
	#
	my @tags = map {chomp $_; $_}
		$repo->command("tag" => '-l')->stdout->getlines();

	# get version number of all tags and put into hash
	#
	my %versions = map {/^release_(\d+)_(\d+)_(\d+)$/ ?
		("$1.$2.$3", {tag => $_, type => "release", version => "$1.$2.$3"}) :
		()} @tags;

	# find all branches, to see what's in development
	#
	my @branches = map {chomp $_; $_}
		$repo->command("branch" => '-a')->stdout->getlines();

	# if the branches are "public facing" ones then add them to the hash
	#
	foreach my $branch (@branches) {
		if ($branch =~ /^[\s\*]+((?:remotes\/origin\/)?v(\d+\.(?:\d+|x)\.x))$/) {
			$versions{$2} = {
				tag => $1,
				type => "development",
				version => $2,
			};
		}
	}

	return \%versions;
}


#** @function version_is_in_branch ($version, $branch)
# @brief Check to see if this version is in this branch
#
# Does the version number match the branch? e.g. 3.0.14 matches branch 3.0.x,
# but does not match 3.1.x or 2.x.x. Basically treat 'x' as a wildcard and
# everything else must match.
#
# @params $version	A FreeRADIUS version number
# @prarms $branch	A FreeRADIUS branch number
#
# @retval $yes		1 if this version is in the branch, else 0
#*

sub version_is_in_branch
{
	my ($version, $branch) = @_;

	# split version and branch into components
	#
	my @vc = split /\./, $version;
	my @bc = split /\./, $branch;

	# go through each component of the version number, if they are the
	# same then jump to the next, otherwise comparison can stop here.
	#
	for (my $i = 0; $i < 3; $i++) {
		# keep going if component is the same
		next if $vc[$i] eq $bc[$i];

		# keep going if branch component is 'x'
		next if $bc[$i] eq "x";

		# version number shoulnd't contain 'x', but may as well to enable
		# comparing branch numbers too
		next if $vc[$i] eq "x";

		# they don't match, and are not 'x'
		return 0;
	}

	# version matches the branch
	#
	return 1;
}


#** @function add_versions_to_branches ($relbranches, $versions)
# @brief Add versions to the release branch hash
#
# Scan through all versions in $versions and assign them to a particular
# branch in $relbranches, if possible.
#
# @params $@relbranches	All branches we're interested in for the web site
# @prarms $%versions	All versions found in the git repository
#*

sub add_versions_to_branches
{
	my ($relbranches, $versions) = @_;

	foreach my $branch (@$relbranches) {
		$$branch{releases} = [];

		foreach my $version (keys %$versions) {
			if (version_is_in_branch($version, $$branch{branch})) {
				push @{$$branch{releases}}, $$versions{$version};
				$$versions{$version}{branch} = $branch;
			}
		}
	}
}


#** @function get_release_components ($repo, $reltag)
# @brief Get all components included in a particular release
#
# Looks at all directories under src/modules in a given release and returns a
# hash of all modules. Key is the module name, and value is a hash with the
# module name, parent module name (e.g. rlm_sql for rlm_sql_sqlite) and readme
# for the module if available.
#
# @params $repo		Git::Repository reference
# @params $versioninfo	Hash reference of tag name and type (devel or release)
#
# @retval $%modules	Hash reference of module name => module information
#*

sub get_release_components
{
	my ($repo, $versioninfo) = @_;

	my $reltag = $$versioninfo{tag};

	# run git ls-tree to find all subdirectories of src/modules for a
	# particular git tag, and get the data as an array of hashes
	#
	my $trees = $repo->command("ls-tree" => "-rt", "$reltag", "src/modules/")->stdout;
	my @objects = grep {$$_{path} =~ /^src\/modules\// and
				($$_{type} eq "tree" or $$_{path} =~ m+/README.md$+)}
		map {my @x = split /\s+/; {
			mode => $x[0],
			type => $x[1],
			hash => $x[2],
			path => $x[3],
		}}
		$trees->getlines();

	# new data structure to hold all the component details in
	my $components = {};

	# go through each git object and work out which modules exist
	foreach my $o (@objects) {
		next unless $$o{path} =~ m+^src/modules/+;

		my @nodes = split /\//, $$o{path};

		# get the relevant module name
		#
		my $name;
		if ($$o{type} eq "tree") {
			# the main module name will always be at the end of the path
			# and begin with rlm_ or proto_
			$name = $nodes[$#nodes];
		} else {
			# we only care about README files, so short circuit if not
			next unless $nodes[$#nodes] eq "README.md";
			$name = $nodes[$#nodes-1];
		}

		# only interested in certain directories
		#
		next unless $name =~ /^(rlm|proto)_/;

		my $component = $components->{$name} || {};
		$component->{name} = $name;

		# find the parent for submodules
		#
		if ($$o{type} eq "tree" and $#nodes > 2) {
			$component->{parent} = @nodes[2];
		}

		# get the module readme
		#
		if ($$o{type} eq "blob") {
			$component->{readmeblob} = $$o{hash};
		}

		$components->{$name} = $component;
	}

	return $components;
}


#** @function build_component_repository ($components, $modules, $versioninfo, $relbranches)
# @brief Add data about modules in a release to component repository
#
# Takes information about modules in a particular release and builds up
# a "component repository" which contains data about all modules and which
# releases they are included in.
#
# @params $%components	Component repository
# @params $%relcomp	Data as returned from get_release_components
# @params $%versioninfo	Hashref with version information for these modules
# @params $%relbranches	Branches available
#
# @retval $%components	Component repository
#*

sub build_component_repository
{
	my ($components, $relcomp, $versioninfo, $relbranches) = @_;

	my $release = $$versioninfo{version};

	# go through all new modules and protocoles and add to the main
	# component repository as required, tracking release numbers
	#
	foreach my $component (keys %$relcomp) {
		unless (defined $$components{$component}) {
			$$components{$component} = {
				name => $component,
				minrelease => $release,
				maxrelease => $release,
				maxdevrelease => $release,
				branches => {},
			};
		}

		my $mrm = $$components{$component};

		# track minimum and maximum released versions for this module
		#
		# If the version we are comparing is a released version, then
		# that takes all precedence so we only show released versions
		# on the web site (e.g. from version 1.1.0 to 3.0.15, even
		# though the module is also in version 4.0.x under development.
		# However, if the module is *only* in development versions
		# (say, 3.1.x and 4.0.x) then show the minimum and maximum
		# versions of that instead so that the module gets listed.
		#
		# In either case, the README.md is always taken from the very
		# latest development version of the server.
		#
		if ($$versioninfo{type} eq "release") {
			if ($$mrm{minrelease} =~ /x/ or version_compare($$mrm{minrelease}, $release) > 0) {
				$$mrm{minrelease} = $release;
			}

			if ($$mrm{maxrelease} =~ /x/ or version_compare($$mrm{maxrelease}, $release) < 0) {
				$$mrm{maxrelease} = $release;
			}
		}
		else {
			if ($$mrm{minrelease} =~ /x/ and version_compare($$mrm{minrelease}, $release) > 0) {
				$$mrm{minrelease} = $release;
			}

			if ($$mrm{maxrelease} =~ /x/ and version_compare($$mrm{maxrelease}, $release) < 0) {
				$$mrm{maxrelease} = $release;
			}
		}

		# track latest development version, just because
		#
		$$mrm{maxdevrelease} = $release if version_compare($$mrm{maxdevrelease}, $release) < 0;


		# sanity check that parents for different versions are the same
		#
		if (defined $$mrm{parent} and
			($$mrm{parent} ne $$relcomp{$component}{parent})) {
			die "differing parents for $component";
		}

		# set the parent
		#
		if (defined $$relcomp{$component}{parent}) {
			$$mrm{parent} = $$relcomp{$component}{parent};
		}

		# set the readme version
		#
		# don't check for stable/development versions here - see comments above
		#
		if (defined $$relcomp{$component}{readmeblob}) {
			my $oldversion = $$mrm{readmeversion} || "0.0.0";
			if (version_compare($oldversion, $release) < 0) {
				$$mrm{readmeblob} = $$relcomp{$component}{readmeblob};
				$$mrm{readmeversion} = $release;
			}
		}

		# find out which branches the module appears in, and add them
		# to the branches hash
		#
		foreach my $branch (@$relbranches) {
			if (version_is_in_branch($release, $$branch{branch})) {
				$$mrm{branches}{$$branch{branch}} = $branch;
			}
		}
	}

	return $components;
}


#** @function get_readme_files ($components)
# @brief Retrieve all module README.md files
#
# Goes through the component repository and fetches all the README.md files for
# each module from the git repo. Done here rather than earlier so we only pull
# the latest README for each module. If nothing else, earlier READMEs are
# unlikely to be formatted correctly, and therefore will cause the parse sub to
# blow up.
#
# @params $repo		Git::Repository reference
# @params $%components	Component repository
#
# @retval $%components	Component repository
#*

sub get_readme_files
{
	my ($repo, $components) = @_;

	foreach my $component (sort keys %$components) {
		my $md = $$components{$component};
		next unless defined $$md{readmeblob};

		$$md{readme} = get_component_readme($repo, $$md{readmeblob});
	}
}


#** @function find_releases ($relbranches, $versions)
# @brief Find which versions are the latest in particular branches
#
# Some versions in relbranches may be "stable", but listed as e.g. 3.0.x. This
# will find the latest stable version in that train.
#
# @params $%relbranches	Branches available
# @params $%versions	All git versions and tags
#
# @retval $%relbranches	Updated release versions with branch info
#*

sub find_releases
{
	my ($relbranches, $versions) = @_;

	my $branches = [];

	# check each release version
	#
	foreach my $rv (@$relbranches) {
		my $version = $$rv{branch};

		# while development versions will be the same as listed in
		# relbranches (e.g. 4.0.x is always the HEAD of v4.0.x),
		# released versions will point to the latest dev version in
		# that train and we need find the latest released version
		# instead.
		#
		if ($$rv{type} eq "release" and $version =~ /x/) {
			my $stableversion = "0.0.0";

			# go through versions in order, remembering last stable
			# version number we've seen. quit out if we hit the
			# development version we're looking for.
			#
			foreach my $v (sort {version_compare($a, $b)} keys %$versions) {
				my $version_is_same_or_lower = (
					version_compare($v, $$rv{branch}) != 1
				);

				if ($$versions{$v}{type} eq "release" and
					$version_is_same_or_lower) {
					$stableversion = $v;
				}

				last if not $version_is_same_or_lower;
			}

			# TODO maybe we should check here to make sure the
			# version we searched for and found was actually in the
			# same train, e.g. searching for 8.1.x stable will
			# currently quite happily return release_3_0_15, which
			# probably isn't what is intended.

			$version = $stableversion;
		}

		my $tagname = $$versions{$version}{tag};
		die "unable to find version $version\n" unless defined $tagname;

		$tagname =~ s+^remotes/origin/++; # trim off remotes
		$$rv{latestversion} = $version;
		$$rv{latesttag} = $tagname;
	}

	return $relbranches;
}


#** @function get_branch_release_data ($repo, $release)
# @brief Build data structure for each release
#
# Pulls together everything needed to create a branch release JSON file.
#
# @params $repo		Git::Repository reference
# @params $%release	Hashref of release
#*

sub get_branch_release_data
{
	my ($repo, $release) = @_;

	my %json;

	my $version = $$release{version};

	# build download links
	#
	my @download = ();
	foreach my $type (qw(tar.gz tar.bz2)) {
		my %d = (
			name => $type,
			url => "ftp://ftp.freeradius.org/pub/freeradius/freeradius-server-$version.$type",
			sig_url => "ftp://ftp.freeradius.org/pub/freeradius/freeradius-server-$version.$type.sig",
		);
		push @download, \%d;
	}
	$json{download} = \@download;

	# build list of features
	#
	my @features = ();
	my %feature = (
		description => "Test feature",
		component => [
			{
				name => "rlm_always",
				url => component_url("rlm_always"),
			},
		],
	);
	push @features, \%feature;
	$json{features} = \@features;

	# build list of defects
	#
	my @defects = ();
	my %defect = (
		description => "Test issue",
		exploit => \0,
		component => [
			{
				name => "rlm_rest",
				url => component_url("rlm_rest"),
			},
		],
	);
	push @defects, \%defect;
	$json{defects} = \@defects;

	$json{name} = $$release{version};
	$json{summary} = "The focus of this release is testing";
	$json{date} = git_date($repo, $$release{tag});

	$$release{output} = \%json;
}


#** @function get_component_release_data ($repo, $component)
# @brief Build data structure for each component
#
# Pulls together everything needed to create a component JSON file.
#
# @params $repo		Git::Repository reference
# @params $%component	Hash reference of module/component data
#*

sub get_component_release_data
{
	my ($repo, $component) = @_;

	my %json;

	my @available = ();
	$json{available} = \@available;

	$json{name} = $$component{name};
	$json{description} = $$component{readme}{summary};
	$json{category} = "io"; # $$component{readme}{metadata}; # TODO XML :(
	$json{documentation_link} = ""; # TODO "http://networkradius.com/doc/current/raddb/mods-available/linelog";

	$$component{output} = \%json;
}


#** @function git_date ($repo, $branch)
# @brief Get the commit date of a git branch
#
# @params $repo		Git::Repository reference
# @params $branch	Git commit ref
#
# @retval $date		Date of commit
#*

sub git_date
{
	my ($repo, $branch) = @_;

	my $cmd = $repo->command(show => "-s",
		"--format=%cd",
		"--date=format:%Y-%m-%dT%H:%M:%SZ",
		$branch);
	my $date = $cmd->stdout->getline();
	chomp $date;

	return $date;
}

#** @function build_web_json ($relbranches, $versions, $components, $outdir)
# @brief Build JSON files for web site API
#
# Takes information in the component repository data and builds JSON files
# that are picked up by the web site Lua scripts.
#
# @params $%relbranches	Branches available
# @params $%versions	All git versions and tags
# @params $%components	Component repository
# @params $outdir	Directory to put output files
#*

sub build_web_json
{
	my ($relbranches, $versions, $components, $outdir) = @_;
	my $json = JSON->new->pretty(1);

	# shortcut to write json out to a file
	#
	sub jout
	{
		my ($fn, $js) = @_;
		open my $fh, ">", $fn;
		print $fh $json->encode($js);
		close $fh;
	}

	make_path "$outdir/branch";

	# create branch json for each release version
	#
	foreach my $rv (@$relbranches) {
		my $tag = $$rv{latesttag};

		my $oj = {
			name => $tag,
			description => $$rv{description},
			status => $$rv{status},
		};
		jout "$outdir/branch/$tag.json", $oj;

		make_path "$outdir/branch/$tag/release";

		foreach my $release (@{$$rv{releases}}) {
			my $fname = $$release{version};
			$fname =~ s/x/0/g; # the lua doesn't like versions with x's in them
			jout "$outdir/branch/$tag/release/$fname.json", $$release{output};
		}
	}

	make_path "$outdir/component";

	foreach my $component (keys %$components) {
		jout "$outdir/component/$component.json", $$components{$component}{output};
	}
}


# dump things in human-readable form (for now)
#
sub output_component_repository
{
	my $components = shift;

	foreach my $component (sort keys %$components) {
		my $md = $$components{$component};

		print "$component\n";
		print "\tmin: " . $$md{minrelease} . "\n";
		print "\tmax: " . $$md{maxrelease} . "\n";
		print "\tparent: " . $$md{parent} . "\n" if defined $$md{parent};
		print "\treadme blob: " . $$md{readmeblob} . "\n" if defined $$md{readmeblob};
		print "\treadme version " . $$md{readmeversion} . "\n" if defined $$md{readmeversion};
		if (defined $$md{readme}) {
			print "-" x 80 . "\n";
			print Dumper $$md{readme};
			print "-" x 80 . "\n";
		}
		print "\n";
	}
}


# tests
#
#print "yes 1\n" if version_compare("2.0.0", "2.x.x") == -1;
#print "yes 2\n" if version_compare("2.0.0", "3.0.0") == -1;
#print "yes 3\n" if version_compare("0.1.0", "1.x.x") == -1;
#print "yes 4\n" if version_compare("0.1.0", "3.2.x") == -1;
#print "yes 5\n" if version_compare("3.0.x", "0.9.9") == 1;
#print "yes 6\n" if version_compare("0.9.9", "3.0.x") == -1;
#
#print "yes\n" if version_is_in_branch("2.0.0", "2.x.x");
#print "yes\n" if version_is_in_branch("2.1.0", "2.x.x");
#print "yes\n" if not version_is_in_branch("1.0.0", "2.x.x");
#print "yes\n" if not version_is_in_branch("3.1.5", "2.x.x");
#print "yes\n" if version_is_in_branch("3.0.15", "3.0.x");
#print "yes\n" if version_is_in_branch("3.0.15", "3.x.x");
#print "yes\n" if not version_is_in_branch("3.0.15", "3.1.x");



# get all versions we're interested in
my $versions = get_versions($repo);

add_versions_to_branches($RELBRANCHES, $versions);

find_releases($RELBRANCHES, $versions);

foreach my $release (keys %$versions) {
	get_branch_release_data($repo, $$versions{$release});
}

#print Dumper $versions;
#print Dumper $RELBRANCHES;
#exit;

#foreach my $k (sort {version_compare($a, $b)} keys %$releases) {
#	next unless $$releases{$k}{type} eq "development";
#	print "$k\n";
#}

# component repository
my $components = {};

#my $ss = get_release_components($repo, "v4.0.x");
#print Dumper $ss;

# go through all versions and add the modules and protocols
# to the components repository
#
foreach my $version (keys %$versions) {
	my $version_components = get_release_components($repo, $$versions{$version});
	build_component_repository($components, $version_components, $$versions{$version}, $RELBRANCHES);
}

# read and parse readme file data
get_readme_files($repo, $components);

foreach my $component (keys %$components) {
	get_component_release_data($repo, $$components{$component});
}

# dump everything we've got
output_component_repository($components);

build_web_json($RELBRANCHES, $versions, $components, $outdir);

