package Ocsinventory::LoggerBackend::File;
use strict;

sub new {
    my (undef, $params) = @_;

    my $self = {};
    $self->{config} = $params->{config};
    $self->{logfile} = $self->{config}->{logdir}."/".$self->{config}->{logfile};

    bless $self;
}

sub addMsg {

    my ($self, $args) = @_;

    my $level = $args->{level};
    my $message = $args->{message};
    my $ppid = getppid();  # Get parent process ID for logging

    return if $message =~ /^$/;

    open FILE, ">>".$self->{config}->{logfile} or warn "Can't open ".
    "`".$self->{config}->{logfile}."'\n";
    print FILE "[".localtime()."][$ppid:$$][$level] $message\n";
    close FILE;

}

1;
