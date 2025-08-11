package Ocsinventory::Agent::XML::Prolog;

use strict;
use warnings;

use XML::Simple;
use Digest::MD5 qw(md5_base64);

sub new {
    my (undef, $params) = @_;

    my $self = {};
    $self->{config} = $params->{context}->{config};

    $self->{logger} = $params->{context}->{logger};

    die unless ($self->{config}->{deviceid}); #XXX

    $self->{xmlroot}{QUERY} = ['PROLOG'];
    $self->{xmlroot}{DEVICEID} = [$self->{config}->{deviceid}];

    # Include extra context in prolog: TAG, agent version and OS family
    my $context = $params->{context} || {};

    # Prefer TAG from persisted accountinfo; fallback to CLI/config tag
    my $tag = eval { $context->{accountinfo}->{accountinfo}->{TAG} } || $self->{config}->{tag};
    $self->{xmlroot}{TAG} = [$tag] if defined $tag && $tag ne '';

    # Agent version
    my $itam_version = $self->{config}->{itam_version};
    $self->{xmlroot}{VERSION} = [$itam_version] if defined $itam_version && $itam_version ne '';

    # Removed OSNAME and OSVERSION as requested; only send simplified OS below

    # Simplified OS indicator for server-side logic: macos | ubuntu | debian
    my $os_type;
    if (uc($^O) eq 'DARWIN') {
        $os_type = 'macos';
    } else {
        my $os_release = '/etc/os-release';
        if (-r $os_release) {
            my ($id, $id_like);
            if (open my $fh, '<', $os_release) {
                while (my $line = <$fh>) {
                    chomp $line;
                    $line =~ s/^\s+|\s+$//g;
                    if ($line =~ /^ID=(?:"|')?(.*?)(?:"|')?$/i) {
                        $id = lc $1;
                    } elsif ($line =~ /^ID_LIKE=(?:"|')?(.*?)(?:"|')?$/i) {
                        $id_like = lc $1;
                    }
                }
                close $fh;
            }
            if (defined $id && $id eq 'ubuntu') {
                $os_type = 'ubuntu';
            } elsif (defined $id && $id eq 'debian') {
                $os_type = 'debian';
            } elsif (defined $id_like && $id_like =~ /ubuntu/) {
                $os_type = 'ubuntu';
            } elsif (defined $id_like && $id_like =~ /debian/) {
                $os_type = 'debian';
            }
        }
    }
    $self->{xmlroot}{OS} = [$os_type] if defined $os_type && $os_type ne '';

    bless $self;
}

sub dump {
    my $self = shift;
    eval "use Data::Dumper;";
    print Dumper($self->{xmlroot});

}

sub getContent {
    my ($self, $args) = @_;

    my $content=XMLout( $self->{xmlroot}, RootName => 'REQUEST', XMLDecl => '<?xml version="1.0" encoding="UTF-8"?>', SuppressEmpty => undef );

    return $content;
}

1;
