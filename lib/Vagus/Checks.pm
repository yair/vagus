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
    my $disabled     = $args{disabled}     // 0;

    if ($disabled) {
        return { status => 'disabled', node => $node_name, reason => 'check disabled (travel/maintenance)' };
    }

    # SSH config — primary liveness check
    my $ssh_host = $args{ssh_host} // 'localhost';
    my $ssh_port = $args{ssh_port} // 2222;
    my $ssh_user = $args{ssh_user} // 'zeresh';
    my $ssh_check_cmd = $args{ssh_check_cmd}
        // "ps aux | grep 'openclaw-node' | grep -v grep | wc -l";

    # Try SSH probe — this is the definitive check
    my $ssh_cmd = "ssh -p $ssh_port -o ConnectTimeout=5 -o StrictHostKeyChecking=no "
                . "-o BatchMode=yes $ssh_user\@$ssh_host '$ssh_check_cmd' 2>/dev/null";

    my $ssh_output = `$ssh_cmd`;
    my $ssh_exit = $? >> 8;

    if ($ssh_exit == 0) {
        chomp $ssh_output;
        my $proc_count = int($ssh_output || 0);

        if ($proc_count > 0) {
            # Node process is running — all good
            # Touch heartbeat file for historical tracking
            my $heartbeat_file = "/home/oc/.vagus/state/node-heartbeat-$node_name";
            if (open my $fh, '>', $heartbeat_file) {
                print $fh time() . "\n";
                close $fh;
            }
            return {
                status => 'ok',
                node   => $node_name,
                check  => 'ssh',
                procs  => $proc_count,
            };
        } else {
            # SSH works but openclaw-node process not running
            return {
                status => 'offline',
                node   => $node_name,
                check  => 'ssh',
                reason => 'SSH reachable but openclaw-node process not running',
            };
        }
    }

    # SSH failed — tunnel might be down, or machine is off
    # Fall back to paired.json token staleness as a secondary signal
    my $paired_file = '/home/oc/.openclaw/devices/paired.json';
    unless (-f $paired_file) {
        return {
            status => 'unknown',
            node   => $node_name,
            check  => 'ssh-failed',
            reason => "SSH unreachable (exit=$ssh_exit) and no paired devices file",
        };
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
        return { status => 'unknown', node => $node_name, check => 'ssh-failed', reason => "SSH unreachable, paired.json parse error: $@" };
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
        return { status => 'offline', node => $node_name, check => 'ssh-failed', reason => "SSH unreachable and node not found in paired devices" };
    }

    # Check last used timestamp from the node's operator token
    my $last_used;
    for my $tok (values %{$node_entry->{tokens} // {}}) {
        my $lu = $tok->{lastUsedAtMs};
        $last_used = $lu if defined $lu && (!defined $last_used || $lu > $last_used);
    }

    my $stale_threshold_hours = $args{stale_hours} // 1;

    if (defined $last_used) {
        my $hours_since = (time() * 1000 - $last_used) / (3600 * 1000);
        my $age_str = sprintf("%.1f", $hours_since);

        if ($hours_since > $stale_threshold_hours) {
            return {
                status => 'offline',
                node   => $node_name,
                check  => 'ssh-failed+token-stale',
                hours_since_seen => $age_str,
                reason => "SSH unreachable and token stale (${age_str}h)",
            };
        }
        return {
            status => 'ok',
            node   => $node_name,
            check  => 'token-only',
            hours_since_seen => $age_str,
            reason => "SSH unreachable but token recent (${age_str}h) — tunnel may be down",
        };
    }

    return {
        status => 'offline',
        node   => $node_name,
        check  => 'ssh-failed+no-token',
        reason => 'SSH unreachable and no recent token activity',
    };
}

1;
