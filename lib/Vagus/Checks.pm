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

# Check mail state. Reads from state file written by IMAP watcher or Junior.
# For now: checks if the IMAP idle watcher process is running,
# and reads mail state from the Junior triage workspace.
sub check_mail {
    my (%args) = @_;
    my $state = $args{state};  # Vagus::State object

    # Check if IMAP watcher is running
    my $imap_running = 0;
    my $ps = `pgrep -f 'imap-idle' 2>/dev/null`;
    $imap_running = 1 if $ps && $ps =~ /\d+/;

    # Check Junior's last activity (triage workspace)
    my $triage_dir = '/home/oc/.openclaw/workspace-triage';
    my $last_activity;
    if (-d $triage_dir) {
        # Find most recently modified file
        my @files = glob("$triage_dir/*");
        my $newest = 0;
        for my $f (@files) {
            my $mtime = (stat $f)[9] // 0;
            $newest = $mtime if $mtime > $newest;
        }
        $last_activity = $newest if $newest > 0;
    }

    my $hours_since_activity = defined $last_activity
        ? (time() - $last_activity) / 3600
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
    my $node_name    = $args{node_name}    // 'zhizi-zeresh';
    my $gateway_url  = $args{gateway_url}  // 'http://127.0.0.1:18789';
    my $gateway_token = $args{gateway_token};
    my $disabled     = $args{disabled}     // 0;

    if ($disabled) {
        return { status => 'disabled', node => $node_name, reason => 'check disabled (travel/maintenance)' };
    }

    # Check if the node's paired device entry exists and has a recent token
    my $paired_file = '/home/oc/.openclaw/devices/paired.json';
    unless (-f $paired_file) {
        return { status => 'unknown', node => $node_name, reason => 'no paired devices file' };
    }

    my $paired;
    eval {
        open my $fh, '<', $paired_file or die;
        local $/;
        my $json = <$fh>;
        close $fh;
        require JSON::PP;
        $paired = JSON::PP::decode_json($json);
    };
    if ($@) {
        return { status => 'unknown', node => $node_name, reason => "parse error: $@" };
    }

    # Find the node entry
    my $node_entry;
    for my $dev (values %$paired) {
        if (($dev->{displayName} // '') eq $node_name && ($dev->{clientMode} // '') eq 'node') {
            $node_entry = $dev;
            last;
        }
    }

    unless ($node_entry) {
        return { status => 'error', node => $node_name, reason => 'node not found in paired devices' };
    }

    # Check last used timestamp from the node's operator token
    my $last_used;
    for my $tok (values %{$node_entry->{tokens} // {}}) {
        my $lu = $tok->{lastUsedAtMs};
        $last_used = $lu if defined $lu && (!defined $last_used || $lu > $last_used);
    }

    my $hours_since_seen;
    if (defined $last_used) {
        $hours_since_seen = (time() * 1000 - $last_used) / (3600 * 1000);
    }

    # Check if the node's WebSocket connection is alive by looking at the
    # gateway log for recent node activity. The token lastUsedAtMs is unreliable
    # (only updates on explicit token use, not on WS keepalive).
    # 
    # Best heuristic: check if the node's device has connected recently
    # by looking at createdAtMs vs lastUsedAtMs, and also check the OC log
    # for recent node-related activity.
    my $connected = 0;

    # Check gateway log for recent node mentions (last 10 min)
    my @log_candidates = (
        '/tmp/openclaw/openclaw-' . POSIX::strftime('%Y-%m-%d', localtime()) . '.log',
    );
    for my $logf (@log_candidates) {
        next unless -f $logf;
        # Only check if log was modified recently
        my $lmtime = (stat $logf)[9] // 0;
        next if (time() - $lmtime) > 600;  # log untouched for 10 min

        # Check last 100 lines for node activity
        if (open my $fh, '<', $logf) {
            my @all = <$fh>;
            close $fh;
            my @tail = @all > 100 ? @all[-100..$#all] : @all;
            for my $line (reverse @tail) {
                if ($line =~ /\Q$node_name\E/i && $line =~ /connect|node|browser|relay/i) {
                    $connected = 1;
                    last;
                }
            }
        }
        last;
    }

    # If token was used in the last 24h, consider it alive
    # (tokens get used on browser relay, exec relay, etc.)
    my $stale_threshold_hours = $args{stale_hours} // 24;  # Default 24h for token staleness
    my $is_stale = defined $hours_since_seen && $hours_since_seen > $stale_threshold_hours;

    if ($is_stale && !$connected) {
        return {
            status => 'offline',
            node   => $node_name,
            hours_since_seen => defined $hours_since_seen ? sprintf("%.1f", $hours_since_seen) : 'unknown',
            reason => 'node appears offline (stale token + no recent log activity)',
        };
    }

    return {
        status => 'ok',
        node   => $node_name,
        hours_since_seen => defined $hours_since_seen ? sprintf("%.1f", $hours_since_seen) : 'unknown',
        connected => $connected,
    };
}

1;
