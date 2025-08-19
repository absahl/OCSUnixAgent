################################################################################
## ITAM Update Module
## Parses prolog response to extract update parameters and writes
## an update configuration XML file at:
##   <installpath>/update/info
################################################################################

package Ocsinventory::Agent::Modules::Update;

use strict;
use warnings;

use version;
use Fcntl qw/:flock/;
use File::Path qw(make_path remove_tree);
use File::Copy;
use File::Basename qw(basename);
use XML::Simple;
use Digest::MD5;
use POSIX qw(strftime);

sub _format_timestamp_from_mtime {
    my ($path) = @_;
    my @st = stat($path);
    my $mtime = $st[9] || time();
    return strftime('%Y%m%d_%H%M%S', localtime($mtime));
}

sub _ensure_dir_0700 {
    my ($dir, $logger) = @_;
    eval { make_path($dir, { mode => 0700 }); };
    if ($@) {
        $logger->error("Failed to create directory $dir: $@");
        return 0;
    }
    return 1;
}

sub _zip_with_ditto {
    my ($source_dir, $dest_zip, $logger) = @_;
    # On macOS, prefer ditto to preserve metadata
    my $status = system('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', $source_dir, $dest_zip);
    if ($status != 0) {
        my $code = $status >> 8;
        $logger->error("Archiving with ditto failed (exit $code) for $source_dir -> $dest_zip");
        return 0;
    }
    return 1;
}

sub _prune_archives_keep_last_n {
    my ($archives_dir, $keep_n, $logger) = @_;
    opendir(my $dh, $archives_dir) or return;
    my @files = grep { /\.zip$/ && -f "$archives_dir/$_" } readdir($dh);
    closedir($dh);
    return unless @files;
    @files = map { [ $_, (stat("$archives_dir/$_"))[9] || 0 ] } @files;
    @files = sort { $b->[1] <=> $a->[1] } @files; # newest first
    my @to_delete = @files[$keep_n .. $#files] if @files > $keep_n;
    for my $entry (@to_delete) {
        my $file = "$archives_dir/".$entry->[0];
        unlink $file or $logger->debug("Failed to remove old archive $file: $!");
    }
}

sub _archive_and_reset_current {
    my ($base_dir, $logger) = @_;
    my $current_dir  = "$base_dir/current";
    my $archives_dir = "$base_dir/archives";

    # If current exists and has content, archive it
    my $has_content = 0;
    if (-d $current_dir && opendir(my $dhc, $current_dir)) {
        while (my $e = readdir($dhc)) { next if $e =~ /^\.?\.?$/; $has_content = 1; last; }
        closedir($dhc);
    }

    if ($has_content) {
        return 0 unless _ensure_dir_0700($archives_dir, $logger);
        my $ts = _format_timestamp_from_mtime($current_dir);
        my $dest_zip = "$archives_dir/$ts.zip";
        # Avoid filename collision by appending a counter
        my $suffix = 0;
        while (-e $dest_zip) { $suffix++; $dest_zip = "$archives_dir/${ts}_$suffix.zip"; }
        my $ok = _zip_with_ditto($current_dir, $dest_zip, $logger);
        if ($ok) {
            $logger->info("Archived $current_dir to $dest_zip");
            _prune_archives_keep_last_n($archives_dir, 5, $logger);
        }
    } else {
        $logger->debug("No content in $current_dir to archive");
    }

    # Regardless of archive result, remove current to start fresh
    if (-d $current_dir) {
        remove_tree($current_dir, { error => \my $err });
        if ($err && @{$err}) {
            $logger->error("Failed to fully remove $current_dir");
        } else {
            $logger->debug("Removed $current_dir");
        }
    }

    return 1;
}

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
        name              => $name,
        start_handler     => undef,
        prolog_writer     => undef,
        prolog_reader     => $name . "_prolog_reader",
        inventory_handler => undef,
        end_handler       => $name . "_end_handler",
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
    
    # Use the directory already created in prolog_reader
    my $info_path = $context->{installpath} . '/update/info';
    $logger->debug("Writing update info to: $info_path");

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
        chmod 0600, $info_path;
        $logger->info("Wrote update config to $info_path");
        return 1;
    } else {
        $logger->error("Cannot open $info_path for writing: $!");
        return 0;
    }
}

# At the beginning of end handler - implements locking mechanism
sub begin {
    my ($pidfile, $logger) = @_;

    open LOCK_R, "$pidfile" or die("Cannot open pid file: $!");
    if (flock(LOCK_R, LOCK_EX|LOCK_NB)) {
        open LOCK_W, ">$pidfile" or die("Cannot open pid file: $!");
        select(LOCK_W) and $|=1;
        select(STDOUT) and $|=1;
        print LOCK_W $$;
        $logger->info("Beginning work. I am $$.");
        return 0;
    } else {
        close(LOCK_R);
        $logger->error("$pidfile locked. Cannot begin work... :-(");
        return 1;
    }
}

sub update_prolog_reader {
    my ($self, $prolog_raw_xml) = @_;

    my $logger  = $self->{logger};
    my $context = $self->{context};
    my $config  = $context->{config};
    my $network = $context->{network};

    $logger->debug('Entering update_prolog_reader');
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
    $logger->debug('Prolog OPTION count: ' . scalar(@{$options}));
    my $update_params;

    foreach my $opt (@{$options}) {
        my $name = $opt->{NAME} || '';
        # Strict: only accept NAME == UPDATE (case-sensitive)
        if (defined $name && $name eq 'UPDATE') {
            $logger->debug('Found OPTION NAME=UPDATE');
            $update_params = _extract_update_from_option_params($opt->{PARAM});
            last;
        }
    }

    # Create working directory and initialize files
    my $opt_dir = $context->{installpath} . '/update';
    
    # Create working directory if it doesn't exist
    if (!-d $opt_dir) {
        mkdir($opt_dir) or do {
            $logger->error("Cannot create $opt_dir: $!");
            return;
        };
    }
    
    # Create lock file if needed
    unless(-e "$opt_dir/lock") {
        open LOCK, ">$opt_dir/lock" or do {
            $logger->error("Cannot create lock file: $!");
            return;
        };
        close(LOCK);
    }

    # If no update option found, nothing to do
    unless ($update_params) {
        $logger->debug("No update option found in prolog; skipping update config generation");
        return;
    }

    # Require at least URL_SUFFIX and VERSION to consider update available
    my $has_url     = defined $update_params->{URL_SUFFIX} && $update_params->{URL_SUFFIX} ne '';
    my $has_version = defined $update_params->{VERSION}    && $update_params->{VERSION}    ne '';
    $logger->debug('Extracted params - URL_SUFFIX: ' . (defined $update_params->{URL_SUFFIX} ? 'set' : 'unset')
                  . ', VERSION: ' . (defined $update_params->{VERSION} ? $update_params->{VERSION} : 'unset')
                  . ', ARGS: ' . (defined $update_params->{ARGS} ? $update_params->{ARGS} : 'unset')
                  . ', FORCE_UPDATE: ' . (defined $update_params->{FORCE_UPDATE} ? $update_params->{FORCE_UPDATE} : 'unset'));
    unless ($has_url && $has_version) {
        $logger->info("[update] Update option present but missing URL_SUFFIX or VERSION; skipping");
        return;
    }

    _write_update_info_xml($self, $update_params);
}

# Asynchronous end handler for update module
sub update_end_handler {
    my ($self) = @_;
    my $logger  = $self->{logger};
    my $context = $self->{context};
    
    # Define working directory and info file for update module
    my $opt_dir  = $context->{installpath} . '/update';
    my $info_file = "$opt_dir/info";
    my $pidfile  = "$opt_dir/lock";
    
    # Compute expected checksum in the parent process using MD5
    open(my $fh, '<', $info_file) or do {
        $logger->error("Cannot open info file $info_file");
        return;
    };
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    my $expected_checksum = $ctx->hexdigest;
    close($fh);
    
    # Fork a new process
    my $pid = fork();
    if (!defined $pid || $pid < 0) {
        $logger->error("Failed to fork child process <ret:$pid> <err:$!>");
        return;
    } elsif ($pid > 0) {
        $logger->info("Child process forked successfully <pid:$pid>");
        return;  # Parent process exits here
    }
    
    # Child process: Set up signal handler
    $logger->debug("Setting up signal handler for USR1");
    $SIG{'USR1'} = sub {
        $logger->info("received USR1 signal - finishing");
        finish($logger, $context);
    };

    # Change to the update working directory
    chdir($opt_dir) or die("Cannot chdir to working directory...Abort\n");

    # Acquire lock before proceeding
    $logger->debug("Trying to acquire lock");
    if (begin($pidfile, $logger)) {
        exit(0);
    }

    # Execute core task
    $logger->debug("Initiating core update task");
    $self->_update_core_task($expected_checksum);

    # Clean exit through finish
    $logger->debug("Initiating cleanup");
    finish($logger, $context);
}

# Private subroutine containing only the core validation logic
sub _update_core_task {
    my ($self, $expected_checksum) = @_;
    my $logger  = $self->{logger};
    my $context = $self->{context};

    my $info_file = $context->{installpath} . '/update/info';

    # Validate checksum and read info file
    $logger->debug("Opening info file for checksum <$info_file>");
    open(my $fh_child, '<', $info_file) or do {
        $logger->error("Failed to open info file for checksum <$info_file>");
        return 0;
    };
    
    my $child_ctx = Digest::MD5->new;
    $child_ctx->addfile($fh_child);
    my $child_checksum = $child_ctx->hexdigest;
    close($fh_child);

    $logger->debug("Validating checksum: expected <$expected_checksum>, got <$child_checksum>");
    if ($child_checksum eq $expected_checksum) {
        $logger->debug("Checksum matches, proceeding to read info file");
        
        # Read the info file
        $logger->debug("Reading info file <$info_file>");
        my $info = XML::Simple::XMLin("$info_file");
        $logger->debug(sprintf("Update config: Version=%s, URLSuffix=%s, Args=%s, Force=%s",
            $info->{VERSION},
            $info->{URL_SUFFIX},
            $info->{ARGS},
            $info->{FORCE_UPDATE}));

        # Check if update is required
        my $current_version = version->parse($context->{config}->{itam_version} || '0.0.0');
        my $availabe_version = version->parse($info->{VERSION} || '0.0.0');
        my $force_update = $info->{FORCE_UPDATE} || 0;
        
        # Compare versions and check force flag
        if (!$force_update && $current_version >= $info->{VERSION}) {
            $logger->info("Update not required: Current version ($current_version) >= Available version ($info->{VERSION})");
            return 1;
        }
        
        $logger->info(sprintf("Update required: %s (current: %s -> available: %s)", 
            $force_update ? "Force update enabled" : "New version available",
            $current_version,
            $info->{VERSION}
        ));

        # Backup data
        $logger->debug("Backing up data");
        my $backup_ok = $self->_backup_data();
        unless ($backup_ok) {
            $logger->error("Backup failed, aborting update process");
            return 0;
        }
        $logger->debug("Backup successful");

        # Download the installer
        $logger->debug("Downloading installer");
        my $download_ok = $self->_download_installer($info->{URL_SUFFIX});
        unless ($download_ok) {
            $logger->error("Installer download failed, aborting update process");
            return 0;
        }
        $logger->debug("Installer downloaded successfully");

        # Schedule update
        $logger->debug("Scheduling update");
        my $schedule_ok = $self->_schedule_update();
        unless ($schedule_ok) {
            $logger->error("Scheduling update failed, aborting update process");
            return 0;
        }
        $logger->debug("Update scheduled successfully");
        
        return 1;
    } else {
        $logger->error("Checksum mismatch for info file. Expected $expected_checksum but got $child_checksum");
        return 0;
    }
}

sub _backup_data {
    my ($self) = @_;
    my $logger = $self->{logger};
    
    # Auto update backup only supported on macOS
    if ($^O ne 'darwin') {
        $logger->error('Auto update is not available for Linux.');
        return 0;
    }
    
    my $config_dir = '/etc/ocsinventory-agent';
    my $backup_base_dir = '/var/db/ocsinventory-agent/backup';
    my $backup_current_dir = "$backup_base_dir/current";
    my $config_backup_dir = "$backup_current_dir/configs";
    my $log_file = '/var/log/ocsng.log';
    my $logs_backup_dir = "$backup_current_dir/logs";
    
    # Create backup directories if they don't exist
    # Rotate existing backup/current into archives and start fresh
    _archive_and_reset_current($backup_base_dir, $logger);

    eval {
        make_path($config_backup_dir, { mode => 0700 });
        make_path($logs_backup_dir,   { mode => 0700 });
    };
    if ($@) {
        $logger->error("Failed to create backup directories: $@");
        return 0;
    }
    
    # Copy selected configuration files into configs
    my @config_sources = (
        '/etc/ocsinventory-agent/modules.conf',
        '/etc/ocsinventory-agent/ocsinventory-agent.cfg',
        '/Library/LaunchDaemons/org.ocsng.agent.plist',
    );
    foreach my $src_file (@config_sources) {
        my $dest_file = "$config_backup_dir/" . basename($src_file);
        if (-f $src_file) {
            unless (copy($src_file, $dest_file)) {
                $logger->error("Failed to copy $src_file to $dest_file: $!");
                return 0;
            }
        } else {
            $logger->info("Config file $src_file does not exist, skipping");
        }
    }
    
    # Copy log file if it exists
    if (-f $log_file) {
        my $log_dest = "$logs_backup_dir/ocsng.log";
        unless (copy($log_file, $log_dest)) {
            $logger->error("Failed to copy log file $log_file to $log_dest: $!");
            return 0;
        }
    } else {
        $logger->info("Log file $log_file does not exist, skipping backup");
    }
    
    $logger->info("Successfully backed up configuration files and logs");

    # Also copy update stage files needed for scheduling/execution
    my $resources_dir = '/Applications/AssetSonarAgent.app/Contents/Resources';
    my $update_base_dir = '/var/db/ocsinventory-agent/update';
    my $update_current_dir = "$update_base_dir/current";
    my @update_files  = (
        'org.ocsng.update.stage1.plist',
        'update-stage1.sh',
        'org.ocsng.update.stage2.plist',
        'update-stage2.sh',
    );

    # Ensure destination directory exists
    # Rotate existing update/current into archives and start fresh
    _archive_and_reset_current($update_base_dir, $logger);

    eval {
        make_path($update_current_dir, { mode => 0700 });
    };
    if ($@) {
        $logger->error("Failed to create update directory $update_current_dir: $@");
        return 0;
    }

    foreach my $fname (@update_files) {
        my $src = "$resources_dir/$fname";
        my $dst = "$update_current_dir/$fname";
        unless (-f $src) {
            $logger->error("Required update file not found: $src");
            return 0;
        }
        unless (copy($src, $dst)) {
            $logger->error("Failed to copy $src to $dst: $!");
            return 0;
        }
        # Set restrictive permissions; make scripts executable
        if ($fname =~ /\.sh$/) {
            chmod 0700, $dst;
        } else {
            chmod 0644, $dst;
        }
    }

    $logger->info('Copied update stage files to update directory');
    return 1;
}

sub _download_installer {
    my ($self, $url_suffix) = @_;
    my $logger  = $self->{logger};
    my $context = $self->{context};
    my $network = $context->{network};

    $logger->debug("Entering _download_installer with URL_SUFFIX: $url_suffix");

    unless (defined $url_suffix && $url_suffix ne '') {
        $logger->error("No URL_SUFFIX provided in info file, cannot proceed with download");
        return 0;
    }
    
    my $max_tries = 5;  # Default max tries for download
    my $full_url = "https://item-agents.s3.us-east-1.amazonaws.com/" . $url_suffix;
    
    # Choose installer extension based on OS
    my $installer_dir = '/var/db/ocsinventory-agent/update/current';
    my $installer_path = "$installer_dir/$url_suffix";
    
    # Create directory if it doesn't exist
    eval {
        make_path($installer_dir, { mode => 0700 });
    };
    if ($@) {
        $logger->error("Failed to create directory $installer_dir: $@");
        return 0;
    }
    
    $logger->debug("Downloading installer <url:$full_url>");
    my $err_msg;
    for (my $try = 1; $try <= $max_tries; $try++)
    {
        $err_msg = $network->getFileFromUrl($full_url, $installer_path);
        last unless defined($err_msg); # break early if not failed
    }

    # In case of failure
    if (defined($err_msg)) {
        $logger->error("Failed to download installer in maximum tries <error:$err_msg> <tries:$max_tries>");
        # report error and clean package in case URL is expired
        if ($err_msg eq 'Request has expired') {
            $logger->info("Failed to download installer because URL has expired");
        }
        return 0;
    }

    $logger->debug("Installer downloaded successfully");
    return 1; # Indicate success
}

sub _schedule_update {
    my ($self) = @_;
    my $logger = $self->{logger};

    $logger->debug("Entering _schedule_update");

    # Only supported on macOS
    if ($^O ne 'darwin') {
        $logger->error('Auto update is not available for Linux.');
        return 0;
    }

    my $src_plist = '/var/db/ocsinventory-agent/update/current/org.ocsng.update.stage1.plist';

    unless (-f $src_plist) {
        $logger->error("Launchd plist not found at $src_plist");
        return 0;
    }

    # Determine destination plist path in standard location (filenames match labels)
    my $dest_dir = '/Library/LaunchDaemons';
    my $dest_plist = "$dest_dir/" . basename($src_plist);

    # 1) Unload existing job if exists (best-effort)
    my $bootout_cmd = "/bin/launchctl bootout system $dest_plist 2>&1";
    my $bootout_out = qx{$bootout_cmd};
    my $bootout_status = $? >> 8;
    $logger->debug(sprintf('launchctl bootout status=%d output=%s', $bootout_status, defined $bootout_out ? $bootout_out : ''));

    # 2) Copy .plist to standard location with proper perms/ownership
    unless (copy($src_plist, $dest_plist)) {
        $logger->error("Failed to copy $src_plist to $dest_plist: $!");
        return 0;
    }
    chmod 0644, $dest_plist;
    my $uid = (getpwnam('root'))[2];
    my $gid = (getgrnam('wheel'))[2];
    if (defined $uid && defined $gid) {
        chown $uid, $gid, $dest_plist;
    } else {
        $logger->debug('Could not resolve root:wheel for chown; skipping ownership change');
    }

    # 3) Load it (bootstrap preferred, fallback to legacy load)
    my $success = 0;
    my $bootstrap_cmd = "/bin/launchctl bootstrap system $dest_plist 2>&1";
    my $bootstrap_out = qx{$bootstrap_cmd};
    my $bootstrap_status = $? >> 8;
    if ($bootstrap_status == 0) {
        $logger->info("Scheduled update via launchctl bootstrap: $dest_plist");
        $success = 1;
    } else {
        $logger->debug(sprintf('launchctl bootstrap failed status=%d output=%s', $bootstrap_status, defined $bootstrap_out ? $bootstrap_out : ''));
        my $load_cmd = "/bin/launchctl load -w $dest_plist 2>&1";
        my $load_out = qx{$load_cmd};
        my $load_status = $? >> 8;
        if ($load_status == 0) {
            $logger->info("Scheduled update via legacy launchctl load -w: $dest_plist");
            $success = 1;
        } else {
            $logger->error(sprintf('Failed to schedule update. load status=%d output=%s', $load_status, defined $load_out ? $load_out : ''));
        }
    }

    return $success ? 1 : 0;
}

# Private finish subroutine for update module - mirrors the download finish
sub finish {
    my ($logger, $context) = @_;
    # Open or create the lock file in update directory
    open my $LOCK, '>', $context->{installpath} . '/update/lock' or warn "Cannot open lock file\n";
    $logger->debug("End of work...\n");
    exit(0);
}

1;


