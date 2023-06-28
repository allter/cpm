package App::cpm::Worker::Installer;
use strict;
use warnings;

use App::cpm::Git;
use App::cpm::Logger::File;
use App::cpm::Requirement;
use App::cpm::Worker::Installer::Menlo;
use App::cpm::Worker::Installer::Prebuilt;
use App::cpm::version;
use CPAN::DistnameInfo;
use CPAN::Meta;
use Config;
use ExtUtils::Install ();
use ExtUtils::InstallPaths ();
use File::Basename 'basename';
use File::Copy ();
use File::Copy::Recursive ();
use File::Path qw(mkpath rmtree);
use File::Spec;
use File::Temp ();
use File::pushd 'pushd';
use JSON::PP ();
use Module::CPANfile;
use Time::HiRes ();

use constant NEED_INJECT_TOOLCHAIN_REQUIREMENTS => $] < 5.016;

my $TRUSTED_MIRROR = sub {
    my $uri = shift;
    !!( $uri =~ m{^https?://(?:www.cpan.org|backpan.perl.org|cpan.metacpan.org)} );
};

sub work {
    my ($self, $job) = @_;
    my $type = $job->{type} || "(undef)";
    local $self->{logger}{context} = $job->distvname;
    if ($type eq "fetch") {
        if (my $result = $self->fetch($job)) {
            return +{
                ok => 1,
                directory => $result->{directory},
                meta => $result->{meta},
                requirements => $result->{requirements},
                provides => $result->{provides},
                using_cache => $result->{using_cache},
                prebuilt => $result->{prebuilt},
                rev => $result->{rev}, #n.shulyakovskiy
                ($job->{ref} ? (ref => $job->{ref}) : ()), #n.shulyakovskiy
                version => $result->{version}, #n.shulyakovskiy
            };
        } else {
            $self->{logger}->log_fail("Failed to fetch/configure distribution");
        }
    } elsif ($type eq "configure") {
        # $job->{directory}, $job->{distfile}, $job->{meta});
        if (my $result = $self->configure($job)) {
            return +{
                ok => 1,
                distdata => $result->{distdata},
                requirements => $result->{requirements},
                static_builder => $result->{static_builder},
            };
        } else {
            $self->{logger}->log_fail("Failed to configure distribution");
        }
    } elsif ($type eq "install") {
        my $ok = $self->install($job);
        my $message = $ok ? $self->{logger}->log("Successfully installed distribution") : $self->{logger}->log_fail("Failed to install distribution");
        return { ok => $ok, directory => $job->{directory} };
    } else {
        die "Unknown type: $type\n";
    }
    return { ok => 0 };
}

sub new {
    my ($class, %option) = @_;
    $option{logger} ||= App::cpm::Logger::File->new;
    $option{base}  or die "base option is required\n";
    $option{cache} or die "cache option is required\n";
    mkpath $_ for grep !-d, $option{base}, $option{cache};
    $option{logger}->log("Work directory is $option{base}");

    my $menlo = App::cpm::Worker::Installer::Menlo->new(
        static_install => $option{static_install},
        base => $option{base},
        logger => $option{logger},
        quiet => 1,
        pod2man => $option{man_pages},
        notest => $option{notest},
        sudo => $option{sudo},
        mirrors => ["https://cpan.metacpan.org/"], # this is dummy
        configure_timeout => $option{configure_timeout},
        build_timeout => $option{build_timeout},
        test_timeout => $option{test_timeout},
    );
    if ($option{local_lib}) {
        my $local_lib = $option{local_lib} = $menlo->maybe_abs($option{local_lib});
        $menlo->{self_contained} = 1;
        $menlo->log("Setup local::lib $local_lib");
        $menlo->setup_local_lib($local_lib);
    }
    $menlo->log("--", `$^X -V`, "--");
    $option{prebuilt} = App::cpm::Worker::Installer::Prebuilt->new if $option{prebuilt};
    bless { %option, menlo => $menlo }, $class;
}

sub menlo { shift->{menlo} }

sub _git_cache_dir {
    my ($self, $uri, $rev) = @_;
    my $uri_dir = $uri;
    $uri_dir =~ s/[^a-zA-Z0-9_.-]/-/g;
    return File::Spec->catfile($self->{cache}, 'git', $uri_dir, $rev);
}

sub _fetch_git {
    my ($self, $uri, $ref) = @_;
    my $basename = File::Basename::basename($uri);
    $basename =~ s/\.git$//;
    $basename =~ s/[^a-zA-Z0-9_.-]/-/g;
    my $dir = File::Temp::tempdir(
        "$basename-XXXXX",
        CLEANUP => 0,
        DIR => $self->menlo->{base},
    );
    $self->menlo->mask_output( diag_progress => "Cloning $uri" );
    my ($ok, $res) = $self->menlo->run_command([ 'git', 'clone', $uri, $dir ]);
    if (!$ok || !-e "$dir/.git") {
        $self->menlo->diag_fail("Failed cloning git repository $uri", 1);
        if ($res->{stdout}) {
            $self->menlo->diag_fail($_, 1) foreach map { "  $_" } split /\r?\n/, $res->{stdout};
        }
        return;
    }
    my $guard = pushd $dir;
    if ($ref) {
        ($ok, $res) = $self->menlo->run_command([ 'git', 'checkout', $ref ]);
        unless ($ok) {
            $self->menlo->diag_fail("Failed to checkout '$ref' in git repository $uri\n");
            if ($res->{stdout}) {
                $self->menlo->diag_fail($_, 1) foreach map { "  $_" } split /\r?\n/, $res->{stdout};
            }
            return;
        }
    }
    $self->menlo->diag_ok;
    chomp(my $rev = `git rev-parse HEAD`);
    ($dir, $rev);
}

sub enable_prebuilt {
    my ($self, $source, $uri) = @_;
    return 1 if $self->{prebuilt} && $source eq 'git';
    $self->{prebuilt} && !$self->{prebuilt}->skip($uri) && $TRUSTED_MIRROR->($uri);
}

sub fetch {
    my ($self, $job) = @_;
    my $guard = pushd;

    my $source   = $job->{source};
    my $distfile = $job->{distfile};
    my $rev      = $job->{rev};
    my $uri      = $job->{uri};
    my $features = $job->{features};

    if ($self->enable_prebuilt($source, $uri)) {
        if (my $result = $self->find_prebuilt($source, $uri, $rev, $features)) {
            $result->{ref} = $job->{ref} if $job->{ref};
            $self->{logger}->log("Using prebuilt $result->{directory}");
            return $result;
        }
    }

    my ($dir, $using_cache, $name, $version);
    if ($source eq "git") {
        my $basename = basename $uri;
        my ($uri, $subdir) = App::cpm::Git->split_uri($uri);
        my $sd = $subdir ? join("-", split m{/}, $subdir) : '';

        my $cache_dir = $self->_git_cache_dir($uri, "$sd.$rev");

        if (-d $cache_dir && -d $cache_dir . '/.git') {
            $self->{logger}->log("Using cache $cache_dir");
            $using_cache++;
        } else {
            my ($tmp_dir, $long_rev) = $self->_fetch_git($uri, $rev);
            die "Error clone $uri: Empty dir" unless $tmp_dir;
            if ($long_rev ne $rev) {
                unless (index($long_rev, $rev) == 0) {
                    my $msg = "Revision mismatch $long_rev ne $rev";
                    $self->{logger}->log_fail($msg);
                    return;
                }
                $rev = $long_rev;
                $cache_dir = $self->_git_cache_dir($uri, "$sd.$rev");
            }
            File::Copy::Recursive::dirmove($tmp_dir, $cache_dir);
        }

        $version = App::cpm::Git->version($cache_dir);

        my $sd_exist = 1;
        if ($subdir) {
            $cache_dir = File::Spec->catfile($cache_dir, $subdir);
            unless (-d $cache_dir) {
                $self->{logger}->log_warn("Directory $subdir not exists in git repository $uri (cache_dir: $cache_dir)");
                $sd_exist = 0;
            }
        }
        if ($sd_exist) {
            $dir = File::Temp::tempdir(
                "$basename-XXXXX",
                CLEANUP => 0,
                DIR => $self->menlo->{base},
            );
            File::Copy::Recursive::dircopy($cache_dir, $dir);
            App::cpm::Git->rewrite_version($dir, $version, $rev) if $version;

            if (my ($n) = $basename =~ /^(?:(?:perl|perl5|p5)-)?([\w-]+)(?:\.git)?$/) {
                $name = $n if -f File::Spec->catfile($dir, 'lib', split(/-/, $n)) . '.pm';
            }
        }

    } elsif ($source eq "local") {
        $self->{logger}->log("Copying $uri");
        $uri =~ s{^file://}{};
        $uri = $self->menlo->maybe_abs($uri);
        my $basename = basename $uri;
        my $g = pushd $self->menlo->{base};
        if (-d $uri) {
            my $dest = File::Temp::tempdir(
                "$basename-XXXXX",
                CLEANUP => 0,
                DIR => $self->menlo->{base},
            );
            File::Copy::Recursive::dircopy($uri, $dest);
            $dir = $dest;
        } elsif (-f $uri) {
            my $dest = $basename;
            File::Copy::copy($uri, $dest);
            $dir = $self->menlo->unpack($basename);
            $dir = File::Spec->catdir($self->menlo->{base}, $dir) if $dir;
        }
    } elsif ($source =~ /^(?:cpan|https?)$/) {
        my $g = pushd $self->menlo->{base};

        FETCH: {
            my $basename = basename $uri;
            if ($uri =~ s{^file://}{}) {
                $self->{logger}->log("Copying $uri");
                File::Copy::copy($uri, $basename)
                    or last FETCH;
                $dir = $self->menlo->unpack($basename);
            } else {
                local $self->menlo->{save_dists};
                if ($distfile and $TRUSTED_MIRROR->($uri)) {
                    my $cache = File::Spec->catfile($self->{cache}, "authors/id/$distfile");
                    if (-f $cache) {
                        $self->{logger}->log("Using cache $cache");
                        File::Copy::copy($cache, $basename);
                        $dir = $self->menlo->unpack($basename);
                        if ($dir) {
                            $using_cache++;
                            last FETCH;
                        }
                        unlink $cache;
                    }
                    $self->menlo->{save_dists} = $self->{cache};
                }
                $dir = $self->menlo->fetch_module({uris => [$uri], pathname => $distfile})
            }
        }
        $dir = File::Spec->catdir($self->menlo->{base}, $dir) if $dir;
    }
    return unless $dir;

    chdir $dir or die;

    my $meta = $self->_load_metafile($distfile, 'META.json', 'META.yml');
    unless ($meta) {
        $self->{logger}->log_warn("Distribution does not have META.json nor META.yml");
        if (!-f 'Build.PL' && !-f 'Makefile.PL') {
            if ($name && $version) {
                $meta = CPAN::Meta->new({ name => $name, version => $version, x_static_install => 1 });
            } else {
                $self->{logger}->log_fail("No way to guess distribution META");
                return;
            }
        }
        # If Build.PL or Makefile.PL exist then META will be loaded from MYMETA.json on configure
    }

    my $req = { configure => App::cpm::Requirement->new };
    eval {
        if ($meta && $self->menlo->opts_in_static_install($meta)) {
            $self->{logger}->log("Distribution opts in x_static_install: $meta->{x_static_install}");
        } elsif(-f 'cpanfile' || $meta) {
            $req = { configure => $self->_extract_configure_requirements($meta, $distfile, $features) };
        }
    };
    die "Error load requirments for $dir: $@" if $@;

    my $p = $meta ? ($meta->{provides} || $self->menlo->extract_packages($meta, ".")) : {};
    my $provides = [ map +{ package => $_, version => $p->{$_}{version}, ($job->{ref} ? (ref => $job->{ref}):()) }, sort keys %$p ];

    return +{
        directory => $dir,
        meta => $meta,
        requirements => $req,
        provides => $provides,
        using_cache => $using_cache,
        rev => $rev,
        ($job->{ref} ? (ref => $job->{ref}) : ()),
        version => $version,
    };
}

sub find_prebuilt {
    my ($self, $source, $uri, $rev, $features) = @_;
    my ($dir, $distfile);
    if ($source eq 'git') {
        my $dirname = join "-", $uri, $rev, $features ? @$features : ();
        $dirname =~ s/[^a-zA-Z0-9_.-]/-/g;
        $dir = File::Spec->catdir($self->{prebuilt_base}, 'git', $dirname);
        unless (length $rev == 40) {
            $dir = glob("$dir*");
            return unless defined $dir;
            ($rev) = $dir =~ /-(\p{IsXDigit}+)$/;
        }
    } else {
        $distfile = $uri;
        my $info = CPAN::DistnameInfo->new($distfile);
        $dir = File::Spec->catdir($self->{prebuilt_base}, $info->cpanid, $info->distvname);
    }
    return unless -f File::Spec->catfile($dir, ".prebuilt");

    my $guard = pushd $dir;

    my $meta = $self->_load_metafile($distfile, 'blib/meta/MYMETA.json', 'META.json', 'META.yml');
    unless ($meta && $self->menlo->no_dynamic_config($meta)) {
        $self->{logger}->log_warn("Prebuilt does not have MYMETA.json nor META.json nor META.yml");
        return;
    }

    my $phase  = $self->{notest} ? [qw(build runtime)] : [qw(build test runtime)];

    my %req;
    if (!$self->menlo->opts_in_static_install($meta)) {
        # XXX Actually we don't need configure requirements for prebuilt.
        # But requires them for consistency for now.
        %req = ( configure => $self->_extract_configure_requirements($meta, $distfile, $features) );
    }
    %req = (%req, %{$self->_extract_requirements($meta, $phase)} );

    my $json = do {
        open my $fh, "<", 'blib/meta/install.json' or die;
        JSON::PP::decode_json(do { local $/; <$fh> });
    };
    my $distvname = $json->{dist};
    my $provides = [ map +{ package => $_, version => $json->{provides}{$_}{version} }, sort keys %{$json->{provides}} ];

    return +{
        directory => $dir,
        meta => $meta->as_struct,
        distvname => $distvname,
        provides => $provides,
        prebuilt => 1,
        requirements => \%req,
        rev => $rev,
    };
}

sub save_prebuilt {
    my ($self, $job) = @_;
    my $dir;
    if ($job->{distdata}->{source} eq 'git') {
        my $dirname = join "-", $job->{distdata}->{pathname}, $job->{features} ? @{$job->{features}} : ();
        $dirname =~ s/[^a-zA-Z0-9_.-]/-/g;
        $dir = File::Spec->catdir($self->{prebuilt_base}, 'git', $dirname);
    } else {
        $dir = File::Spec->catdir($self->{prebuilt_base}, $job->cpanid, $job->distvname);
    }

    if (-d $dir and !File::Path::rmtree($dir)) {
        return;
    }

    my $parent = File::Basename::dirname($dir);
    for (1..3) {
        last if -d $parent;
        eval { File::Path::mkpath($parent) };
    }
    return unless -d $parent;

    $self->{logger}->log("Saving the build $job->{directory} in $dir");
    if (File::Copy::Recursive::dircopy($job->{directory}, $dir)) {
        open my $fh, ">", File::Spec->catfile($dir, ".prebuilt") or die $!;
    } else {
        warn "dircopy $job->{directory} $dir: $!";
    }
}

sub _inject_toolchain_requirements {
    my ($self, $distfile, $requirement) = @_;
    $distfile ||= "";

    if (    -f "Makefile.PL"
        and !$requirement->has('ExtUtils::MakeMaker')
        and !-f "Build.PL"
        and $distfile !~ m{/ExtUtils-MakeMaker-[0-9v]}
    ) {
        $requirement->add('ExtUtils::MakeMaker');
    }
    if ($requirement->has('Module::Build')) {
        $requirement->add('ExtUtils::Install');
    }

    my %inject = (
        'Module::Build' => '0.38',
        'ExtUtils::MakeMaker' => '6.58',
        'ExtUtils::Install' => '1.46',
    );

    for my $package (sort keys %inject) {
        $requirement->has($package) or next;
        $requirement->add($package, $inject{$package});
    }
    $requirement;
}

sub _load_metafile {
    my ($self, $distfile, @file) = @_;
    my $meta;
    if (my ($file) = grep -f, @file) {
        $meta = eval { CPAN::Meta->load_file($file) };
        $self->{logger}->log_fail("Invalid $file: $@") if $@;
    }

    if (!$meta and $distfile) {
        my $d = CPAN::DistnameInfo->new($distfile);
        $meta = CPAN::Meta->new({name => $d->dist, version => $d->version});
    }
    $meta;
}

# XXX Assume current directory is distribution directory
# because the test "-f Build.PL" or similar is present
sub _extract_configure_requirements {
    my ($self, $meta, $distfile, $features) = @_;
    my $requirement = $self->_extract_requirements($meta, [qw(configure)], $features)->{configure};
    if ($requirement->empty and -f "Build.PL" and ($distfile || "") !~ m{/Module-Build-[0-9v]}) {
        $requirement->add("Module::Build" => "0.38");
    }
    if (NEED_INJECT_TOOLCHAIN_REQUIREMENTS) {
        $self->_inject_toolchain_requirements($distfile, $requirement);
    }
    return $requirement;
}

sub _extract_requirements {
    my ($self, $meta, $phases, $features) = @_;
    $phases = [$phases] unless ref $phases;
    die "Empty metadata" if !$meta && !-f 'cpanfile';
    my %req;
    require Module::CPANfile;
    my %known_features;
    for my $meta_or_cpanfile ((-f 'cpanfile' ? Module::CPANfile->load('cpanfile'): ()), ($meta ? $meta : ())) {
        my $can_get_options = $meta_or_cpanfile->can('options_for_module') ? 1 : 0;
        $known_features{$_->identifier} = $can_get_options for $meta_or_cpanfile->features;
        my $hash = $meta_or_cpanfile->effective_prereqs([ grep { exists $known_features{$_} && $known_features{$_} == $can_get_options} @$features ])->as_string_hash;
        for my $phase (@$phases) {
            $req{$phase} ||= App::cpm::Requirement->new;
            my $from = ($hash->{$phase} || +{})->{requires} || +{};
            for my $package (sort keys %$from) {
                $req{$phase}->add($package, ($can_get_options && $meta_or_cpanfile->options_for_module($package) ? ({ version_range => $from->{$package}, options => $meta_or_cpanfile->options_for_module($package)}) : ($from->{$package})));
            }
        }
    }
    my @unknown_features = grep { !exists $known_features{$_} } @$features;
    die "Unknown features ".join(", ", map { "'$_'" } @unknown_features) if @unknown_features;
    \%req;
}

sub _retry {
    my ($self, $sub) = @_;
    return 1 if $sub->();
    return unless $self->{retry};
    Time::HiRes::sleep(0.1);
    $self->{logger}->log_warn("! Retrying (you can turn off this behavior by --no-retry)");
    return $sub->();
}

sub configure {
    my ($self, $job) = @_;
    my ($dir, $distfile, $meta, $source, $features) = @{$job}{qw(directory distfile meta source features)};
    my $guard = pushd $dir;
    my $menlo = $self->menlo;
    my $menlo_dist = { meta => $meta, cpanmeta => $meta }; # XXX

    $self->{logger}->log("Configuring distribution");
    my ($static_builder, $configure_ok);
    {
        if ($menlo->opts_in_static_install($meta)) {
            my $state = {};
            $menlo->static_install_configure($state, $menlo_dist, 1);
            $static_builder = $state->{static_install};
            ++$configure_ok and last;
        }
        if (-f 'Build.PL') {
            my @cmd = ($menlo->{perl}, 'Build.PL');
            push @cmd, '--pureperl-only' if $self->{pureperl_only};
            push @cmd, "--dist_verison=$job->{version}" if $job->{source} eq 'git' && $job->{version};
            $self->_retry(sub {
                $menlo->configure(\@cmd, $menlo_dist, 1);
                -f 'Build';
            }) and ++$configure_ok and last;
        }
        if (-f 'Makefile.PL') {
            my @cmd = ($menlo->{perl}, 'Makefile.PL');
            push @cmd, 'PUREPERL_ONLY=1' if $self->{pureperl_only};
            push @cmd, "VERSION=$job->{version}" if $job->{source} eq 'git' && $job->{version};
            $self->_retry(sub {
                $menlo->configure(\@cmd, $menlo_dist, 1); # XXX depth == 1?
                -f 'Makefile';
            }) and ++$configure_ok and last;
        }
    }
    return unless $configure_ok;


    my $phase = $self->{notest} ? [qw(build runtime)] : [qw(build test runtime)];
    my $dd_distfile = $source eq 'git' ? "$job->{uri}\@$job->{rev}" : $distfile;
    my $mymeta = $self->_load_metafile($distfile, 'MYMETA.json', 'MYMETA.yml');
    my $distdata = $self->_build_distdata($source, $dd_distfile, $mymeta);
    my $req = $self->_extract_requirements($mymeta, $phase, $features);

    return +{
        distdata => $distdata,
        requirements => $req,
        static_builder => $static_builder,
    };
}

sub _build_distdata {
    my ($self, $source, $distfile, $meta) = @_;

    my $menlo = $self->menlo;
    my $fake_state = { configured_ok => 1, use_module_build => -f "Build" };
    my $module_name = $menlo->find_module_name($fake_state) || $meta->{name};
    $module_name =~ s/-/::/g;

    my $distvname = $source eq 'git' ? "$meta->{name}-$meta->{version}"
        : CPAN::DistnameInfo->new($distfile)->distvname;
    my $provides = $meta->{provides} || $menlo->extract_packages($meta, ".");
    +{
        distvname => $distvname,
        pathname => $distfile,
        provides => $provides,
        version => $meta->{version} || 0,
        source => $source,
        module_name => $module_name,
    };
}

sub install {
    my ($self, $job) = @_;
    return $self->install_prebuilt($job) if $job->{prebuilt};

    my ($dir, $distdata, $static_builder, $distvname, $meta)
        = @{$job}{qw(directory distdata static_builder distvname meta)};
    my $guard = pushd $dir;
    my $menlo = $self->menlo;
    my $menlo_dist = { meta => $meta }; # XXX

    $self->{logger}->log("Building " . ($menlo->{notest} ? "" : "and testing ") . "distribution");
    my $installed;
    if ($static_builder) {
        $menlo->build(sub { $static_builder->build }, $distvname, $menlo_dist)
        && $menlo->test(sub { $static_builder->build("test") }, $distvname, $menlo_dist)
        && $menlo->install(sub { $static_builder->build("install") }, [], $menlo_dist)
        && $installed++;
    } elsif (-f 'Build') {
        $self->_retry(sub { $menlo->build([ $menlo->{perl}, "./Build" ], $distvname, $menlo_dist)  })
        && $self->_retry(sub { $menlo->test([ $menlo->{perl}, "./Build", "test" ], $distvname, $menlo_dist)  })
        && $self->_retry(sub { $menlo->install([ $menlo->{perl}, "./Build", "install" ], [], $menlo_dist)  })
        && $installed++;
    } else {
        $self->_retry(sub { $menlo->build([ $menlo->{make} ], $distvname, $menlo_dist)  })
        && $self->_retry(sub { $menlo->test([ $menlo->{make}, "test" ], $distvname, $menlo_dist)  })
        && $self->_retry(sub { $menlo->install([ $menlo->{make}, "install" ], [], $menlo_dist) })
        && $installed++;
    }

    if ($installed && $distdata) {
        {
            # dirty hack: if $distdata->{source} ne "cpan", then $menlo->save_meta does nothing
            local $distdata->{source} = 'cpan' if $distdata->{source} eq 'git';
            $menlo->save_meta(
                $distdata->{module_name},
                $distdata,
                $distdata->{module_name},
            );
        }
        $self->save_prebuilt($job) if $self->enable_prebuilt($distdata->{source}, $job->{uri});
    }
    return $installed;
}

sub install_prebuilt {
    my ($self, $job) = @_;

    my $install_base = $self->{local_lib};
    if (!$install_base && ($ENV{PERL_MM_OPT} || '') =~ /INSTALL_BASE=(\S+)/) {
        $install_base = $1;
    }

    $self->{logger}->log("Copying prebuilt $job->{directory}/blib");
    my $guard = pushd $job->{directory};
    my $paths = ExtUtils::InstallPaths->new(
        dist_name => $job->distname, # this enables the installation of packlist
        $install_base ? (install_base => $install_base) : (),
    );
    my $install_base_meta = $install_base ? "$install_base/lib/perl5" : $Config{sitelibexp};
    my $distvname = $job->distvname;
    open my $fh, ">", \my $stdout;
    {
        local *STDOUT = $fh;
        ExtUtils::Install::install([
            from_to => $paths->install_map,
            verbose => 0,
            dry_run => 0,
            uninstall_shadows => 0,
            skip => undef,
            always_copy => 1,
            result => \my %result,
        ]);
        ExtUtils::Install::install({
            'blib/meta' => "$install_base_meta/$Config{archname}/.meta/$distvname",
        });
    }
    $self->{logger}->log($stdout);
    return 1;
}

1;
