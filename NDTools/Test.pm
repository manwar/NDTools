package NDTools::Test;

use strict;
use warnings FATAL => 'all';
use parent qw(Exporter);

use Capture::Tiny qw(capture);
use Data::Dumper;
use Test::More;

our @EXPORT = qw(
    run_ok
    t_ab_cmp
    t_dir
    t_dump
);

sub run_ok {
    my %t = @_;

    my @envs = exists $t{env} ? %{$t{env}} : ();
    SET_ENV: # can't use loop here - env vars will be localized in it's block
    @envs and local $ENV{$envs[0]} = $envs[1];
    if (@envs) {
        splice @envs, 0, 2;
        goto SET_ENV;
    }

    if (exists $t{pre} and not $t{pre}->()) {
        fail("Pre hook for '$t{name}' failed");
        return;
    }

    my ($out, $err, $exit) = capture { system(@{$t{cmd}}) };

    subtest $t{name} => sub {
        local $Test::Builder::Level = $Test::Builder::Level + 6;

        for my $std ('stdout', 'stderr') {
            next if (exists $t{$std} and not defined $t{$std}); # set to undef to skip test
            $t{$std} = '' unless (exists $t{$std});             # silence expected by default

            my $desc = uc($std) . " check for $t{name}: [" . join(" ", @{$t{cmd}}) ."]";
            my $data = $std eq 'stdout' ? $out : $err;

            if (ref $t{$std} eq 'CODE') {
                ok($t{$std}->($data), $desc);
            } elsif (ref $t{$std} eq 'Regexp') {
                like($data, $t{$std}, $desc);
            } else {
                is($data, $t{$std}, $desc);
            }
        }

        if (not exists $t{exit} or defined $t{exit}) {  # set to undef to skip test
            $t{exit} = 0 unless exists $t{exit};        # defailt exit code
            is(
                $exit >> 8, $t{exit},
                "Exit code check for $t{name}: [" . join(" ", @{$t{cmd}}) ."]"
            );
        }

        $t{test}->() if (exists $t{test});

        if (exists $t{post} and not $t{post}->()) {
            fail("Post hook for '$t{name}' failed");
            return;
        }

        done_testing();
    }
}

sub t_ab_cmp {
    return "GOT: " . neat_dump(shift) . "\nEXP: " . neat_dump(shift);
}

sub t_dir {
    my $tfile = shift || (caller)[1];
    substr($tfile, 0, length($tfile) - 1) . "d";
}

sub t_dump {
    return Data::Dumper->new([shift])->Terse(1)->Sortkeys(1)->Quotekeys(0)->Indent(0)->Deepcopy(1)->Dump();
}

1;
