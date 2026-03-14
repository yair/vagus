package Vagus::State;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Spec;
use Vagus::Log;

my $JSON = JSON::PP->new->utf8->pretty->canonical;

sub new {
    my ($class, %args) = @_;
    my $dir = $args{dir} or die "State dir required";
    make_path($dir) unless -d $dir;
    return bless { dir => $dir }, $class;
}

sub _path {
    my ($self, $name) = @_;
    return File::Spec->catfile($self->{dir}, $name);
}

# Read a JSON state file. Returns hashref or default.
sub read_json {
    my ($self, $name, $default) = @_;
    $default //= {};
    my $path = $self->_path($name);
    return $default unless -f $path;

    open my $fh, '<', $path or do {
        Vagus::Log::warn_("Cannot read state $path: $!");
        return $default;
    };
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { decode_json($raw) };
    if ($@) {
        Vagus::Log::warn_("Corrupt state file $path: $@");
        return $default;
    }
    return $data;
}

# Write a JSON state file atomically.
sub write_json {
    my ($self, $name, $data) = @_;
    my $path = $self->_path($name);
    my $tmp  = "$path.tmp.$$";

    if (Vagus::Log::is_dry_run()) {
        Vagus::Log::debug("Would write state: $name");
        return 1;
    }

    open my $fh, '>', $tmp or do {
        Vagus::Log::error("Cannot write state $tmp: $!");
        return 0;
    };
    print $fh $JSON->encode($data);
    close $fh;
    rename $tmp, $path or do {
        Vagus::Log::error("Cannot rename $tmp -> $path: $!");
        unlink $tmp;
        return 0;
    };
    return 1;
}

# Append a line to a JSONL file (escalation log).
sub append_jsonl {
    my ($self, $name, $record) = @_;
    $record->{ts} //= Vagus::Log::_ts() if Vagus::Log->can('_ts');

    if (Vagus::Log::is_dry_run()) {
        Vagus::Log::debug("Would append to $name: " . encode_json($record));
        return 1;
    }

    my $path = $self->_path($name);
    open my $fh, '>>', $path or do {
        Vagus::Log::error("Cannot append to $path: $!");
        return 0;
    };
    print $fh encode_json($record) . "\n";
    close $fh;
    return 1;
}

# Get age of a timestamp key in a state file (in seconds).
# Returns undef if key doesn't exist.
sub age_of {
    my ($self, $file, @keys) = @_;
    my $data = $self->read_json($file);
    my $val = $data;
    for my $k (@keys) {
        return undef unless ref $val eq 'HASH' && exists $val->{$k};
        $val = $val->{$k};
    }
    return undef unless defined $val;

    # Parse ISO 8601-ish timestamp
    my $epoch = _parse_ts($val);
    return undef unless defined $epoch;
    return time() - $epoch;
}

sub _parse_ts {
    my ($ts) = @_;
    return undef unless $ts;
    # Handle epoch seconds directly
    return $ts if $ts =~ /^\d{10,}$/;
    # Handle ISO 8601: 2026-03-14T14:00:00+01:00
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        require POSIX;
        my @t = ($6, $5, $4, $3, $2 - 1, $1 - 1900);
        return POSIX::mktime(@t);
    }
    return undef;
}

# Convenience: update a nested key in a state file.
sub update_key {
    my ($self, $file, $key_path, $value) = @_;
    my $data = $self->read_json($file);
    my @keys = split /\./, $key_path;
    my $ref = $data;
    for my $i (0 .. $#keys - 1) {
        $ref->{$keys[$i]} //= {};
        $ref = $ref->{$keys[$i]};
    }
    $ref->{$keys[-1]} = $value;
    return $self->write_json($file, $data);
}

sub now_ts {
    require POSIX;
    return POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime);
}

1;
