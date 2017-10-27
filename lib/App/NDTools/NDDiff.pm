package App::NDTools::NDDiff;

use strict;
use warnings FATAL => 'all';
use parent 'App::NDTools::NDTool';

use Algorithm::Diff;
use JSON qw();
use App::NDTools::Slurp qw(s_dump);
use Log::Log4Cli 0.18;
use Struct::Diff 0.88 qw();
use Struct::Path qw(spath spath_delta);
use Struct::Path::PerlStyle qw(ps_parse ps_serialize);
use Term::ANSIColor qw(colored);

sub VERSION { "0.26" }

sub arg_opts {
    my $self = shift;
    return (
        $self->SUPER::arg_opts(),
        'brief' => sub { $self->{OPTS}->{ofmt} = $_[0] },
        'colors!' => \$self->{OPTS}->{colors},
        'ctx-text=i' => \$self->{OPTS}->{'ctx-text'},
        'full' => \$self->{OPTS}->{full},
        'full-headers' => \$self->{OPTS}->{'full-headers'},
        'grep=s@' => \$self->{OPTS}->{grep},
        'json' => sub { $self->{OPTS}->{ofmt} = $_[0] },
        'ignore=s@' => \$self->{OPTS}->{ignore},
        'path=s' => \$self->{OPTS}->{path},
        'rules' => sub { $self->{OPTS}->{ofmt} = $_[0] },
        'quiet|q' => \$self->{OPTS}->{quiet},
        'show' => \$self->{OPTS}->{show},
    )
}

sub check_args {
    my $self = shift;

    if ($self->{OPTS}->{show}) {
        unless (@_ == 1) {
            log_error { "One argument expected (--show) used" };
            return undef;
        }
    } elsif (@_ != 2) {
        log_error { "Two arguments expected for diff" };
        return undef;
    }

    return $self;
}

sub configure {
    my $self = shift;

    $self->{OPTS}->{colors} = -t STDOUT ? 1 : 0
        unless (defined $self->{OPTS}->{colors});

    for (@{$self->{OPTS}->{grep}}, @{$self->{OPTS}->{ignore}}) {
        my $tmp = eval { ps_parse($_) };
        die_fatal "Failed to parse '$_'", 4 if ($@);
        $_ = $tmp;
    }

    # --path is ambigous - result is a list which depends of passed structure
    log_alert { "Opt --path is deprecated and will be removed in the future" }
        if ($self->{OPTS}->{path});

    return $self;
}

sub defaults {
    my $self = shift;
    my $out = {
        %{$self->SUPER::defaults()},
        'ctx-text' => 3,
        'term' => {
            'line' => {
                'A' => 'green',
                'D' => 'yellow',
                'U' => 'white',
                'R' => 'red',
                '@' => 'magenta',
            },
            'sign' => {
                'A' => '>',
                'D' => '!',
                'U' => ' ',
                'R' => '<',
                '@' => ' ',
            },
        },
        'ofmt' => 'term',
    };
    $out->{term}{line}{N} = $out->{term}{line}{A};
    $out->{term}{line}{O} = $out->{term}{line}{R};
    $out->{term}{sign}{N} = $out->{term}{sign}{A};
    $out->{term}{sign}{O} = $out->{term}{sign}{R};
    return $out;
}

sub add {
    my $self = shift;
    push @{$self->{items}}, @_;
}

sub diff {
    my $self = shift;
    log_debug { "Calculating diff for structure" };
    $self->{diff} = Struct::Diff::diff(
        $self->{items}->[0],
        $self->{items}->[1],
        noU => $self->{OPTS}->{full} ? 0 : 1,
    );
    if ($self->{OPTS}->{ofmt} eq 'term') {
        $self->diff_term or return undef;
    }
    return $self->{diff};
}

sub _lcsidx2ranges {
    my ($in_a, $in_b) = @_;
    return [], [] unless (@{$in_a});

    my @out_a = [ shift @{$in_a} ];
    my @out_b = [ shift @{$in_b} ];

    while (@{$in_a}) {
        my $i_a = shift @{$in_a};
        my $i_b = shift @{$in_b};
        if (
            ($i_a - $out_a[-1][-1] < 2) and
            ($i_b - $out_b[-1][-1] < 2)
        ) { # update ranges - both sequences are continous
            $out_a[-1][1] = $i_a;
            $out_b[-1][1] = $i_b;
        } else { # new ranges
            push @out_a, [ $i_a ];
            push @out_b, [ $i_b ];
        }
    }

    return \@out_a, \@out_b;
}

sub diff_term {
    my $self = shift;

    log_debug { "Calculating diffs for text values" };

    my $dref;       # ref to diff
    my ($o, $n);    # LCS ranges
    my ($po, $pn);  # current positions in splitted texts
    my ($ro, $rn);  # current LCS range
    my @list = Struct::Diff::list_diff($self->{diff});

    while (@list) {
        (undef, $dref) = splice @list, 0, 2;

        next unless (exists ${$dref}->{N});
        unless (exists ${$dref}->{O}) {
            log_error { "Incomplete diff passed (old value is absent)" };
            return undef;
        }

        my @old = split($/, ${$dref}->{O}, -1)
            if (${$dref}->{O} and not ref ${$dref}->{O});
        my @new = split($/, ${$dref}->{N}, -1)
            if (${$dref}->{N} and not ref ${$dref}->{N});

        if (@old > 1 or @new > 1) {
            delete ${$dref}->{O};
            delete ${$dref}->{N};

            if ($old[-1] eq '' and $new[-1] eq '') {
                pop @old; # because split by newline and -1 for LIMIT
                pop @new; # -"-
            }

            ($o, $n) = _lcsidx2ranges(Algorithm::Diff::LCSidx \@old, \@new);
            ($po, $pn) = (0, 0);

            while (@{$o}) {
                ($ro, $rn) = (shift @{$o}, shift @{$n});
                push @{${$dref}->{T}}, { R => [ @old[$po .. $ro->[0] - 1] ] }
                    if ($ro->[0] > $po);
                push @{${$dref}->{T}}, { A => [ @new[$pn .. $rn->[0] - 1] ] }
                    if ($rn->[0] > $pn);
                push @{${$dref}->{T}}, { U => [ @new[$rn->[0] .. $rn->[-1]] ] };
                $po = $ro->[-1] + 1;
                $pn = $rn->[-1] + 1;
            }

            # collect tailing added/removed
            push @{${$dref}->{T}}, { R => [ @old[$po .. $#old] ] }
                if ($po <= $#old);
            push @{${$dref}->{T}}, { A => [ @new[$pn .. $#new] ] }
                if ($pn <= $#new);
        }
    }

    return $self;
}

sub dump {
    my $self = shift;

    log_debug { "Dumping results" };

    if ($self->{OPTS}->{ofmt} eq 'term') {
        $self->dump_term();
    } elsif ($self->{OPTS}->{ofmt} eq 'brief') {
        $self->dump_brief();
    } elsif ($self->{OPTS}->{ofmt} eq 'rules') {
        $self->dump_rules();
    } else {
        s_dump(\*STDOUT, $self->{OPTS}->{ofmt},
            {pretty => $self->{OPTS}->{pretty}}, $self->{diff});
    }

    return $self;
}

sub dump_brief {
    my $self = shift;

    my ($path, $dref, $tag);
    my @list = Struct::Diff::list_diff($self->{diff}, sort => 1);

    while (@list) {
        ($path, $dref) = splice @list, 0, 2;
        for $tag (qw{R N A}) {
            $self->print_brief_block($path, $tag)
                if (exists ${$dref}->{$tag});
        }
    }
}

sub dump_rules {
    my $self = shift;

    my ($path, $dref, $item, @out);
    my @list = Struct::Diff::list_diff($self->{diff}, sort => 1);

    while (@list) {
        ($path, $dref) = splice @list, 0, 2;
        for (qw{R N A}) {
            next unless (exists ${$dref}->{$_});
            unshift @out, {
                modname => $_ eq "R" ? "Remove" : "Insert",
                path => $self->dump_rules_path($path),
                value => ${$dref}->{$_}
            };
        }
    }

    s_dump(\*STDOUT, 'JSON', {pretty => $self->{OPTS}->{pretty}}, \@out);
}

sub dump_rules_path { # to be able to override
    return ps_serialize($_[1]);
}

sub dump_term {
    my $self = shift;

    my ($path, $dref, $tag);
    my @list = Struct::Diff::list_diff($self->{diff}, sort => 1);

    while (@list) {
        ($path, $dref) = splice @list, 0, 2;
        for $tag (qw{R O N A T}) {
            $self->print_term_block(${$dref}->{$tag}, $path, $tag)
                if (exists ${$dref}->{$tag});
        }
    }
}

sub exec {
    my $self = shift;

    $self->check_args(@ARGV) or die_fatal undef, 1;
    $self->load(@ARGV) or die_fatal undef, 1;

    if ($self->{OPTS}->{show}) {
        $self->{diff} = shift @{$self->{items}};
    } else {
        $self->diff or die_fatal undef, 1;
    }

    $self->dump or die_fatal undef, 1 unless ($self->{OPTS}->{quiet});

    die_info "All done, no difference found", 0
        if (not keys %{$self->{diff}} or exists $self->{diff}->{U});
    die_info "Difference found", 8;
}

sub load {
    my $self = shift;

    for (@_) {
        my $data = $self->load_struct($_) or return undef;

        if (my $path = $self->{OPTS}->{path}) {
            my $p = eval { ps_parse($path) };
            if ($@) {
                log_error { "Failed to parse path '$path' ($@)" };
                return undef;
            }
            ($data) = spath($data, $p, deref => 1);
        }

        ($data) = $self->grep($self->{OPTS}->{grep}, $data)
            if (@{$self->{OPTS}->{grep}});

        map { spath($data, $_, delete => 1) } @{$self->{OPTS}->{ignore}}
            if (ref $data);

        $self->add($data);
    }

    return $self;
}

sub print_brief_block {
    my ($self, $path, $status) = @_;

    return unless (@{$path}); # nothing to show

    $path = [ @{$path} ]; # prevent passed path corruption (used later for items with same subpath)
    $status = 'D' if ($status eq 'N');
    my $last = ps_serialize([pop @{$path}]);
    my $base = ps_serialize($path);

    if ($self->{OPTS}->{colors}) {
        $last = colored($last, "bold " . $self->{OPTS}->{term}->{line}->{$status});
        $base = colored($base, $self->{OPTS}->{term}->{line}->{U});
    }

    print $self->{OPTS}->{term}->{sign}->{$status} . " " . $base . $last . "\n";
}

sub print_term_block {
    my ($self, $value, $path, $status) = @_;
    log_trace { "'" . ps_serialize($path) . "' (" . $status . ")"};

    my @lines;
    my $color = $self->{OPTS}->{term}->{line}->{$status};
    my $dsign = $self->{OPTS}->{term}->{sign}->{$status};

    # diff for path
    if (@{$path} and my @delta = spath_delta($self->{'hdr_path'}, $path)) {
        $self->{'hdr_path'} = [@{$path}];
        for (my $s = 0; $s < @{$path}; $s++) {
            next if (not $self->{OPTS}->{'full-headers'} and $s < @{$path} - @delta);
            my $line = sprintf("%" . $s * 2 . "s", "") . ps_serialize([$path->[$s]]);
            if (($status eq 'A' or $status eq 'R') and $s == $#{$path}) {
                $line = "$dsign $line";
                $line = colored($line, "bold $color") if ($self->{OPTS}->{colors});
            } else {
                $line = "  $line";
            }
            push @lines, $line;
        }
    }

    # diff for value
    my $indent = sprintf "%" . @{$path} * 2 . "s", "";
    push @lines, $self->term_value_diff($value, $status, $indent);

    print join("\n", @lines) . "\n";
}

sub term_value_diff {
    my ($self, $value, $status, $indent) = @_;

    return $self->term_value_diff_text($value, $indent)
        if ($status eq 'T');

    return $self->term_value_diff_default($value, $status, $indent);
}

sub term_value_diff_default {
    my ($self, $value, $status, $indent) = @_;
    my @out;

    $value = JSON->new->allow_nonref->canonical->pretty($self->{OPTS}->{pretty})->encode($value)
        if (ref $value or not defined $value);

    for my $line (split($/, $value)) {
        substr($line, 0, 0, $self->{OPTS}->{term}->{sign}->{$status} . $indent . " ");
        $line = colored($line, $self->{OPTS}->{term}->{line}->{$status})
            if ($self->{OPTS}->{colors});
        push @out, $line;
    }

    return @out;
}

sub term_value_diff_text {
    my ($self, $diff, $indent) = @_;
    my (@out, @head_ctx, @tail_ctx, $pos);

    while (my $hunk = shift @{$diff}) {
        my ($status, $lines) = each %{$hunk};
        my $sign  = $self->{OPTS}->{term}->{sign}->{$status};
        my $color = $self->{OPTS}->{term}->{line}->{$status};
        $pos += @{$lines};

        if ($status eq 'U') {
            if ($self->{OPTS}->{'ctx-text'}) {
                @head_ctx = splice(@{$lines});                                  # before changes
                @tail_ctx = splice(@head_ctx, 0, $self->{OPTS}->{'ctx-text'})   # after changes
                    if (@out);
                splice(@head_ctx, 0, @head_ctx - $self->{OPTS}->{'ctx-text'})
                    if (@head_ctx > $self->{OPTS}->{'ctx-text'});

                splice(@head_ctx) unless (@{$diff});

                @head_ctx = map {
                    my $l = $sign . " " . $indent . $_;
                    $self->{OPTS}->{colors} ? colored($l, $color) : $l;
                } @head_ctx;
                @tail_ctx = map {
                    my $l = $sign . " " . $indent . $_;
                    $self->{OPTS}->{colors} ? colored($l, $color) : $l;
                } @tail_ctx;
            } else {
                splice(@{$lines}); # purge or will be printed in the next block
            }
        }

        push @out, splice @tail_ctx;
        if (@head_ctx or (not $self->{OPTS}->{'ctx-text'} and $status eq 'U' and @{$diff}) or not @out) {
            my $l = $self->{OPTS}->{term}->{sign}->{'@'} . " " . $indent . "@@ $pos,- -,- @@";
            push @out, $self->{OPTS}->{colors} ? colored($l, $self->{OPTS}->{term}->{line}->{'@'}) : $l;
        }
        push @out, splice @head_ctx;
        push @out, map {
            my $l = $sign . " " . $indent . $_;
            $self->{OPTS}->{colors} ? colored($l, $color) : $l;
        } @{$lines};
    }

    return @out;
}

1; # End of App::NDTools::NDDiff
