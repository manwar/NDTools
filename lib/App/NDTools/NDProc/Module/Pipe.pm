package App::NDTools::NDProc::Module::Pipe;

use strict;
use warnings FATAL => 'all';
use parent 'App::NDTools::NDProc::Module';

use IPC::Run3;
use Log::Log4Cli;
use App::NDTools::Slurp qw(s_decode s_encode);
use Struct::Path qw(spath);
use Struct::Path::PerlStyle qw(ps_parse);

sub MODINFO { "Modify structure using external process" }
sub VERSION { "0.03" }

sub arg_opts {
    my $self = shift;

    return (
        $self->SUPER::arg_opts(),
        'command|cmd=s' => \$self->{OPTS}->{command},
        'preserve=s@' => \$self->{OPTS}->{preserve},
        'strict' => \$self->{OPTS}->{strict},
    )
}

sub check_rule {
    my ($self, $rule) = @_;
    my $out = $self;

    # process full source if no paths defined # FIXME: move it to parent and make common for all mods
    push @{$rule->{path}}, '' unless (@{$rule->{path}});

    unless (defined $rule->{command}) {
        log_error { 'Command to run should be defined' };
        $out = undef;
    }

    return $out;
}

sub process_path {
    my ($self, $data, $path, $opts) = @_;

    my $spath = eval { ps_parse($path) };
    die_fatal "Failed to parse path ($@)", 4 if ($@);

    my @refs = eval { spath($data, $spath, strict => $opts->{strict}) };
    die_fatal "Failed to lookup path '$path'", 4 if ($@);

     for my $r (@refs) {
        my $in = s_encode(${$r}, 'JSON', { pretty => 1 });

        my ($out, $err);
        run3($opts->{command}, \$in, \$out, \$err, { return_if_system_error => 1});
        die_fatal "Failed to run '$opts->{command}' ($!)", 2
            if ($? == -1); # run3 specific
        unless ($? == 0) {
            die_fatal "'$opts->{command}' exited with " . ($? >> 8) .
                ($err ? " (" . join(" ", split("\n", $err)) . ")" : ""), 16;
        }

        ${$r} = s_decode($out, 'JSON');
    }
}

1; # End of App::NDTools::NDProc::Module::Pipe

__END__

=head1 NAME

Pipe - pipe structure to external program and apply result.

=head1 OPTIONS

=over 4

=item B<--[no]blame>

Blame calculation toggle. Enabled by default.

=item B<--command|--cmd> E<lt>commandE<gt>

Command to run. Exit 0 expected for success. JSON emitted to it's STDERR
will be applied to original structure.

=item B<--path> E<lt>pathE<gt>

Structure to send to cammand's STDIN.

=item B<--preserve> E<lt>pathE<gt>

Preserve specified structure parts. May be used several times.

=item B<--strict>

Fail if specified path doesn't exists.

=back

=head1 SEE ALSO

L<ndproc(1)>, L<ndproc-modules>

L<nddiff(1)>, L<ndquery(1)>, L<Struct::Path::PerlStyle>
