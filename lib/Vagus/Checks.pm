package Vagus::Checks;
use strict;
use warnings;
use Vagus::Log;

# Check cron for errors. Returns { status => 'ok'|'error', errors => [...] }
sub check_cron {
    my (%args) = @_;
    my $cmd = $args{crontab_cmd} // 'crontab -l';

    my @errors;

    # 1. Check crontab is readable
    my $crontab = `$cmd 2>&1`;
    if ($? != 0) {
        push @errors, "crontab command failed: $crontab";
    }

    # 2. Check recent log files for errors
    my @log_files = glob('/home/oc/.openclaw/logs/*.log');
    for my $log (@log_files) {
        next if $log =~ /vagus\.log$/;  # Don't check our own log
        next if $log =~ /heartbeat-gate/;  # Old system being replaced by Vagus
        my $basename = (split m{/}, $log)[-1];

        # Only check logs modified in the last hour
        my $mtime = (stat $log)[9] // 0;
        next if (time() - $mtime) > 3600;

        # Read last 20 lines
        my @lines;
        if (open my $fh, '<', $log) {
            my @all = <$fh>;
            close $fh;
            @lines = @all > 20 ? @all[-20..$#all] : @all;
        }

        # Look for errors in recent lines
        for my $line (@lines) {
            chomp $line;
            if ($line =~ /\bERROR\b/i && $line !~ /\bERROR: Failed to scrape usage\b/) {
                # Skip known non-critical patterns
                next if $line =~ /No usage warning/;
                next if $line =~ /session file locked/;  # Transient OC lock contention
                next if $line =~ /gateway (?:connect failed|closed)/i;  # OC gateway reconnect noise
                next if $line =~ /unknown option/i;  # CLI arg errors in old scripts
                push @errors, "$basename: $line";
                last;  # One error per log file is enough
            }
        }
    }

    if (@errors) {
        return { status => 'error', errors => \@errors };
    }
    return { status => 'ok', errors => [] };
}

# Check usage via existing script. Returns parsed data or failure info.
sub check_usage {
    my (%args) = @_;
    my $script = $args{script};

    unless ($script && -x $script) {
        return { status => 'scrape_failed', reason => "Script not found or not executable: $script" };
    }

    my $output = `$script 2>/dev/null`;
    my $exit = $? >> 8;

    if (!$output || $output !~ /\d/) {
        return { status => 'scrape_failed', reason => "No parseable output" };
    }

    my %usage;
    for my $line (split /\n/, $output) {
        if ($line =~ /^(\w+)=(\d+)\|(.*)$/) {
            $usage{$1} = { pct => int($2), reset => $3 };
        }
    }

    unless ($usage{'5hr'} || $usage{weekly}) {
        return { status => 'scrape_failed', reason => "Could not parse usage fields" };
    }

    return {
        status  => 'ok',
        '5hr'   => $usage{'5hr'}{pct}   // -1,
        weekly  => $usage{weekly}{pct}   // -1,
        sonnet  => $usage{sonnet}{pct}   // -1,
        '5hr_reset'   => $usage{'5hr'}{reset}   // '',
        weekly_reset  => $usage{weekly}{reset}   // '',
        raw     => $output,
    };
}

# Check mail state. Verifies IMAP watcher is running and mail is flowing.
# Uses multiple signals: IMAP watcher process, triage session activity,
# and recent mail delivery (Maildir mtime).
sub check_mail {
    my (%args) = @_;
    my $state = $args{state};  # Vagus::State object

    # Check if IMAP watcher is running
    my $imap_running = 0;
    my $ps = `pgrep -f 'imap-idle' 2>/dev/null`;
    $imap_running = 1 if $ps && $ps =~ /\d+/;

    # Check triage session activity via OC sessions registry
    # (Junior works through hooks + sessions_send, not workspace files)
    my $triage_sessions = '/home/oc/.openclaw/agents/triage/sessions/sessions.json';
    my $last_triage_activity;
    if (-f $triage_sessions) {
        my $mtime = (stat $triage_sessions)[9] // 0;
        $last_triage_activity = $mtime if $mtime > 0;
    }

    # Also check the most recent mail arrival in any Maildir
    my $mail_dir = '/home/oc/mail/zeresh';
    my $last_mail;
    if (-d $mail_dir) {
        # Check new/ and cur/ dirs across all folders for recent mail
        my @dirs = glob("$mail_dir/*/new $mail_dir/*/cur $mail_dir/INBOX/new $mail_dir/INBOX/cur");
        for my $d (@dirs) {
            next unless -d $d;
            my $mtime = (stat $d)[9] // 0;
            $last_mail = $mtime if $mtime > ($last_mail // 0);
        }
    }

    # Use the most recent signal: triage session activity OR mail delivery
    my $best_activity = $last_triage_activity // 0;
    $best_activity = $last_mail if defined $last_mail && $last_mail > $best_activity;

    my $hours_since_activity = $best_activity > 0
        ? (time() - $best_activity) / 3600
        : undef;

    return {
        status => 'ok',
        imap_running => $imap_running,
        hours_since_junior_activity => $hours_since_activity,
    };
}

# Check if a remote OC node is connected.
# Uses the gateway WebSocket endpoint to verify node is reachable.
sub check_node {
    my (%args) = @_;
    my $node_name = $args{node_name} // 'zhizi-zeresh';

    if ($args{disabled}) {
        return { status => 'disabled', node => $node_name, reason => 'check disabled (travel/maintenance)' };
    }

    # Liveness via the gateway's OWN node registry (authoritative). Replaces the old
    # `ssh -p 2222 zeresh@localhost` probe + paired.json operator-token staleness, both
    # of which broke when the SSH tunnel was retired for the tailnet (2026-05-28): the
    # ssh probe failed outright, and the operator token's lastUsedAtMs tracks
    # operation-use (frozen ~Feb), NOT connection -- so it falsely reported the node
    # offline with a bogus "last seen 2181h" while it was in fact connected over the mesh.
    my $oc  = $args{oc_bin} // '/home/oc/.npm-global/bin/openclaw';
    my $out = `$oc nodes status --json 2>/dev/null`;
    my $exit = $? >> 8;
    if ($exit != 0 || !length $out) {
        return { status => 'unknown', node => $node_name, check => 'gateway-unreachable',
                 reason => "could not query 'openclaw nodes status' (exit=$exit)" };
    }

    my $data;
    eval { require JSON::PP; $data = JSON::PP::decode_json($out); 1 }
        or return { status => 'unknown', node => $node_name, check => 'parse-error',
                    reason => "nodes status JSON parse error: $@" };

    my $entry;
    for my $n (@{ $data->{nodes} // [] }) {
        if (($n->{displayName} // '') eq $node_name) { $entry = $n; last; }
    }
    unless ($entry) {
        return { status => 'offline', node => $node_name, check => 'nodes-status',
                 hours_since_seen => '?', reason => 'node not present in gateway registry' };
    }

    my $last_ms = $entry->{lastSeenAtMs} // $entry->{connectedAtMs};
    my $hours_since_seen = defined $last_ms
        ? sprintf('%.1f', (time() * 1000 - $last_ms) / 3_600_000) : '?';

    if ($entry->{connected}) {
        my $hb = "/home/oc/.vagus/state/node-heartbeat-$node_name";
        if (open my $fh, '>', $hb) { print $fh time() . "\n"; close $fh; }
        return { status => 'ok', node => $node_name, check => 'nodes-status',
                 hours_since_seen => $hours_since_seen };
    }

    return { status => 'offline', node => $node_name, check => 'nodes-status',
             hours_since_seen => $hours_since_seen,
             reason => 'gateway reports node not connected' };
}

1;
