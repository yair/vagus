#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use lib "$RealBin/../lib";

use Vagus::Log;
Vagus::Log::init(dry_run => 0, verbose => 0);

use Vagus::Config;
use Vagus::State;
use Vagus::Rules;

my $conf = Vagus::Config->new(path => "$RealBin/../vagus.conf");
my $tmpdir = tempdir(CLEANUP => 1);
my $state = Vagus::State->new(dir => $tmpdir);

# --- Test: All clear ---
{
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
        },
    );
    is($action, undef, 'All clear: no action');
}

# --- Test: Cron error fires wake_zeresh ---
{
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'error', errors => ['heartbeat-gated-cron.log: some error'] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
        },
    );
    ok($action, 'Cron error: action returned');
    is($action->{rule}, 'cron_error', 'Cron error rule fired');
    is($action->{action}, 'wake_zeresh', 'Action is wake_zeresh');
    like($action->{message}, qr/Cron errors/, 'Message mentions cron errors');
}

# --- Test: Cron error doesn't re-fire within cooldown ---
{
    # Simulate that zeresh was already woken 30 min ago
    my $ts_30min = POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime(time() - 1800));
    $state->update_key('wakes.json', 'last_wake.zeresh_cron.ts', $ts_30min);

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'error', errors => ['some error'] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
        },
    );
    is($action, undef, 'Cron error within cooldown: no action');

    # Clean up
    $state->write_json('wakes.json', {});
}

# --- Test: Usage high fires telegram ---
{
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 75, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
        },
    );
    ok($action, 'Usage high: action returned');
    is($action->{rule}, 'usage_high', 'Usage high rule fired');
    is($action->{action}, 'telegram_jay', 'Action is telegram');
    like($action->{message}, qr/75%/, 'Message contains percentage');
}

# --- Test: Usage scrape failure accumulates ---
{
    # Reset state
    $state->write_json('health.json', {});
    $state->write_json('wakes.json', {});

    # Simulate 5 failures (below threshold of 6)
    for my $i (1..5) {
        my $action = Vagus::Rules::evaluate(
            conf   => $conf,
            state  => $state,
            checks => {
                cron  => { status => 'ok', errors => [] },
                usage => { status => 'scrape_failed', reason => 'test' },
                mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            },
        );
        is($action, undef, "Scrape failure $i: no action yet");
    }

    # 6th failure should trigger
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'scrape_failed', reason => 'test' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
        },
    );
    ok($action, '6th scrape failure: action returned');
    is($action->{rule}, 'usage_scraper_broken', 'Scraper broken rule fired');
    is($action->{action}, 'telegram_jay', 'Action is telegram');
}

# --- Test: Mail stale fires wake_junior ---
{
    $state->write_json('wakes.json', {});

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 5 },
        },
    );
    ok($action, 'Mail stale: action returned');
    is($action->{rule}, 'mail_stale', 'Mail stale rule fired');
    is($action->{action}, 'wake_junior', 'Action is wake_junior');
}

# --- Test: Mail stale escalation to zeresh ---
{
    # Junior was woken 3 hours ago
    my $ts_3hr = POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime(time() - 3*3600));
    $state->update_key('wakes.json', 'last_wake.junior_mail.ts', $ts_3hr);

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 7 },
        },
    );
    ok($action, 'Mail escalation: action returned');
    is($action->{rule}, 'mail_stale_escalate', 'Mail escalation rule fired');
    is($action->{action}, 'wake_zeresh', 'Escalated to zeresh');
}

# --- Test: Priority order (cron beats usage beats mail) ---
{
    $state->write_json('wakes.json', {});

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'error', errors => ['big error'] },
            usage => { status => 'ok', '5hr' => 90, weekly => 95, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 0, hours_since_junior_activity => 10 },
        },
    );
    is($action->{rule}, 'cron_error', 'Cron error takes priority over usage and mail');
}

done_testing();
