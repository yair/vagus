package Vagus::Log;
use strict;
use warnings;
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $LOG_FH;
my $LOG_PATH;
my $DRY_RUN = 0;
my $VERBOSE = 0;

sub init {
    my (%args) = @_;
    $LOG_PATH = $args{path};
    $DRY_RUN  = $args{dry_run} // 0;
    $VERBOSE  = $args{verbose} // 0;

    if ($LOG_PATH) {
        make_path(dirname($LOG_PATH));
        open $LOG_FH, '>>', $LOG_PATH
            or warn "Cannot open log $LOG_PATH: $!";
        if ($LOG_FH) {
            $LOG_FH->autoflush(1);
        }
    }
}

sub _ts { strftime('%Y-%m-%dT%H:%M:%S%z', localtime) }

sub _write {
    my ($level, $msg) = @_;
    my $line = sprintf("[%s] [%s]%s %s",
        _ts(), $level,
        ($DRY_RUN ? ' [DRY-RUN]' : ''),
        $msg);

    if ($LOG_FH) {
        print $LOG_FH "$line\n";
    }
    if ($VERBOSE || $level eq 'ERROR') {
        print STDERR "$line\n";
    }
}

sub info  { _write('INFO',  $_[0]) }
sub warn_ { _write('WARN',  $_[0]) }
sub error { _write('ERROR', $_[0]) }
sub debug { _write('DEBUG', $_[0]) if $VERBOSE }

sub is_dry_run { $DRY_RUN }

sub close_log {
    close $LOG_FH if $LOG_FH;
    $LOG_FH = undef;
}

1;
