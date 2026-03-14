package Vagus::Actions;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Vagus::Log;

my $HTTP = HTTP::Tiny->new(timeout => 15);

# Send a Telegram message. Zero OC tokens.
sub telegram_alert {
    my (%args) = @_;
    my $token   = $args{bot_token} or return 0;
    my $chat_id = $args{chat_id}   or return 0;
    my $text    = $args{text}       or return 0;

    Vagus::Log::info("telegram_alert -> chat=$chat_id text=" . substr($text, 0, 80) . "...");

    if (Vagus::Log::is_dry_run()) {
        Vagus::Log::info("[DRY-RUN] Would send Telegram: $text");
        return 1;
    }

    my $url = "https://api.telegram.org/bot$token/sendMessage";
    my $resp = $HTTP->post_form($url, {
        chat_id    => $chat_id,
        text       => $text,
        parse_mode => 'Markdown',
    });

    if ($resp->{success}) {
        Vagus::Log::info("Telegram alert sent successfully");
        return 1;
    } else {
        Vagus::Log::error("Telegram alert failed: $resp->{status} $resp->{content}");
        return 0;
    }
}

# Wake an OC agent by sending a message to its session via the gateway webhook.
sub wake_agent {
    my (%args) = @_;
    my $gateway_url   = $args{gateway_url}   or return 0;
    my $gateway_token = $args{gateway_token} or return 0;
    my $agent         = $args{agent}         // 'main';
    my $message       = $args{message}       or return 0;

    Vagus::Log::info("wake_agent -> agent=$agent message=" . substr($message, 0, 80) . "...");

    if (Vagus::Log::is_dry_run()) {
        Vagus::Log::info("[DRY-RUN] Would wake agent '$agent': $message");
        return 1;
    }

    # Use gateway webhook endpoint
    # /hooks/wake for main agent, /hooks/agent for specific agents
    my ($url, $payload);

    if ($agent eq 'main') {
        $url = "$gateway_url/hooks/wake";
        $payload = { text => $message, mode => 'now' };
    } else {
        $url = "$gateway_url/hooks/agent";
        $payload = {
            message   => $message,
            agentId   => $agent,
            wakeMode  => 'now',
            deliver   => JSON::PP::true,
            name      => "Vagus → $agent",
            sessionKey => "hook:vagus-$agent",
        };
    }

    my $resp = $HTTP->post($url, {
        headers => {
            'Content-Type'  => 'application/json',
            'Authorization' => "Bearer $gateway_token",
        },
        content => encode_json($payload),
    });

    if ($resp->{success}) {
        Vagus::Log::info("Agent '$agent' woken successfully");
        return 1;
    } else {
        Vagus::Log::error("Failed to wake agent '$agent' via hook: $resp->{status} $resp->{content}");
        Vagus::Log::warn_("Gateway hook failed. Cannot wake agent.");
        return 0;
    }
}

# Update the /tmp/usage-warning flag file
sub set_usage_flag {
    my (%args) = @_;

    if (Vagus::Log::is_dry_run()) {
        Vagus::Log::debug("[DRY-RUN] Would update /tmp/usage-warning");
        return 1;
    }

    if ($args{clear}) {
        unlink '/tmp/usage-warning';
        Vagus::Log::info("Cleared /tmp/usage-warning");
        return 1;
    }

    open my $fh, '>', '/tmp/usage-warning' or do {
        Vagus::Log::error("Cannot write /tmp/usage-warning: $!");
        return 0;
    };
    print $fh "timestamp=$args{timestamp}\n";
    print $fh "5hr=$args{'5hr'}\n"       if defined $args{'5hr'};
    print $fh "weekly=$args{weekly}\n"    if defined $args{weekly};
    print $fh "triggered=$args{triggered}\n" if $args{triggered};
    close $fh;
    return 1;
}

1;
