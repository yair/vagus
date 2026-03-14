#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use lib "$RealBin/../lib";

use Vagus::Config;

# --- Test loading config ---
my $conf = Vagus::Config->new(path => "$RealBin/../vagus.conf");
ok($conf, 'Config loaded');

# --- Test deep accessor ---
is($conf->get('telegram.jay_chat_id'), '6554979373', 'Deep accessor works');
is($conf->get('thresholds.mail_stale_hours'), 4, 'Threshold accessor');
is($conf->get('nonexistent.key'), undef, 'Missing key returns undef');
is($conf->get('thresholds.nonexistent'), undef, 'Missing nested key returns undef');

# --- Test convenience methods ---
ok($conf->state_dir, 'state_dir returns value');
ok($conf->log_file, 'log_file returns value');
is($conf->threshold('usage_5hr_warn'), 70, 'threshold() shortcut');

# --- Test quiet hours ---
# Quiet: 23:00 - 08:00
ok($conf->is_quiet_hour(23), '23:00 is quiet');
ok($conf->is_quiet_hour(0),  '00:00 is quiet');
ok($conf->is_quiet_hour(3),  '03:00 is quiet');
ok($conf->is_quiet_hour(7),  '07:00 is quiet');
ok(!$conf->is_quiet_hour(8), '08:00 is not quiet');
ok(!$conf->is_quiet_hour(12), '12:00 is not quiet');
ok(!$conf->is_quiet_hour(22), '22:00 is not quiet');

# --- Test working hours ---
# Working: 10:00 - 19:00
ok($conf->is_working_hour(10), '10:00 is working');
ok($conf->is_working_hour(14), '14:00 is working');
ok($conf->is_working_hour(18), '18:00 is working');
ok(!$conf->is_working_hour(9),  '09:00 is not working');
ok(!$conf->is_working_hour(19), '19:00 is not working');
ok(!$conf->is_working_hour(23), '23:00 is not working');

# --- Test missing config ---
eval { Vagus::Config->new(path => '/nonexistent/vagus.conf') };
ok($@, 'Missing config file throws error');

done_testing();
