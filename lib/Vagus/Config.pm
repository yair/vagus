package Vagus::Config;
use strict;
use warnings;
use JSON::PP;
use File::Spec;
use Carp qw(croak);

sub new {
    my ($class, %args) = @_;
    my $path = $args{path} // _default_path();
    croak "Config file not found: $path" unless -f $path;

    open my $fh, '<', $path or croak "Cannot open $path: $!";
    local $/;
    my $json = <$fh>;
    close $fh;

    my $data = decode_json($json);
    return bless { data => $data, path => $path }, $class;
}

sub _default_path {
    # Look for vagus.conf next to the script, or in /home/oc/projects/vagus/
    my $dir = $ENV{VAGUS_ROOT} // '/home/oc/projects/vagus';
    return File::Spec->catfile($dir, 'vagus.conf');
}

# Deep accessor: $conf->get('telegram.jay_chat_id')
sub get {
    my ($self, $key) = @_;
    my @parts = split /\./, $key;
    my $val = $self->{data};
    for my $p (@parts) {
        return undef unless ref $val eq 'HASH' && exists $val->{$p};
        $val = $val->{$p};
    }
    return $val;
}

# Convenience: all thresholds
sub threshold {
    my ($self, $key) = @_;
    return $self->get("thresholds.$key");
}

sub state_dir  { $_[0]->get('state_dir') }
sub log_file   { $_[0]->get('log_file') }

sub is_quiet_hour {
    my ($self, $hour) = @_;
    $hour //= (localtime)[2];
    my $start = $self->get('quiet_hours.start');
    my $end   = $self->get('quiet_hours.end');
    # Handle wrap-around (e.g., 23-8)
    if ($start > $end) {
        return ($hour >= $start || $hour < $end);
    }
    return ($hour >= $start && $hour < $end);
}

sub is_working_hour {
    my ($self, $hour) = @_;
    $hour //= (localtime)[2];
    my $start = $self->get('working_hours.start');
    my $end   = $self->get('working_hours.end');
    return ($hour >= $start && $hour < $end);
}

1;
