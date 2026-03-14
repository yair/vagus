#!/usr/bin/env perl
# vagus.pl — Heartbeat control plane
# Runs on cron, checks health, wakes agents when needed.
# Zero LLM tokens consumed by Vagus itself.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use Getopt::Long;

use Vagus::Config;
use Vagus::Log;
use Vagus::State;
use Vagus::Checks;
use Vagus::Rules;
use Vagus::Actions;

# --- CLI args ---
my $dry_run = 0;
my $verbose = 0;
my $config_path;
GetOptions(
    'dry-run|n' => \$dry_run,
    'verbose|v' => \$verbose,
    'config|c=s' => \$config_path,
) or die "Usage: $0 [--dry-run] [--verbose] [--config path]\n";

$ENV{VAGUS_ROOT} //= $RealBin;

# --- Init ---
my $conf = Vagus::Config->new($config_path ? (path => $config_path) : ());

Vagus::Log::init(
    path    => $conf->log_file,
    dry_run => $dry_run,
    verbose => $verbose,
);

Vagus::Log::info("=== Vagus starting" . ($dry_run ? " (DRY RUN)" : "") . " ===");

my $state = Vagus::State->new(dir => $conf->state_dir);

# --- Run checks ---
Vagus::Log::info("Running health checks...");

my %checks;

# 1. Cron
$checks{cron} = Vagus::Checks::check_cron(
    crontab_cmd => $conf->get('scripts.crontab_cmd'),
);
Vagus::Log::info("Cron: $checks{cron}{status}" .
    ($checks{cron}{status} eq 'error' ? " (" . scalar(@{$checks{cron}{errors}}) . " errors)" : ""));

# 2. Usage
$checks{usage} = Vagus::Checks::check_usage(
    script => $conf->get('scripts.check_usage'),
);
if ($checks{usage}{status} eq 'ok') {
    Vagus::Log::info("Usage: 5hr=$checks{usage}{'5hr'}% weekly=$checks{usage}{weekly}%");
} else {
    Vagus::Log::warn_("Usage: $checks{usage}{status} - $checks{usage}{reason}");
}

# 3. Mail
$checks{mail} = Vagus::Checks::check_mail(state => $state);
Vagus::Log::info("Mail: imap_running=$checks{mail}{imap_running}" .
    (defined $checks{mail}{hours_since_junior_activity}
        ? " junior_age=" . int($checks{mail}{hours_since_junior_activity}) . "h"
        : " junior_age=unknown"));

# --- Update health state ---
$state->update_key('health.json', 'last_check', Vagus::State::now_ts());
if ($checks{usage}{status} eq 'ok') {
    $state->update_key('health.json', 'usage.5hr_pct',  $checks{usage}{'5hr'});
    $state->update_key('health.json', 'usage.weekly_pct', $checks{usage}{weekly});
}

# --- Evaluate rules ---
my $action = Vagus::Rules::evaluate(
    conf   => $conf,
    state  => $state,
    checks => \%checks,
);

if (!$action) {
    Vagus::Log::info("All clear. No action needed.");
    $state->append_jsonl('escalations.jsonl', {
        check  => 'all',
        result => 'clear',
    });
    Vagus::Log::info("=== Vagus done ===");
    exit 0;
}

# --- Execute action ---
Vagus::Log::info("Rule fired: $action->{rule} -> $action->{action}");

my $success = 0;

if ($action->{action} eq 'telegram_jay') {
    $success = Vagus::Actions::telegram_alert(
        bot_token => $conf->get('telegram.zeresh_bot_token'),
        chat_id   => $conf->get('telegram.jay_chat_id'),
        text      => $action->{message},
    );
}
elsif ($action->{action} eq 'wake_zeresh') {
    $success = Vagus::Actions::wake_agent(
        gateway_url   => $conf->get('openclaw.gateway_url'),
        gateway_token => $conf->get('openclaw.gateway_token'),
        agent         => 'main',
        message       => $action->{message},
    );
}
elsif ($action->{action} eq 'wake_junior') {
    $success = Vagus::Actions::wake_agent(
        gateway_url   => $conf->get('openclaw.gateway_url'),
        gateway_token => $conf->get('openclaw.gateway_token'),
        agent         => 'triage',
        message       => $action->{message},
    );
}
elsif ($action->{action} eq 'wake_worker') {
    $success = Vagus::Actions::wake_agent(
        gateway_url   => $conf->get('openclaw.gateway_url'),
        gateway_token => $conf->get('openclaw.gateway_token'),
        agent         => 'main',  # For now; will be a separate worker agent later
        message       => $action->{message},
    );
}
else {
    Vagus::Log::error("Unknown action: $action->{action}");
}

# --- Update state ---
if ($success && $action->{state_update}) {
    my $su = $action->{state_update};
    $state->update_key($su->{file}, $su->{key}, $su->{val});
}

if ($action->{escalation}) {
    $state->append_jsonl('escalations.jsonl', {
        %{$action->{escalation}},
        success => $success ? 1 : 0,
    });
}

Vagus::Log::info("Action " . ($success ? "succeeded" : "FAILED") . ": $action->{rule}");
Vagus::Log::info("=== Vagus done ===");

exit($success ? 0 : 1);
