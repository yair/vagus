#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use JSON::PP;
use lib "$RealBin/../lib";

# Suppress log output in tests (but allow writes)
use Vagus::Log;
Vagus::Log::init(dry_run => 0, verbose => 0);

use Vagus::State;

my $tmpdir = tempdir(CLEANUP => 1);
my $state = Vagus::State->new(dir => $tmpdir);
ok($state, 'State object created');

# --- Test read/write JSON ---
my $data = { foo => 'bar', nested => { key => 'val' } };
ok($state->write_json('test.json', $data), 'write_json succeeds');
is_deeply($state->read_json('test.json'), $data, 'read_json returns written data');

# --- Test default for missing file ---
is_deeply($state->read_json('missing.json'), {}, 'Missing file returns empty hashref');
is_deeply($state->read_json('missing.json', { default => 1 }), { default => 1 }, 'Missing file returns custom default');

# --- Test update_key ---
$state->write_json('wakes.json', {});
$state->update_key('wakes.json', 'last_wake.zeresh.ts', '2026-03-14T14:00:00+0100');
my $wakes = $state->read_json('wakes.json');
is($wakes->{last_wake}{zeresh}{ts}, '2026-03-14T14:00:00+0100', 'update_key creates nested path');

# Update existing key
$state->update_key('wakes.json', 'last_wake.zeresh.reason', 'cron_error');
$wakes = $state->read_json('wakes.json');
is($wakes->{last_wake}{zeresh}{reason}, 'cron_error', 'update_key sets sibling key');
is($wakes->{last_wake}{zeresh}{ts}, '2026-03-14T14:00:00+0100', 'Previous key preserved');

# --- Test age_of ---
# Write a timestamp 60 seconds ago
my $ts_60ago = POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime(time() - 60));
$state->update_key('wakes.json', 'last_wake.recent.ts', $ts_60ago);
my $age = $state->age_of('wakes.json', 'last_wake', 'recent', 'ts');
ok(defined $age, 'age_of returns a value');
ok($age >= 58 && $age <= 65, "age_of is ~60s (got $age)");

# Missing key
is($state->age_of('wakes.json', 'last_wake', 'nonexistent', 'ts'), undef, 'age_of returns undef for missing key');

# --- Test append_jsonl ---
# Writes already enabled
ok($state->append_jsonl('escalations.jsonl', { check => 'test', result => 'ok' }), 'append_jsonl succeeds');
ok($state->append_jsonl('escalations.jsonl', { check => 'test2', result => 'error' }), 'second append');

my $path = "$tmpdir/escalations.jsonl";
ok(-f $path, 'JSONL file created');
open my $fh, '<', $path;
my @lines = <$fh>;
close $fh;
is(scalar @lines, 2, 'Two JSONL lines written');
my $line1 = decode_json($lines[0]);
is($line1->{check}, 'test', 'First JSONL record correct');

# --- Test atomic write (corrupt data handling) ---
# Write garbage to a state file
open $fh, '>', "$tmpdir/corrupt.json";
print $fh "not json {{{";
close $fh;
my $result = $state->read_json('corrupt.json', { fallback => 1 });
is_deeply($result, { fallback => 1 }, 'Corrupt file returns default');

done_testing();
