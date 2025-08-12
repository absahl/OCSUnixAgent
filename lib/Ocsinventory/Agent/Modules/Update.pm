################################################################################
## ITAM Update Module
## Parses prolog response to extract update parameters and writes
## an update configuration XML file at:
##   <installpath>/update/info
################################################################################

package Ocsinventory::Agent::Modules::Update;

use strict;
use warnings;

use File::Path qw(make_path);
use XML::Simple;

sub new {
    my $name = "update";

    my (undef, $context) = @_;
    my $self = {};

    $self->{logger} = new Ocsinventory::Logger({
        config => $context->{config},
    });
    $self->{logger}->{header} = "[$name]";

    $self->{context} = $context;

    $self->{structure} = {
        name => $name,
        start_handler => undef,
        prolog_writer => undef,
        prolog_reader => $name . "_prolog_reader",
        inventory_handler => undef,
        end_handler => undef,
    };

    bless $self;
}

sub _extract_update_from_option_params {
    my ($params_arrayref) = @_;
    my %update = (
        URL_SUFFIX   => undef,
        VERSION      => undef,
        ARGS         => undef,
        FORCE_UPDATE => undef,
    );

    # Strict: consider only PARAM with TYPE == 'PACK'
    foreach my $param (@{$params_arrayref || []}) {
        # Debug: show PARAM TYPEs encountered (kept minimal to avoid noise)
        # Only proceed on TYPE == PACK
        next unless (defined $param->{TYPE} && $param->{TYPE} eq 'PACK');
        foreach my $key (qw(URL_SUFFIX VERSION ARGS FORCE_UPDATE)) {
            if (exists $param->{$key} && defined $param->{$key} && $param->{$key} ne '') {
                $update{$key} = $param->{$key};
            }
        }
    }

    return \%update;
}

sub _write_update_info_xml {
    my ($self, $update_href) = @_;
    my $logger  = $self->{logger};
    my $context = $self->{context};
    my $config  = $context->{config};

    # Compute output dir under install path
    my $base_dir  = $context->{installpath} || $config->{basevardir} || '/var/lib/ocsinventory-agent';
    my $output_dir = $base_dir . '/update';
    $logger->debug("[update] Computed output directory: $output_dir");

    # Ensure directory exists
    eval { make_path($output_dir) };
    if ($@) {
        $logger->error("Failed to create directory $output_dir: $@");
        return 0;
    }

    my $info_path = $output_dir . '/info';
    $logger->debug("[update] Writing update info to: $info_path");

    my $data = {
        UPDATE => {
            URL_SUFFIX   => defined $update_href->{URL_SUFFIX}   ? $update_href->{URL_SUFFIX}   : '',
            VERSION      => defined $update_href->{VERSION}      ? $update_href->{VERSION}      : '',
            ARGS         => defined $update_href->{ARGS}         ? $update_href->{ARGS}         : '',
            FORCE_UPDATE => defined $update_href->{FORCE_UPDATE} ? $update_href->{FORCE_UPDATE} : '',
        }
    };

    my $xml;
    eval {
        $xml = XMLout(
            $data,
            RootName   => undef,   # prevent wrapping in extra root element
            XMLDecl    => '<?xml version="1.0" encoding="UTF-8"?>',
        );
    };
    if ($@ || !defined $xml) {
        $logger->error("Failed to generate update XML: $@");
        return 0;
    }

    if (open(my $fh, '>', $info_path)) {
        print $fh $xml;
        close $fh;
        $logger->info("Wrote update config to $info_path");
        return 1;
    } else {
        $logger->error("Cannot open $info_path for writing: $!");
        return 0;
    }
}

sub update_prolog_reader {
    my ($self, $prolog_raw_xml) = @_;

    my $logger  = $self->{logger};
    my $context = $self->{context};
    my $config  = $context->{config};

    $logger->debug('[update] Entering update_prolog_reader');
    # Parse prolog XML; be resilient to variations
    my $prolog;
    eval {
        $prolog = XML::Simple::XMLin($prolog_raw_xml, ForceArray => ['OPTION', 'PARAM']);
    };
    if ($@ || !$prolog) {
        $logger->error("Failed to parse prolog XML for update: $@");
        return;
    }

    my $options = $prolog->{OPTION} || [];
    $logger->debug('[update] Prolog OPTION count: ' . scalar(@{$options}));
    my $update_params;

    foreach my $opt (@{$options}) {
        my $name = $opt->{NAME} || '';
        # Strict: only accept NAME == UPDATE (case-sensitive)
        if (defined $name && $name eq 'UPDATE') {
            $logger->debug('[update] Found OPTION NAME=UPDATE');
            $update_params = _extract_update_from_option_params($opt->{PARAM});
            last;
        }
    }

    # If no update option found, nothing to do
    unless ($update_params) {
        $logger->debug("[update] No update option found in prolog; skipping update config generation");
        return;
    }

    # Require at least URL_SUFFIX and VERSION to consider update available
    my $has_url     = defined $update_params->{URL_SUFFIX} && $update_params->{URL_SUFFIX} ne '';
    my $has_version = defined $update_params->{VERSION}    && $update_params->{VERSION}    ne '';
    $logger->debug('[update] Extracted params - URL_SUFFIX: ' . (defined $update_params->{URL_SUFFIX} ? 'set' : 'unset')
                  . ', VERSION: ' . (defined $update_params->{VERSION} ? $update_params->{VERSION} : 'unset')
                  . ', ARGS: ' . (defined $update_params->{ARGS} ? $update_params->{ARGS} : 'unset')
                  . ', FORCE_UPDATE: ' . (defined $update_params->{FORCE_UPDATE} ? $update_params->{FORCE_UPDATE} : 'unset'));
    unless ($has_url && $has_version) {
        $logger->info("[update] Update option present but missing URL_SUFFIX or VERSION; skipping");
        return;
    }

    # Write using internalized output path
    _write_update_info_xml($self, $update_params);
}

1;


