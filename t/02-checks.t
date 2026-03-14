#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir tempfile);
use lib "$RealBin/../lib";

use Vagus::Log;
Vagus::Log::init(dry_run => 1);

use Vagus::Checks;
use Vagus::State;

# --- Test check_cron (with real crontab) ---
my $cron = Vagus::Checks::check_cron();
ok($cron, 'check_cron returns a result');
ok(exists $cron->{status}, 'check_cron has status');
ok(exists $cron->{errors}, 'check_cron has errors array');
ok(ref $cron->{errors} eq 'ARRAY', 'errors is an array');

# Test with a command that fails
my $bad_cron = Vagus::Checks::check_cron(crontab_cmd => 'false');
is($bad_cron->{status}, 'error', 'Failed crontab command returns error');

# --- Test check_usage (mock) ---
# Create a mock script that outputs usage data
my ($fh, $mock_script) = tempfile(SUFFIX => '.sh', UNLINK => 1);
print $fh "#!/bin/bash\necho '5hr=25|4pm'\necho 'weekly=30|Mar20'\necho 'sonnet=5|Mar20'\n";
close $fh;
chmod 0755, $mock_script;

my $usage = Vagus::Checks::check_usage(script => $mock_script);
is($usage->{status}, 'ok', 'Usage check succeeds with mock');
is($usage->{'5hr'}, 25, 'Parsed 5hr correctly');
is($usage->{weekly}, 30, 'Parsed weekly correctly');
is($usage->{sonnet}, 5, 'Parsed sonnet correctly');

# Test with failing script
my ($fh2, $fail_script) = tempfile(SUFFIX => '.sh', UNLINK => 1);
print $fh2 "#!/bin/bash\nexit 1\n";
close $fh2;
chmod 0755, $fail_script;

my $fail_usage = Vagus::Checks::check_usage(script => $fail_script);
is($fail_usage->{status}, 'scrape_failed', 'Failed script returns scrape_failed');

# Test with missing script
my $missing = Vagus::Checks::check_usage(script => '/nonexistent/script.sh');
is($missing->{status}, 'scrape_failed', 'Missing script returns scrape_failed');

# --- Test check_mail ---
my $tmpdir = tempdir(CLEANUP => 1);
my $mstate = Vagus::State->new(dir => $tmpdir);
my $mail = Vagus::Checks::check_mail(state => $mstate);
ok($mail, 'check_mail returns result');
ok(exists $mail->{imap_running}, 'Has imap_running field');
# imap_running might be 0 or 1 depending on the system
ok($mail->{imap_running} == 0 || $mail->{imap_running} == 1, 'imap_running is boolean');

done_testing();
