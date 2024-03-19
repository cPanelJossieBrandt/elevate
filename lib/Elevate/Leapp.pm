package Elevate::Leapp;

=encoding utf-8

=head1 NAME

Elevate::Leapp

Object to install and execute the leapp script

=cut

use cPstrict;

use Cpanel::JSON ();
use Cpanel::Pkgr ();

use Elevate::OS  ();
use Elevate::YUM ();

use Config::Tiny ();

use Log::Log4perl qw(:easy);

use constant LEAPP_REPORT_JSON    => q[/var/log/leapp/leapp-report.json];
use constant LEAPP_REPORT_TXT     => q[/var/log/leapp/leapp-report.txt];
use constant LEAPP_UPGRADE_LOG    => q[/var/log/leapp/leapp-upgrade.log];
use constant LEAPP_FAIL_CONT_FILE => q[/var/cpanel/elevate_leap_fail_continue];

use Simple::Accessor qw{
  cpev
  yum
};

sub _build_cpev {
    die q[Missing cpev];
}

sub _build_yum ($self) {
    return Elevate::YUM->new( cpev => $self->cpev() );
}

sub install ($self) {

    unless ( Cpanel::Pkgr::is_installed('elevate-release') ) {
        my $elevate_rpm_url = Elevate::OS::elevate_rpm_url();
        $self->yum->install_rpm_via_url($elevate_rpm_url);
    }

    my $leapp_data_pkg = Elevate::OS::leapp_data_pkg();

    unless ( Cpanel::Pkgr::is_installed('leapp-upgrade') && Cpanel::Pkgr::is_installed($leapp_data_pkg) ) {
        $self->yum->install( 'leapp-upgrade', $leapp_data_pkg );
    }

    return;
}

sub remove_kernel_devel ($self) {

    if ( Cpanel::Pkgr::is_installed('kernel-devel') ) {
        $self->yum->remove('kernel-devel');
    }

    return;
}

sub preupgrade ($self) {

    INFO("Running leapp preupgrade checks");

    $self->cpev->ssystem_hide_output( '/usr/bin/leapp', 'preupgrade' );

    INFO("Finished running leapp preupgrade checks");

    return;
}

sub upgrade ($self) {

    return unless $self->cpev->should_run_leapp();

    $self->cpev->run_once(
        setup_answer_file => sub {
            $self->setup_answer_file();
        },
    );

    my $leapp_flag = Elevate::OS::leapp_flag();
    my $leapp_bin  = '/usr/bin/leapp';
    my @leapp_args = ('upgrade');
    push( @leapp_args, $leapp_flag ) if $leapp_flag;

    INFO("Running leapp upgrade");

    my $ok = eval {
        local $ENV{LEAPP_OVL_SIZE} = cpev::read_stage_file('env')->{'LEAPP_OVL_SIZE'} || 3000;
        $self->cpev->ssystem_and_die( { keep_env => 1 }, $leapp_bin, @leapp_args );
        1;
    };

    return 1 if $ok;

    $self->_report_leapp_failure_and_die();
    return;
}

sub search_report_file_for_blockers ( $self, @ignored_blockers ) {

    my @blockers;
    my $leapp_json_report = LEAPP_REPORT_JSON;

    if ( !-e $leapp_json_report ) {
        ERROR("Leapp did not generate the expected report file: $leapp_json_report");
        return [
            {
                title   => "Leapp did not generate $leapp_json_report",
                summary => "It is expected that leapp generate a JSON report file",
            }
        ];
    }

    my $report = eval { Cpanel::JSON::LoadFile($leapp_json_report) } // {};
    if ( my $exception = $@ ) {
        ERROR("Unable to parse leapp report file ($leapp_json_report): $exception");
        return [
            {
                title   => "Unable to parse leapp report file $leapp_json_report",
                summary => "The JSON report file generated by LEAPP is unreadable or corrupt",
            }
        ];
    }

    my $entries = $report->{entries};
    return [] unless ( ref $entries eq 'ARRAY' );

    foreach my $entry (@$entries) {
        next unless ( ref $entry eq 'HASH' );

        # If it is a blocker, then it will contain an array
        # of flags one of which will be named "inhibitor"
        my $flags = $entry->{flags};
        next unless ( ref $flags eq 'ARRAY' );
        next unless scalar grep { $_ eq 'inhibitor' } @$flags;

        # Some blockers we ignore because we fix them before upgrade
        next if scalar grep { $_ eq $entry->{actor} } @ignored_blockers;

        my $blocker = {
            title   => $entry->{title},
            summary => $entry->{summary},
        };

        if ( ref $entry->{detail}{remediations} eq 'ARRAY' ) {
            foreach my $rem ( @{ $entry->{detail}{remediations} } ) {
                next unless ( $rem->{type} && $rem->{context} );
                if ( $rem->{type} eq 'hint' ) {
                    $blocker->{hint} = $rem->{context};
                }
                if ( $rem->{type} eq 'command' && ref $rem->{context} eq 'ARRAY' ) {
                    $blocker->{command} = join ' ', @{ $rem->{context} };
                }
            }
        }

        push @blockers, $blocker;
    }

    return \@blockers;
}

sub check_upgrade_log_for_failures ($self) {
    my $upgrade_log = LEAPP_UPGRADE_LOG;

    if ( !-e $upgrade_log ) {
        ERROR("No LEAPP upgrade log detected at [$upgrade_log]");

        return 1;
    }

    my $out = $self->cpev->ssystem_capture_output( '/usr/bin/grep', '-E', "\\sERROR\\s", $upgrade_log );

    if ( scalar @{ $out->{'stdout'} } ) {
        if ( -e LEAPP_FAIL_CONT_FILE ) {
            INFO( "Found LEAPP upgrade errors, but continuing anyway because " . LEAPP_FAIL_CONT_FILE . " exists" );

            return 0;
        }
        else {
            ERROR('There were errors during the LEAPP process.');
            ERROR( join( '\n', @{ $out->{'stdout'} } ) );

            return 1;
        }
    }

    return 0;
}

sub _report_leapp_failure_and_die ($self) {

    my $msg = <<'EOS';
The 'leapp upgrade' process failed.

Please investigate, resolve then re-run the following command to continue the update:

    /scripts/elevate-cpanel --continue

EOS

    my $leapp_json_report = LEAPP_REPORT_JSON;
    if ( -e $leapp_json_report ) {
        my $report = eval { Cpanel::JSON::LoadFile($leapp_json_report) } // {};

        my $entries = $report->{entries};
        if ( ref $entries eq 'ARRAY' ) {
            foreach my $e (@$entries) {
                next unless ref $e && $e->{title} =~ qr{Missing.*answer}i;

                $msg .= $e->{summary} if $e->{summary};

                if ( ref $e->{detail} ) {
                    my $d = $e->{detail};

                    if ( ref $d->{remediations} ) {
                        foreach my $remed ( $d->{remediations}->@* ) {
                            next unless $remed->{type} && $remed->{type} eq 'command';
                            next unless ref $remed->{context};
                            my @hint = $remed->{context}->@*;
                            next unless scalar @hint;
                            $hint[0] = q[/usr/bin/leapp] if $hint[0] && $hint[0] eq 'leapp';
                            my $cmd = join( ' ', @hint );

                            $msg .= "\n\n";
                            $msg .= <<"EOS";
Consider running this command:

    $cmd
EOS
                        }
                    }

                }

            }
        }
    }

    if ( -e LEAPP_REPORT_TXT ) {
        $msg .= qq[\nYou can read the full leapp report at: ] . LEAPP_REPORT_TXT;
    }

    die qq[$msg\n];
    return;
}

sub setup_answer_file ($self) {
    my $leapp_dir = '/var/log/leapp';
    mkdir $leapp_dir unless -d $leapp_dir;

    my $answerfile_path = $leapp_dir . '/answerfile';
    system touch => $answerfile_path unless -e $answerfile_path;

    my $do_write;    # no point in overwriting the file if nothing needs to change

    my $ini_obj = Config::Tiny->read( $answerfile_path, 'utf8' );
    LOGDIE( 'Failed to read leapp answerfile: ' . Config::Tiny->errstr ) unless $ini_obj;

    my $SECTION = 'remove_pam_pkcs11_module_check';

    if ( not defined $ini_obj->{$SECTION}->{'confirm'} or $ini_obj->{$SECTION}->{'confirm'} ne 'True' ) {
        $do_write = 1;
        $ini_obj->{$SECTION}->{'confirm'} = 'True';
    }

    if ($do_write) {
        $ini_obj->write( $answerfile_path, 'utf8' )    #
          or LOGDIE( 'Failed to write leapp answerfile: ' . $ini_obj->errstr );
    }

    return;
}

1;
