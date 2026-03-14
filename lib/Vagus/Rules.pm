package Vagus::Rules;
use strict;
use warnings;
use POSIX qw(strftime);
use Vagus::Log;
use Vagus::Actions;

# Evaluate all rules in priority order. Returns the first action to take,
# or undef if all clear. Only ONE action per invocation (prevents storm).
#
# Args:
#   conf    => Vagus::Config
#   state   => Vagus::State
#   checks  => { cron => {...}, usage => {...}, mail => {...} }
#
# Returns: { rule => $name, action => $action_name, %params } or undef

sub evaluate {
    my (%args) = @_;
    my $conf   = $args{conf};
    my $state  = $args{state};
    my $checks = $args{checks};

    my $now_ts = Vagus::State::now_ts();
    my $hour   = (localtime)[2];
    my $is_quiet   = $conf->is_quiet_hour($hour);
    my $is_working = $conf->is_working_hour($hour);

    # --- Rule 1: Cron errors (critical) ---
    if ($checks->{cron}{status} eq 'error' && @{$checks->{cron}{errors}}) {
        my $errors = join("\n", @{$checks->{cron}{errors}});
        my $age = $state->age_of('wakes.json', 'last_wake', 'zeresh_cron', 'ts');
        my $threshold = ($conf->threshold('cron_rewake_hours') // 2) * 3600;

        if (!defined $age || $age > $threshold) {
            return {
                rule    => 'cron_error',
                action  => 'wake_zeresh',
                message => "[Vagus] Cron errors detected. Fix permanently.\n\n$errors",
                state_update => { file => 'wakes.json', key => 'last_wake.zeresh_cron.ts', val => $now_ts },
                escalation => { check => 'cron', result => 'error', action => 'wake_zeresh' },
            };
        }

        # Already woken, check if we need to escalate to Jay
        my $esc_threshold = ($conf->threshold('cron_escalate_hours') // 4) * 3600;
        if (defined $age && $age > $esc_threshold) {
            return {
                rule    => 'cron_error_escalate',
                action  => 'telegram_jay',
                message => "⚠️ *Cron errors persist* (agent was woken ${\ int($age/3600)}h ago, didn't fix):\n\n$errors",
                state_update => { file => 'wakes.json', key => 'last_wake.zeresh_cron.ts', val => $now_ts },
                escalation => { check => 'cron', result => 'persists', action => 'telegram_jay' },
            };
        }

        Vagus::Log::info("Cron errors present but already handling (age=${\ int(($age//0)/60)}m)");
    }

    # --- Rule 2: Usage scraper broken ---
    if ($checks->{usage}{status} eq 'scrape_failed') {
        my $health = $state->read_json('health.json');
        my $fails = ($health->{usage}{consecutive_scrape_failures} // 0) + 1;

        # Update failure count
        $state->update_key('health.json', 'usage.consecutive_scrape_failures', $fails);
        $state->update_key('health.json', 'usage.last_scrape_attempt', $now_ts);

        my $max = $conf->threshold('usage_scrape_fail_max') // 6;
        if ($fails >= $max) {
            my $alert_age = $state->age_of('wakes.json', 'last_wake', 'usage_scrape_alert', 'ts');
            if (!defined $alert_age || $alert_age > 6 * 3600) {
                return {
                    rule    => 'usage_scraper_broken',
                    action  => 'telegram_jay',
                    message => "⚠️ *Usage scraper broken*\n${fails} consecutive failures (~${\int($fails*10/60)}h).\nCannot monitor token limits — flying blind!",
                    state_update => { file => 'wakes.json', key => 'last_wake.usage_scrape_alert.ts', val => $now_ts },
                    escalation => { check => 'usage_scrape', result => 'broken', action => 'telegram_jay', fails => $fails },
                };
            }
        }
    }

    # --- Rule 3: Usage high ---
    if ($checks->{usage}{status} eq 'ok') {
        # Reset failure counter on success
        $state->update_key('health.json', 'usage.consecutive_scrape_failures', 0);
        $state->update_key('health.json', 'usage.last_scrape', $now_ts);

        my $pct_5hr  = $checks->{usage}{'5hr'}  // 0;
        my $pct_week = $checks->{usage}{weekly}  // 0;
        my $warn_5hr  = $conf->threshold('usage_5hr_warn')  // 70;
        my $warn_week = $conf->threshold('usage_weekly_warn') // 80;

        my @triggered;
        push @triggered, "5hr" if $pct_5hr >= $warn_5hr;
        push @triggered, "weekly" if $pct_week >= $warn_week;

        if (@triggered) {
            # Check cooldowns
            my $alert_age = $state->age_of('wakes.json', 'last_wake', 'usage_alert', 'ts');
            my $cooldown = $conf->threshold('usage_5hr_alert_cooldown_min') // 30;
            $cooldown *= 60;

            if (!defined $alert_age || $alert_age > $cooldown) {
                my $triggered_str = join('+', @triggered);
                Vagus::Actions::set_usage_flag(
                    timestamp => $now_ts,
                    '5hr'     => $pct_5hr,
                    weekly    => $pct_week,
                    triggered => $triggered_str,
                );
                return {
                    rule    => 'usage_high',
                    action  => 'telegram_jay',
                    message => "⚠️ *Usage Alert*\n5-hour: ${pct_5hr}% (resets $checks->{usage}{'5hr_reset'})\nWeekly: ${pct_week}% (resets $checks->{usage}{weekly_reset})",
                    state_update => { file => 'wakes.json', key => 'last_wake.usage_alert.ts', val => $now_ts },
                    escalation => { check => 'usage', result => 'high', action => 'telegram_jay', pct_5hr => $pct_5hr, pct_week => $pct_week },
                };
            }
        } else {
            # Usage healthy — clear flag if set
            Vagus::Actions::set_usage_flag(clear => 1) if -f '/tmp/usage-warning';
        }
    }

    # --- Rule 4: Mail system stale ---
    if ($checks->{mail}) {
        my $hours = $checks->{mail}{hours_since_junior_activity};
        my $stale_threshold = $conf->threshold('mail_stale_hours') // 4;
        my $escalate_threshold = $conf->threshold('mail_stale_escalate_hours') // 6;

        if (defined $hours && $hours > $stale_threshold) {
            my $junior_age = $state->age_of('wakes.json', 'last_wake', 'junior_mail', 'ts');
            my $junior_cooldown = ($conf->threshold('junior_rewake_hours') // 2) * 3600;

            # Check escalation first: if Junior was woken and mail is STILL stale past escalate threshold
            if (defined $junior_age && $hours > $escalate_threshold) {
                my $zeresh_age = $state->age_of('wakes.json', 'last_wake', 'zeresh_mail', 'ts');
                my $zeresh_cooldown = ($conf->threshold('zeresh_mail_rewake_hours') // 4) * 3600;

                if (!defined $zeresh_age || $zeresh_age > $zeresh_cooldown) {
                    return {
                        rule    => 'mail_stale_escalate',
                        action  => 'wake_zeresh',
                        message => "[Vagus] Mail system stale for ${\ int($hours)}h. Junior was woken but didn't fix it. Diagnose the mail pipeline and tell Jay.",
                        state_update => { file => 'wakes.json', key => 'last_wake.zeresh_mail.ts', val => $now_ts },
                        escalation => { check => 'mail', result => 'still_stale', action => 'wake_zeresh', hours => int($hours) },
                    };
                }
            }

            # Otherwise, wake Junior if not recently woken
            if (!defined $junior_age || $junior_age > $junior_cooldown) {
                return {
                    rule    => 'mail_stale',
                    action  => 'wake_junior',
                    message => "[Vagus] Mail triage appears stale (${\ int($hours)}h since last activity). Check IMAP watcher and process inbox.",
                    state_update => { file => 'wakes.json', key => 'last_wake.junior_mail.ts', val => $now_ts },
                    escalation => { check => 'mail', result => 'stale', action => 'wake_junior', hours => int($hours) },
                };
            }
        }
    }

    # --- Rule 5: Batch work (lowest priority, only when coast is clear) ---
    # Deferred for now. Placeholder for future todo-driven batch work.
    # When implemented: check $is_quiet, $is_working, usage levels, cooldown,
    # then pick a todo and wake a worker agent.

    # --- Rule 0: All clear ---
    return undef;
}

1;
