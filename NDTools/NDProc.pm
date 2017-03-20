package NDTools::NDProc;

use strict;
use warnings FATAL => 'all';
use parent "NDTools::NDTool";

use NDTools::INC;
use Getopt::Long qw(:config bundling pass_through);
use Log::Log4Cli;
use Module::Find qw(findsubmod);
use NDTools::Slurp qw(s_decode s_dump s_encode s_load);
use Storable qw(dclone freeze thaw);
use Struct::Diff qw(diff dsplit);
use Struct::Path qw(spath);
use Struct::Path::PerlStyle qw(ps_parse);

sub VERSION { '0.13' }

sub arg_opts {
    my $self = shift;
    my %arg_opts = (
        $self->SUPER::arg_opts(),
        'builtin-format=s' => \$self->{OPTS}->{'builtin-format'},
        'builtin-rules=s' => \$self->{OPTS}->{'builtin-rules'},
        'dump-blame=s' => \$self->{OPTS}->{'dump-blame'},
        'dump-rules=s' => \$self->{OPTS}->{'dump-rules'},
        'embed-blame=s' => \$self->{OPTS}->{'embed-blame'},
        'embed-rules=s' => \$self->{OPTS}->{'embed-rules'},
        'list-modules|l' => \$self->{OPTS}->{'list-modules'},
        'module|m=s' => \$self->{OPTS}->{module},
        'rules=s' => sub { push @{$self->{rules}}, @{s_load($_[1], undef)} },
    );
    delete $arg_opts{'help|h'};     # skip in first args parsing -- will be accessable for modules
    delete $arg_opts{'version|V'};  # --"--
    return %arg_opts;
}

sub configure {
    my $self = shift;
    if ($self->{OPTS}->{module} or ref $self->{rules} eq 'ARRAY' and @{$self->{rules}}) {
        log_info { "Explicit rules used: builtin will be ignored" };
        $self->{OPTS}->{'builtin-rules'} = undef;
    }
}

sub defaults {
    return {
        'blame' => 1, # may be redefined per-rule
        'builtin-format' => "", # raw
        'modpath' => [ "NDTools::NDProc::Module" ],
    };
}

sub dump_arg {
    my ($self, $uri, $arg) = @_;
    log_debug { "Dumping result to $uri" };
    s_dump($uri, undef, undef, $arg);
}

sub dump_blame {
    my ($self, $blame) = @_;
    return unless (defined $self->{OPTS}->{'dump-blame'});
    log_debug { "Dumping blame to '$self->{OPTS}->{'dump-blame'}'" };
    s_dump($self->{OPTS}->{'dump-blame'}, undef, undef, $blame);
}

sub dump_rules {
    my $self = shift;
    for my $rule (@{$self->{rules}}) {
        # remove undefs - defaults will be used anyway
        map { defined $rule->{$_} || delete $rule->{$_} } keys %{$rule};
    }
    s_dump($self->{OPTS}->{'dump-rules'}, undef, undef, $self->{rules});
}

sub embed {
    my ($self, $data, $path, $thing) = @_;

    my $spath = eval { ps_parse($path) };
    die_fatal "Unable to parse '$path' ($@)", 4 if ($@);
    my $ref = eval { (spath($data, $spath, expand => 1))[0]};
    die_fatal "Unable to lookup '$path' ($@)", 4 if ($@);

    ${$ref} = $self->{OPTS}->{'builtin-format'} ?
        s_encode($thing, $self->{OPTS}->{'builtin-format'}) :
        $thing;
}

sub exec {
    my $self = shift;

    $self->init_modules(@{$self->{OPTS}->{modpath}});
    if ($self->{OPTS}->{'list-modules'}) {
        map { printf "%-10s %-8s %s\n", @{$_} } $self->list_modules;
        die_info undef, 0;
    }

    if (defined $self->{OPTS}->{module}) {
        die_fatal "Unknown module '$self->{OPTS}->{module}' specified", 1
            unless (exists $self->{MODS}->{$self->{OPTS}->{module}});
        my $mod = $self->{MODS}->{$self->{OPTS}->{module}}->new();
        push @{$self->{rules}}, {
            %{$mod->parse_args()->get_opts()},
            modname => $self->{OPTS}->{module},
        };
    }

    # parse the rest of args (unrecognized by module (if was specified by args))
    # to be sure there is no unsupported opts remain
    my @rest_opts = (
        'help|h' => sub { $self->usage; die_info undef, 0 },
        'version|V' => sub { print $self->VERSION . "\n"; die_info undef, 0; },
    );

    my $p = Getopt::Long::Parser->new();
    $p->configure('nopass_through'); # just to be sure
    unless ($p->getoptions(@rest_opts)) {
        $self->usage;
        die_fatal "Unsupported opts passed", 1;
    }

    if ($self->{OPTS}->{'dump-rules'} and not @ARGV) {
        $self->dump_rules();
    } else {
        die_fatal "At least one argument expected", 1 unless (@ARGV);
        $self->process_args(@ARGV);
    }

    die_info "All done", 0;
}

sub init_modules {
    my $self = shift;
    for my $path (@_) {
        log_trace { "Indexing modules in $path" };
        for my $m (findsubmod $path) {
            $self->{MODS}->{(split('::', $m))[-1]} = $m;
        }
    }
    for my $m (sort keys %{$self->{MODS}}) {
        log_trace { "Initializing module $m ($self->{MODS}->{$m})" };
        eval "require $self->{MODS}->{$m}";
        die_fatal "Failed to initialize module '$m' ($@)", 1 if ($@);
    }
    return $self;
}

sub list_modules {
    my $self = shift;
    return map { [ $_, $self->{MODS}->{$_}->VERSION, $self->{MODS}->{$_}->MODINFO ] }
        sort keys %{$self->{MODS}};
}

sub load_arg {
    my ($self, $arg) = @_;
    log_debug { "Loading $arg" };
    s_load($arg, undef);
}

*load_source = \&load_arg;

sub load_builtin_rules {
    my ($self, $data, $path) = @_;

    log_debug { "Loading builtin rules from '$path'" };
    my $spath = eval { ps_parse($path) };
    die_fatal "Unable to parse path ($@)", 4 if ($@);
    my $rules = eval { (spath($data, $spath, deref => 1, strict => 1))[0] };
    die_fatal "Unable to lookup path ($@)", 4 if ($@);

    return $self->{OPTS}->{'builtin-format'} ?
        s_decode($rules, $self->{OPTS}->{'builtin-format'}) :
        $rules;
}

sub process_args {
    my $self = shift;
    for my $arg (@_) {
        log_info { "Processing $arg" };
        my $data = $self->load_arg($arg);

        if ($self->{OPTS}->{'builtin-rules'}) {
            $self->{rules} = $self->load_builtin_rules($data, $self->{OPTS}->{'builtin-rules'});
            # restore original rules - may be changed while processing structure
            $self->{OPTS}->{'embed-rules'} = $self->{OPTS}->{'builtin-rules'}
                if (not defined $self->{OPTS}->{'embed-rules'});
        }

        if ($self->{OPTS}->{'dump-rules'}) {
            $self->dump_rules();
            next;
        }

        $self->{resolved_rules} = $self->resolve_rules($self->{rules}, $arg);
        my @blame = $self->process_rules(\$data, $self->{resolved_rules});

        if ($self->{OPTS}->{'embed-blame'}) {
            log_debug { "Embedding blame to '$self->{OPTS}->{'embed-blame'}'" };
            $self->embed($data, $self->{OPTS}->{'embed-blame'}, \@blame);
        }

        if ($self->{OPTS}->{'embed-rules'}) {
            log_debug { "Embedding rules to '$self->{OPTS}->{'embed-rules'}'" };
            $self->embed($data, $self->{OPTS}->{'embed-rules'}, $self->{rules});
        }

        $self->dump_arg($arg, $data);
        $self->dump_blame(\@blame);
    }
}

sub process_rules {
    my ($self, $data, $rules) = @_;
    my $rcnt = 0; # rules counter
    my @blame;

    for my $rule (@{$rules}) {
        if ($rule->{disabled}) {
            log_debug { "Rule #$rcnt ($rule->{modname}) is disabled, skip it" };
            next;
        }
        die_fatal "Unknown module '$rule->{modname}' specified (rule #$rcnt)", 1
            unless (exists $self->{MODS}->{$rule->{modname}});

        log_debug { "Processing rule #$rcnt ($rule->{modname})" };
        my $result = ref ${$data} ? dclone(${$data}) : ${$data};
        my $source = exists $rule->{source} ? thaw($self->{sources}->{$rule->{source}}) : undef;
        $self->{MODS}->{$rule->{modname}}->new->process($data, $rule, $source);

        my $changes = { rule_id => 0 + $rcnt };
        if (defined $rule->{blame} ? $rule->{blame} : $self->{OPTS}->{blame}) {
            my $diff = dsplit(diff($result, ${$data}, noO => 1, noU => 1));
            $changes->{R} = delete $diff->{a} if (exists $diff->{a}); # more obvious
            $changes->{A} = delete $diff->{b} if (exists $diff->{b}); # --"--
        }
        map { $changes->{$_} = $rule->{$_} if (defined $rule->{$_}) }
            qw(blame comment source); # preserve useful info
        push @blame, dclone($changes);

        $rcnt++;
    }

    return @blame;
}

sub resolve_rules {
    my ($self, $rules, $opt_src) = @_;
    my $result;

    log_debug { "Resolving rules" };
    for my $rule (@{$rules}) {
        if (exists $rule->{source} and ref $rule->{source} eq 'ARRAY') {
            for my $src (@{$rule->{source}}) {
                my $new = { %{$rule} };
                $new->{source} = $src;
                push @{$result}, $new;
            }
        } else {
            push @{$result}, { %{$rule} };
        }
    }

    for my $rule (@{$result}) {
        # single path may be specified as string, convert it to list
        $rule->{path}->[0] = delete $rule->{path}
            if (exists $rule->{path} and not ref $rule->{path});

        next unless (exists $rule->{source});
        unless (defined $rule->{source} and $rule->{source} ne '') {
            # use processing doc as source
            $rule->{source} = $opt_src;
        }
        next if (exists $self->{sources}->{$rule->{source}});
        $self->{sources}->{$rule->{source}} =
            freeze($self->load_source($rule->{source}));
    }

    return $result;
}

1; # End of NDTools::NDProc
