#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use JSON::PP;
use lib "$RealBin/../lib";

use Vagus::Log;
Vagus::Log::init(dry_run => 0, verbose => 0);

use Vagus::Config;
use Vagus::State;
use Vagus::Checks;
use Vagus::Rules;

my $conf = Vagus::Config->new(path => "$RealBin/../vagus.conf");
my $tmpdir = tempdir(CLEANUP => 1);
my $state = Vagus::State->new(dir => $tmpdir);

# --- Test check_node with disabled flag ---
{
    my $result = Vagus::Checks::check_node(
        node_name => 'test-node',
        disabled  => 1,
    );
    is($result->{status}, 'disabled', 'Disabled node returns disabled status');
}

# --- Test check_node with missing paired file ---
{
    my $result = Vagus::Checks::check_node(
        node_name     => 'nonexistent',
        gateway_url   => 'http://127.0.0.1:99999',  # won't connect
        gateway_token => 'fake',
    );
    # Should return something (ok/unknown/offline) — not crash
    ok($result, 'check_node with real paired file returns result');
    ok(exists $result->{status}, 'Has status field');
}

# --- Test Rules: node offline fires telegram ---
{
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            nodes => {
                'zhizi-zeresh' => {
                    status => 'offline',
                    node   => 'zhizi-zeresh',
                    hours_since_seen => '2.5',
                    reason => 'test',
                },
            },
        },
    );
    ok($action, 'Node offline: action returned');
    is($action->{rule}, 'node_offline', 'Node offline rule fired');
    is($action->{action}, 'telegram_jay', 'Action is telegram');
    like($action->{message}, qr/zhizi-zeresh/, 'Message mentions node name');
    like($action->{message}, qr/2\.5h/, 'Message mentions hours');
}

# --- Test Rules: node offline respects cooldown ---
{
    # Simulate alert sent 30 min ago (within 2hr cooldown)
    my $ts_30min = POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime(time() - 1800));
    $state->update_key('wakes.json', 'last_wake.node_offline_zhizi_zeresh.ts', $ts_30min);

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            nodes => {
                'zhizi-zeresh' => {
                    status => 'offline',
                    node   => 'zhizi-zeresh',
                    hours_since_seen => '2.5',
                },
            },
        },
    );
    is($action, undef, 'Node offline within cooldown: no action');
}

# --- Test Rules: node ok doesn't fire ---
{
    $state->write_json('wakes.json', {});  # clear state

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            nodes => {
                'zhizi-zeresh' => {
                    status => 'ok',
                    node   => 'zhizi-zeresh',
                    hours_since_seen => '0.1',
                    connected => 1,
                },
            },
        },
    );
    is($action, undef, 'Node ok: no action');
}

# --- Test Rules: disabled node doesn't fire ---
{
    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'ok', errors => [] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            nodes => {
                'zhizi-zeresh' => {
                    status => 'disabled',
                    node   => 'zhizi-zeresh',
                    reason => 'travel',
                },
            },
        },
    );
    is($action, undef, 'Disabled node: no action');
}

# --- Test priority: cron beats node offline ---
{
    $state->write_json('wakes.json', {});

    my $action = Vagus::Rules::evaluate(
        conf   => $conf,
        state  => $state,
        checks => {
            cron  => { status => 'error', errors => ['big error'] },
            usage => { status => 'ok', '5hr' => 20, weekly => 30, '5hr_reset' => '4pm', weekly_reset => 'Mar20' },
            mail  => { status => 'ok', imap_running => 1, hours_since_junior_activity => 1 },
            nodes => {
                'zhizi-zeresh' => {
                    status => 'offline',
                    node   => 'zhizi-zeresh',
                    hours_since_seen => '5.0',
                },
            },
        },
    );
    is($action->{rule}, 'cron_error', 'Cron error takes priority over node offline');
}

done_testing();
