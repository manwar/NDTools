package App::NDTools::NDProc::Module::Merge;

use strict;
use warnings FATAL => 'all';
use parent 'App::NDTools::NDProc::Module';

use Hash::Merge qw();
use Hash::Merge::Extra;
use List::MoreUtils qw(before);
use Log::Log4Cli;
use Storable qw(dclone);
use Struct::Path qw(is_implicit_step spath);
use Struct::Path::PerlStyle qw(ps_parse ps_serialize);

sub MODINFO { "Merge structures according provided rules" }
sub VERSION { "0.12" }

sub arg_opts {
    my $self = shift;
    return (
        $self->SUPER::arg_opts(),
        'ignore=s@' => \$self->{OPTS}->{ignore},
        'merge|path=s' => sub {
            if ($self->{rules} and @{$self->{rules}}) {
                push @{$self->{rules}->[-1]->{path}}, { merge => $_[1] };
            } else {
                push @{$self->{OPTS}->{path}}, { merge => $_[1] };
            }
        },
        'source=s' => sub {
            push @{$self->{rules}}, { source => $_[1] };
        },
        'strict!' => sub {
            $self->set_path_related_opt($_[0], $_[1]),
        },
        'preserve=s@' => \$self->{OPTS}->{preserve},
        'style=s' => sub {
            $self->set_path_related_opt($_[0], $_[1])
        },
    )
}

sub configure {
    my $self = shift;
    $self->{rules} = [] unless ($self->{rules});

    # resolve rules
    for my $rule (@{$self->{rules}}) {

        # merge with global wide opts
        my $globals = dclone($self->{OPTS});
        unshift @{$rule->{path}}, @{delete $globals->{path}}
            if ($globals->{path} and @{$globals->{path}});
        $rule = { %{$globals}, %{$rule} };

        # path as simple string if no no specific opts defined
        map { $_ = $_->{merge} if (exists $_->{merge} and keys %{$_} == 1) }
            @{$rule->{path}};
    }
}

sub defaults {
    my $self = shift;
    return {
        %{$self->SUPER::defaults()},
        'strict' => 1,
        'style' => 'R_OVERRIDE',
    };
}

sub get_opts {
    my $self = shift;
    return @{$self->{rules}};
}

sub map_paths {
    my ($data, $srcs, $spath) = @_;

    my @explicit = before { is_implicit_step($_) } @{$spath};
    return spath($data, $spath, paths => 1, expand => 1)
        if (@explicit == @{$spath}); # fully qualified path

    my @out;
    my @dsts = spath($data, $spath, paths => 1);

    $srcs = [ @{$srcs} ];
    while (@{$srcs}) {
        my ($sp, $sr) = splice @{$srcs}, 0, 2;

        if (@dsts) { # destination struct may match - use this paths beforehand
            push @out, splice @dsts, 0, 2;
            next;
        }

        my @e_path = @{$spath};
        while (my $step = pop @e_path) {
            if (ref $step eq 'ARRAY' and is_implicit_step($step)) {
                if (my @tmp = spath($data, \@e_path, deref => 1, paths => 1)) {
                    # expand last existed array, addressed by implicit step
                    @e_path = ( @{$tmp[0]}, [ scalar @{$tmp[1]} ] );
                    last;
                }
            } elsif (ref $step eq 'HASH' and is_implicit_step($step)) {
                if (my @tmp = spath($data, [ @e_path, $step ], paths => 1)) {
                    @e_path = @{$tmp[0]};
                    last;
                }
            }
        }

        @e_path = @{$sp}[0 .. $#explicit] unless (@e_path);
        my @i_path = @{$sp}[@e_path .. $#{$sp}];

        map { $_ = [0] if (ref $_ eq 'ARRAY') } @i_path; # drop array's indexes in implicit part of path
        push @out, spath($data, [@e_path, @i_path], paths => 1, expand => 1);
    }

    return @out;
}

sub process {
    my ($self, $data, $opts, $source) = @_;

    if (exists $opts->{ignore}) {
        for my $path (@{$opts->{ignore}}) {
            log_debug { "Removing (ignore) from src '$path'" };
            spath($source, ps_parse($path), delete => 1);
        }
    }

    $self->stash_preserved($data, $opts->{preserve}) if ($opts->{preserve});

    # merge full source if no paths defined
    push @{$opts->{path}}, {} unless ($opts->{path} and @{$opts->{path}});
    # convert to canonical structure
    map { $_ = { merge => $_ } unless (ref $_) } @{$opts->{path}};

    for my $m (@{$opts->{path}}) {
        $m->{merge} = '' unless (defined $m->{merge}); # merge whole source if path omitted
        my $spath = ps_parse($m->{merge});

        log_debug { "Resolving paths '$m->{merge}'" };
        my @srcs = spath($source, $spath, paths => 1);
        unless (@srcs) {
            die_fatal "No such path ($m->{merge}) in $opts->{source}", 4
                if(exists $m->{strict} ? $m->{strict} : $opts->{strict});
            log_info { "Ignoring path $m->{merge} (doesn't exists in $opts->{source})" };
            next;
        }
        my @dsts = map_paths($data, \@srcs, $spath);

        my $style = $m->{style} || $opts->{style} || $self->{OPTS}->{style};
        while (@srcs) {
            my ($sp, $sr) = splice @srcs, 0, 2;
            my ($dp, $dr) = splice @dsts, 0, 2;
            log_info { "Merging $opts->{source} ($style, '" .
                ps_serialize($sp) . "' => '" . ps_serialize($dp) . "')" };
            Hash::Merge::set_behavior($style);
            ${$dr} = Hash::Merge::merge(${$dr}, ${$sr});
        }
    }

    $self->restore_preserved($data) if ($opts->{preserve});
}

sub set_path_related_opt {
    my ($self, $name, $val) = @_;

    if ($self->{rules} and @{$self->{rules}}) {
        if (exists $self->{rules}->[-1]->{path} and @{$self->{rules}->[-1]->{path}}) {
            $self->{rules}->[-1]->{path}->[-1]->{$name} = $val; # per path
        } else {
            $self->{rules}->[-1]->{$name} = $val; # per rule
        }
    } else {
        $self->{OPTS}->{$name} = $val; # global (whole ruleset wide)
    }
}

1; # End of App::NDTools::NDProc::Module::Merge

__END__

=head1 NAME

Merge - merge structures according provided rules

=head1 OPTIONS

=over 4

=item B<--[no]blame>

Blame calculation toggle. Enabled by default.

=item B<--ignore> E<lt>pathE<gt>

Ignore part from source structure. Rule-wide option. May be used several times.

=item B<--merge> E<lt>pathE<gt>

Path in the source structure to merge. Whole structure will be merged if
omitted or empty. May be specified several times.

=item B<--preserve> E<lt>pathE<gt>

Preserve specified parts from original structure. Rule-wide option. May be used
several times.

=item B<--source> E<lt>uriE<gt>

Source to merge with. Original processing structure will be used if option
specified, but value not defined or empty. Rule-wide option. May be used several
times.

=item B<--[no]strict>

Fail if specified path doesn't exists in source structure. Positional opt - define
rule default if used before --merge, per-merge opt otherwise. Enabled by default.

=item B<--style> E<lt>styleE<gt>

Merge style. Positional option - define rule default if used before --merge,
per-merge opt otherwise.

=over 8

=item B<L_ADDITIVE>, B<R_ADDITIVE>

Hashes merged, arrays joined, undefined scalars overrided. Left and right precedence.

=item B<L_OVERRIDE>, B<R_OVERRIDE>

Hashes merged, arrays and scalars overrided. Left and right precedence.

=item B<L_REPLACE>, B<R_REPLACE>

Nothing merged. One thing simply replaced by another. Left and right precedence.

=back

Default is B<R_OVERRIDE>

=back

=head1 SEE ALSO

L<ndproc(1)>, L<ndproc-modules(1)>

L<nddiff(1)>, L<ndquery(1)>, L<Struct::Path::PerlStyle>

