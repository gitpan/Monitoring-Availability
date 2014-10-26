package Monitoring::Availability;

use 5.006;
use strict;
use warnings;
use Data::Dumper;
use Carp;

our $VERSION = '0.03_3';


=head1 NAME

Monitoring::Availability - Calculate Availability Data from
Nagios and Icinga Logfiles.

=head1 SYNOPSIS

    use Monitoring::Availability;
    my $ma = Monitoring::Availability->new();

=head1 DESCRIPTION

This module calculates the availability for hosts/server from given logfiles.
The Logfileformat is Nagios/Icinga only.

=head1 REPOSITORY

    Git: http://github.com/sni/Monitoring-Availability

=head1 CONSTRUCTOR

=head2 new ( [ARGS] )

Creates an C<Monitoring::Availability> object. C<new> takes at least the
logs parameter.  Arguments are in key-value pairs.

=over 4

=item rpttimeperiod

report timeperiod. defines a timeperiod for this report. Will use 24x7 if not
specified.

=item assumeinitialstates

Assume the initial host/service state if none is found.

=item assumestateretention

Assume state retention

=item assumestatesduringnotrunning

Assume state during times when the monitoring process is not running

=item includesoftstates

Include soft states in the calculation. Only hard states are used otherwise.

=item initialassumedhoststate

Assumed host state if none is found

=item initialassumedservicestate

Assumed service state if none is found

=item backtrack

Go back this amount of days to find initial states

=item verbose

verbose mode

=back

=cut

sub new {
    my $class = shift;
    unshift(@_, "peer") if scalar @_ == 1;
    my(%options) = @_;

    my $self = {
        'verbose'                       => 0,       # enable verbose output
        'logger'                        => undef,   # logger object used for verbose output
        'rpttimeperiod'                 => undef,
        'assumeinitialstates'           => undef,
        'assumestateretention'          => undef,
        'assumestatesduringnotrunning'  => undef,
        'includesoftstates'             => undef,
        'initialassumedhoststate'       => undef,
        'initialassumedservicestate'    => undef,
        'backtrack'                     => 4,
    };
    bless $self, $class;

    for my $opt_key (keys %options) {
        if(exists $self->{$opt_key}) {
            $self->{$opt_key} = $options{$opt_key};
        }
        else {
            croak("unknown option: $opt_key");
        }
    }

    # create empty log array
    $self->_reset_log_store();

    $self->_log('initialized '.$class);

    return $self;
}


########################################

=head1 METHODS

=head2 calculate

 calculate()

Calculate the availability

=over 4

=item start

Timestamp of start

=item end

Timestamp of end

=item log_string

String containing the logs

=item log_file

File containing the logs

=item log_dir

Directory containing *.log files

=item log_livestatus

Array with logs from a livestatus query

 a sample query could be:
 selectall_arrayref(GET logs...\nColumns: time type options, {Slice => 1})

=back

=cut

sub calculate {
    my $self      = shift;
    my(%opts)     = @_;
    my $options = {
        'start'                         => undef,
        'end'                           => undef,
        'hosts'                         => [],
        'services'                      => [],
        'log_string'                    => undef,   # logs from string
        'log_livestatus'                => undef,   # logs from a livestatus query
        'log_file'                      => undef,   # logs from a file
        'log_dir'                       => undef,   # logs from a dir
        'rpttimeperiod'                 => $self->{'rpttimeperiod'},
        'assumeinitialstates'           => $self->{'assumeinitialstates'},
        'assumestateretention'          => $self->{'assumestateretention'},
        'assumestatesduringnotrunning'  => $self->{'assumestatesduringnotrunning'},
        'includesoftstates'             => $self->{'includesoftstates'},
        'initialassumedhoststate'       => $self->{'initialassumedhoststate'},
        'initialassumedservicestate'    => $self->{'initialassumedservicestate'},
        'backtrack'                     => $self->{'backtrack'},
    };
    $self->_log('calculate()');
    my $result;

    for my $opt_key (keys %opts) {
        if(exists $options->{$opt_key}) {
            $options->{$opt_key} = $opts{$opt_key};
        }
        else {
            croak("unknown option: $opt_key");
        }
    }

    # create lookup hash for faster access
    $result->{'hosts'}    = {};
    $result->{'services'} = {};
    for my $host (@{$options->{'hosts'}}) {
        $result->{'hosts'}->{$host} = 1;
    }
    for my $service (@{$options->{'services'}}) {
        if(ref $service ne 'HASH') {
            croak("services have to be an array of hashes, for example: [{host => 'hostname', service => 'description'}, ...]\ngot: ".Dumper($service));
        }
        $result->{'services'}->{$service->{'host'}}->{$service->{'service'}} = 1;
    }
    $options->{'calc_all'} = 0;
    if(scalar keys %{$result->{'services'}} == 0 and scalar keys %{$result->{'hosts'}} == 0) {
        $self->_log('will calculate availability for all hosts/services found');
        $options->{'calc_all'} = 1;
    }

    #print "calculation availabity with:";
    #print Dumper($options);
    unless($options->{'calc_all'}) {
        $self->_set_empty_hosts($options, $result);
        $self->_set_empty_services($options, $result);
    }
    #print Dumper($result);

    # which source do we use?
    if(defined $options->{'log_string'}) {
        $self->_store_logs_from_string($options->{'log_string'});
    }
    if(defined $options->{'log_file'}) {
        $self->_store_logs_from_file($options->{'log_file'});
    }
    if(defined $options->{'log_dir'}) {
        $self->_store_logs_from_dir($options->{'log_dir'});
    }
    if(defined $options->{'log_livestatus'}) {
        $self->_store_logs_from_livestatus($options->{'log_livestatus'});
    }

    if(scalar @{$self->{'logs'}} >= 0) {
        $self->_compute_availability_from_log_store($result, $options);
    }

    return($result);
}

########################################
# INTERNAL SUBS
########################################
sub _reset_log_store {
    my $self   = shift;
    $self->_log('_reset_log_store()');
    undef $self->{'logs'};
    $self->{'logs'} = [];
    return 1;
}

########################################
sub _store_logs_from_string {
    my $self   = shift;
    my $string = shift;
    $self->_log('_store_logs_from_string()');
    return unless defined $string;
    for my $line (split/\n/mx, $string) {
        my $data = $self->_parse_line($line);
        push @{$self->{'logs'}}, $data if defined $data;
    }
    return 1;
}

########################################
sub _store_logs_from_file {
    my $self   = shift;
    my $file   = shift;
    $self->_log('_store_logs_from_file()');
    return unless defined $file;

    open(my $FH, '<', $file) or croak('cannot read file '.$file.': '.$!);
    while(my $line = <$FH>) {
        chomp($line);
        my $data = $self->_parse_line($line);
        push @{$self->{'logs'}}, $data if defined $data;
    }
    close($FH);
    return 1;
}

########################################
sub _store_logs_from_dir {
    my $self   = shift;
    my $dir   = shift;
    $self->_log('_store_logs_from_dir()');

    return unless defined $dir;

    opendir(my $dh, $dir) or croak('cannot open directory '.$dir.': '.$!);
    while(my $file = readdir($dh)) {
        if($file =~ m/\.log$/mx) {
            $self->_store_logs_from_file($dir.'/'.$file);
        }
    }
    closedir $dh;

    return 1;
}

########################################
sub _store_logs_from_livestatus {
    my $self      = shift;
    my $log_array = shift;
    $self->_log('_store_logs_from_livestatus()');
    return unless defined $log_array;
    for my $entry (@{$log_array}) {
        my $data = $self->_parse_livestatus_entry($entry);
        push @{$self->{'logs'}}, $data if defined $data;
    }
    return 1;
}

########################################
sub _parse_livestatus_entry {
    my $self   = shift;
    my $entry  = shift;

    my $string = $entry->{'options'} || '';
    if($string eq '') {
        # extract starts/stops
        $self->_set_from_type($entry, $string);
        return $entry;
    }

    # extract more information from our options
    $self->_set_from_options($entry, $string);

    return $entry;
}

########################################
sub _parse_line {
    my $self   = shift;
    my $string = shift;
    my $return = {
        'time' => '',
        'type' => '',
    };

    return if substr($string, 0, 1, '') ne '[';
    $return->{'time'} = substr($string, 0, 10, '');
    return if substr($string, 0, 2, '') ne '] ';

    $return->{'type'} = $self->_strtok($string, ': ');
    if(!defined $string) {
        # extract starts/stops
        $self->_set_from_type($return, $string);
        return $return;
    }

    # extract more information from our options
    $self->_set_from_options($return, $string);

    return $return;
}

########################################
# search for a token and return first occurance, trim that part from string
sub _strtok {
    my $index = index($_[1], $_[2]);
    if($index != -1) {
        my $value = substr($_[1], 0, $index, '');
        substr($_[1], 0, length($_[2]), '');
        return($value);
    }

    my $value = $_[1];
    undef $_[1];

    # seperator not found
    return($value);
}

########################################
sub _set_from_options {
    my $self   = shift;
    my $data   = shift;
    my $string = shift;

    # Host States
    if(   $data->{'type'} eq 'HOST ALERT'
       or $data->{'type'} eq 'CURRENT HOST STATE'
       or $data->{'type'} eq 'INITIAL HOST STATE'
    ) {
        $data->{'host_name'} = $self->_strtok($string, ';');
        $data->{'state'}     = $self->_statestr_to_state($self->_strtok($string, ';'));
        $data->{'hard'}      = $self->_softstr_to_hard($self->_strtok($string, ';'));
    }

    # Service States
    elsif(   $data->{'type'} eq 'SERVICE ALERT'
       or $data->{'type'} eq 'CURRENT SERVICE STATE'
       or $data->{'type'} eq 'INITIAL SERVICE STATE'
    ) {
        $data->{'host_name'}           = $self->_strtok($string, ';');
        $data->{'service_description'} = $self->_strtok($string, ';');
        $data->{'state'}               = $self->_statestr_to_state($self->_strtok($string, ';'));
        $data->{'hard'}                = $self->_softstr_to_hard($self->_strtok($string, ';'));
    }

    # Host Downtimes
    elsif($data->{'type'} eq 'HOST DOWNTIME ALERT') {
        $data->{'host_name'} = $self->_strtok($string, ';');
        $data->{'start'}     = $self->_startstr_to_start($self->_strtok($string, ';'));
    }

    # Service Downtimes
    elsif($data->{'type'} eq 'SERVICE DOWNTIME ALERT') {
        $data->{'host_name'}           = $self->_strtok($string, ';');
        $data->{'service_description'} = $self->_strtok($string, ';');
        $data->{'start'}               = $self->_startstr_to_start($self->_strtok($string, ';'));
    }

    return 1;
}

########################################
sub _set_from_type {
    my $self   = shift;
    my $data   = shift;
    my $string = shift;

    # program starts
    if($data->{'type'} =~ m/\ starting\.\.\./mx) {
        $data->{'proc_start'} = 1;
    }
    elsif($data->{'type'} =~ m/\ restarting\.\.\./mx) {
        $data->{'proc_start'} = 1;
    }

    # program stops
    elsif($data->{'type'} =~ m/shutting\ down\.\.\./mx) {
        $data->{'proc_start'} = 0;
    }
    elsif($data->{'type'} =~ m/Bailing\ out/mx) {
        $data->{'proc_start'} = 0;
    }

    return 1;
}

########################################
sub _startstr_to_start {
    my $self   = shift;
    my $string = shift;

    return 1 if $string eq 'STARTED';
    return 0;
}

########################################
sub _softstr_to_hard {
    my $self   = shift;
    my $string = shift;

    return 1 if $string eq 'HARD';
    return 0;
}

########################################
sub _statestr_to_state {
    my $self   = shift;
    my $string = shift;

    return 0 if $string eq 'UP';
    return 0 if $string eq 'OK';
    return 1 if $string eq 'WARNING';
    return 1 if $string eq 'DOWN';
    return 2 if $string eq 'CRITICAL';
    return 2 if $string eq 'UNREACHABLE';
    return 3 if $string eq 'UNKNOWN';
    return 0 if $string eq 'RECOVERY';
    confess("unknown state: $string");
}

########################################
sub _set_empty_hosts {
    my $self    = shift;
    my $options = shift;
    my $data    = shift;

    my $initial_assumend_state = -1;
    if($options->{'assumeinitialstates'}) {
        $initial_assumend_state = $options->{'initialassumedhoststate'};
    }

    $self->_log('_set_empty_hosts()');
    for my $hostname (keys %{$data->{'hosts'}}) {
        $data->{'hosts'}->{$hostname} = {
            'time_up'           => 0,
            'time_down'         => 0,
            'time_unreachable'  => 0,

            'scheduled_time_up'             => 0,
            'scheduled_time_down'           => 0,
            'scheduled_time_unreachable'    => 0,
            'scheduled_time_indeterminate'  => 0,

            'time_indeterminate_nodata'     => 0,
            'time_indeterminate_notrunning' => 0,
        };
        $self->{'host_data'}->{$hostname} = {
            'in_downtime'      => 0,
            'last_state'       => $initial_assumend_state,
            'last_known_state' => undef,
            'last_state_time'  => 0,
        };
    }
    return 1;
}

########################################
sub _set_empty_services {
    my $self    = shift;
    my $options = shift;
    my $data    = shift;
    $self->_log('_set_empty_services()');

    my $initial_assumend_state      = -1;
    my $initial_assumend_host_state = -1;
    if($options->{'assumeinitialstates'}) {
        $initial_assumend_state      = $options->{'initialassumedservicestate'};
        $initial_assumend_host_state = $options->{'initialassumedhoststate'};
    }

    for my $hostname (keys %{$data->{'services'}}) {
        for my $service_description (keys %{$data->{'services'}->{$hostname}}) {
            $data->{'services'}->{$hostname}->{$service_description} = {
                'time_ok'           => 0,
                'time_warning'      => 0,
                'time_unknown'      => 0,
                'time_critical'     => 0,

                'scheduled_time_ok'             => 0,
                'scheduled_time_warning'        => 0,
                'scheduled_time_unknown'        => 0,
                'scheduled_time_critical'       => 0,
                'scheduled_time_indeterminate'  => 0,

                'time_indeterminate_nodata'     => 0,
                'time_indeterminate_notrunning' => 0,
            };

            # create last service data
            $self->{'service_data'}->{$hostname}->{$service_description} = {
                'in_downtime'      => 0,
                'last_state'       => $initial_assumend_state,
                'last_known_state' => undef,
                'last_state_time'  => 0,
            };
        }
        $self->{'host_data'}->{$hostname} = {
            'in_downtime'      => 0,
            'last_state'       => $initial_assumend_host_state,
            'last_known_state' => undef,
            'last_state_time'  => 0,
        };
    }
    return 1;
}

########################################
sub _compute_availability_from_log_store {
    my $self    = shift;
    my $result  = shift;
    my $options = shift;
    $self->_log('_compute_availability_from_log_store()');

    # make sure our logs are sorted by time
    @{$self->{'logs'}} = sort { $a->{'time'} <=> $b->{'time'} } @{$self->{'logs'}};

    $self->_log('_compute_availability_from_log_store() sorted logs');

    # process all log lines we got
    my $last_time = -1;
    for my $data (@{$self->{'logs'}}) {
        # if we reach the start date of our report, insert a fake entry
        if($last_time < $options->{'start'} and $data->{'time'} > $options->{'start'}) {
            $self->_log('_compute_availability_from_log_store() report start reached, insert fake data');
            for my $host (keys %{$result->{'services'}}) {
                for my $service (keys %{$result->{'services'}->{$host}}) {
                    my $fakedata = {
                        'service_description' => $service,
                        'time'                => $options->{'start'},
                        'host_name'           => $host,
                        'type'                => 'INITIAL SERVICE STATE',
                        'hard'                => 1,
                        'state'               => $self->{'service_data'}->{$host}->{$service}->{'last_state'} || -1,
                    };
                    $self->_process_log_line($result, $options, $fakedata);
                }
            }

            for my $host (keys %{$result->{'hosts'}}) {
                my $fakedata = {
                    'time'                => $options->{'start'},
                    'host_name'           => $host,
                    'type'                => 'INITIAL HOST STATE',
                    'hard'                => 1,
                    'state'               => $self->{'host_data'}->{$host}->{'last_state'} || -1,
                };
                $self->_process_log_line($result, $options, $fakedata);
            }
        }
        $last_time = $data->{'time'};

        # now process the real line
        $self->_process_log_line($result, $options, $data);
    }

    # process a fake last entry with our last known state
    $self->_log('_compute_availability_from_log_store() report end reached, insert fake data');
    for my $host (keys %{$result->{'services'}}) {
        for my $service (keys %{$result->{'services'}->{$host}}) {
            my $fakedata = {
                'service_description' => $service,
                'time'                => $options->{'end'},
                'host_name'           => $host,
                'type'                => 'INITIAL SERVICE STATE',
                'hard'                => 1,
                'state'               => $self->{'service_data'}->{$host}->{$service}->{'last_state'},
            };
            $self->_process_log_line($result, $options, $fakedata);
        }
    }

    for my $host (keys %{$result->{'hosts'}}) {
        my $fakedata = {
            'time'                => $options->{'end'},
            'host_name'           => $host,
            'type'                => 'INITIAL HOST STATE',
            'hard'                => 1,
            'state'               => $self->{'host_data'}->{$host}->{'last_state'},
        };
        $self->_process_log_line($result, $options, $fakedata);
    }

    return 1;
}

########################################
sub _process_log_line {
    my $self    = shift;
    my $result  = shift;
    my $options = shift;
    my $data    = shift;

    $self->_log('#######################################');
    $self->_log('_process_log_line() at '.(scalar localtime $data->{'time'}));
    $self->_log($data);


    # process starts / stops?
    if(defined $data->{'proc_start'}) {
        unless($options->{'assumestatesduringnotrunning'}){
            if($data->{'proc_start'}) {
                # set an event for all services and set state to no_data
                $self->_log('_process_log_line() process start, inserting fake event for all services');
                for my $host_name (keys %{$self->{'service_data'}}) {
                    for my $service_description (keys %{$self->{'service_data'}->{$host_name}}) {
                        my $last_known_state = $self->{'service_data'}->{$host_name}->{$service_description}->{'last_known_state'};
                        my $last_state = -1;
                        $last_state = $last_known_state if defined $last_known_state and $last_known_state >= 0;
                        $self->_set_service_event($host_name, $service_description, $result, $options, { 'start' => $data->{'start'}, 'end' => $data->{'end'}, 'time' => $data->{'time'}, 'state' => $last_state });
                    }
                }
            } else {
                # set an event for all services and set state to not running
                $self->_log('_process_log_line() process stop, inserting fake event for all services');
                for my $host_name (keys %{$self->{'service_data'}}) {
                    for my $service_description (keys %{$self->{'service_data'}->{$host_name}}) {
                        $self->_set_service_event($host_name, $service_description, $result, $options, { 'start' => $data->{'start'}, 'end' => $data->{'end'}, 'time' => $data->{'time'}, 'state' => -2 });
                    }
                }
            }
        }
    }

    # service events
    if(defined $data->{'service_description'}) {
        my $service_hist = $self->{'service_data'}->{$data->{'host_name'}}->{$data->{'service_description'}};

        if($data->{'type'} eq 'CURRENT SERVICE STATE' or $data->{'type'} eq 'SERVICE ALERT' or $data->{'type'} eq 'INITIAL SERVICE STATE') {
            $self->_set_service_event($data->{'host_name'}, $data->{'service_description'}, $result, $options, $data);
        }
        elsif($data->{'type'} eq 'SERVICE DOWNTIME ALERT') {
            undef $data->{'state'}; # we dont know the current state, so make sure it isnt set
            $self->_set_service_event($data->{'host_name'}, $data->{'service_description'}, $result, $options, $data);
            if($data->{'start'}) {
                $service_hist->{'in_downtime'} = 1;
            }
            else {
                $service_hist->{'in_downtime'} = 0;
            }
        }
    }

    # host events
    if(defined $data->{'host_name'}) {
        my $host_hist = $self->{'host_data'}->{$data->{'host_name'}};

        if($data->{'type'} eq 'CURRENT HOST STATE' or $data->{'type'} eq 'HOST ALERT' or $data->{'type'} eq 'INITIAL HOST STATE') {
            $self->_set_host_event($data->{'host_name'}, $result, $options, $data);
        }
        elsif($data->{'type'} eq 'HOST DOWNTIME ALERT') {

            $self->_log('_process_log_line() hostdowntime, inserting fake event for all services');
            # set an event for all services
            for my $service_description (keys %{$self->{'service_data'}->{$data->{'host_name'}}}) {
                $self->_set_service_event($data->{'host_name'}, $service_description, $result, $options, { 'start' => $data->{'start'}, 'end' => $data->{'end'}, 'time' => $data->{'time'} });
            }

            if($data->{'start'}) {
                $host_hist->{'in_downtime'} = 1;
            }
            else {
                $host_hist->{'in_downtime'} = 0;
            }
        }
    }

    return 1;
}


########################################
sub _set_service_event {
    my $self                = shift;
    my $host_name           = shift;
    my $service_description = shift;
    my $result              = shift;
    my $options             = shift;
    my $data                = shift;

    $self->_log('_set_service_event()');

    my $host_hist    = $self->{'host_data'}->{$host_name};
    my $service_hist = $self->{'service_data'}->{$host_name}->{$service_description};
    my $service_data = $result->{'services'}->{$host_name}->{$service_description};

    # check if we are inside the report time
    if($options->{'start'} < $data->{'time'} and $options->{'end'} >= $data->{'time'}) {
        # we got a last state?
        if(defined $service_hist->{'last_state'}) {
            my $diff = $data->{'time'} - $service_hist->{'last_state_time'};

            # ok
            if($service_hist->{'last_state'} == 0) {
                $self->_log('_set_service_event() ok + '.$diff.' seconds ('.$self->_duration($diff).')');
                $service_data->{'time_ok'} += $diff;
                if($service_hist->{'in_downtime'} or $host_hist->{'in_downtime'}) {
                    $self->_log('_set_service_event() ok sched + '.$diff.' seconds');
                    $service_data->{'scheduled_time_ok'} += $diff
                }
            }

            # warning
            elsif($service_hist->{'last_state'} == 1) {
                $self->_log('_set_service_event() warning + '.$diff.' seconds');
                $service_data->{'time_warning'} += $diff;
                if($service_hist->{'in_downtime'} or $host_hist->{'in_downtime'}) {
                    $self->_log('_set_service_event() warning sched + '.$diff.' seconds');
                    $service_data->{'scheduled_time_warning'} += $diff
                }
            }

            # critical
            elsif($service_hist->{'last_state'} == 2) {
                $self->_log('_set_service_event() critical + '.$diff.' seconds ('.$self->_duration($diff).')');
                $service_data->{'time_critical'} += $diff;
                if($service_hist->{'in_downtime'} or $host_hist->{'in_downtime'}) {
                    $self->_log('_set_service_event() critical sched + '.$diff.' seconds');
                    $service_data->{'scheduled_time_critical'} += $diff
                }
            }

            # unknown
            elsif($service_hist->{'last_state'} == 3) {
                $self->_log('_set_service_event() unknown + '.$diff.' seconds ('.$self->_duration($diff).')');
                $service_data->{'time_unknown'} += $diff;
                if($service_hist->{'in_downtime'} or $host_hist->{'in_downtime'}) {
                    $self->_log('_set_service_event() unknown sched + '.$diff.' seconds');
                    $service_data->{'scheduled_time_unknown'} += $diff
                }
            }

            # no data yet
            elsif($service_hist->{'last_state'} == -1) {
                $self->_log('_set_service_event() indeterminate + '.$diff.' seconds ('.$self->_duration($diff).')');
                $service_data->{'time_indeterminate_nodata'} += $diff;
                if($service_hist->{'in_downtime'} or $host_hist->{'in_downtime'}) {
                    $self->_log('_set_service_event() indeterminate sched + '.$diff.' seconds');
                    $service_data->{'scheduled_time_indeterminate'} += $diff
                }
            }

            # not running
            elsif($service_hist->{'last_state'} == -2) {
                $self->_log('_set_service_event() not_running + '.$diff.' seconds ('.$self->_duration($diff).')');
                $service_data->{'time_indeterminate_notrunning'} += $diff;
            }
        }
    }

    # set last state
    if(defined $data->{'state'}) {
        $self->_log('_set_service_event() set last state = '.$data->{'state'});
        $service_hist->{'last_state'}  = $data->{'state'};

        $service_hist->{'last_known_state'} = $data->{'state'} if $data->{'state'} >= 0;
    }
    $service_hist->{'last_state_time'} = $data->{'time'};

    return 1;
}


########################################
sub _set_host_event {
    my $self                = shift;
    my $host_name           = shift;
    my $result              = shift;
    my $options             = shift;
    my $data                = shift;

    $self->_log('_set_host_event()');

    my $host_hist = $self->{'host_data'}->{$host_name};
    my $host_data = $result->{'hosts'}->{$host_name};

    # check if we are inside the report time
    if($options->{'start'} < $data->{'time'} and $options->{'end'} >= $data->{'time'}) {
        # we got a last state?
        if(defined $host_hist->{'last_state'}) {
            my $diff = $data->{'time'} - $host_hist->{'last_state_time'};

            # up
            if($host_hist->{'last_state'} == 0) {
                $self->_log('_set_host_event() up + '.$diff.' seconds ('.$self->_duration($diff).')');
                $host_data->{'time_up'} += $diff;
                if($host_hist->{'in_downtime'}) {
                    $self->_log('_set_host_event() up sched + '.$diff.' seconds');
                    $host_data->{'scheduled_time_up'} += $diff
                }
            }

            # down
            elsif($host_hist->{'last_state'} == 1) {
                $self->_log('_set_host_event() down + '.$diff.' seconds');
                $host_data->{'time_down'} += $diff;
                if($host_hist->{'in_downtime'}) {
                    $self->_log('_set_host_event() down sched + '.$diff.' seconds');
                    $host_data->{'scheduled_time_down'} += $diff
                }
            }

            # unreachable
            elsif($host_hist->{'last_state'} == 2) {
                $self->_log('_set_host_event() unreachable + '.$diff.' seconds ('.$self->_duration($diff).')');
                $host_data->{'time_unreachable'} += $diff;
                if($host_hist->{'in_downtime'}) {
                    $self->_log('_set_host_event() unreachable sched + '.$diff.' seconds');
                    $host_data->{'scheduled_time_unreachable'} += $diff
                }
            }

            # no data yet
            elsif($host_hist->{'last_state'} == -1) {
                $self->_log('_set_host_event() indeterminate + '.$diff.' seconds ('.$self->_duration($diff).')');
                $host_data->{'time_indeterminate_nodata'} += $diff;
                if($host_hist->{'in_downtime'}) {
                    $self->_log('_set_host_event() indeterminate sched + '.$diff.' seconds');
                    $host_data->{'scheduled_time_indeterminate'} += $diff
                }
            }

            # not running
            elsif($host_hist->{'last_state'} == -2) {
                $self->_log('_set_host_event() not_running + '.$diff.' seconds ('.$self->_duration($diff).')');
                $host_data->{'time_indeterminate_notrunning'} += $diff;
            }
        }
    }

    # set last state
    if(defined $data->{'state'}) {
        $self->_log('_set_host_event() set last state = '.$data->{'state'});
        $host_hist->{'last_state'} = $data->{'state'};

        $host_hist->{'last_known_state'} = $data->{'state'} if $data->{'state'} >= 0;
    }
    $host_hist->{'last_state_time'} = $data->{'time'};

    return 1;
}


########################################
sub _log {
    my $self = shift;
    my $text = shift;

    if($self->{'verbose'} and defined $self->{'logger'}) {
        if(ref $text ne '') {
            $text = Dumper($text);
        }
        $self->{'logger'}->debug($text);
    }

    return 1;
}

##############################################
# calculate a duration in the
# format: 0d 0h 29m 43s
sub _duration {
    my $self     = shift;
    my $duration = shift;

    croak("undef duration in duration(): ".$duration) unless defined $duration;
    $duration = $duration * -1 if $duration < 0;

    if($duration < 0) { $duration = time() + $duration; }

    my $days    = 0;
    my $hours   = 0;
    my $minutes = 0;
    my $seconds = 0;
    if($duration >= 86400) {
        $days     = int($duration/86400);
        $duration = $duration%86400;
    }
    if($duration >= 3600) {
        $hours    = int($duration/3600);
        $duration = $duration%3600;
    }
    if($duration >= 60) {
        $minutes  = int($duration/60);
        $duration = $duration%60;
    }
    $seconds = $duration;

    return($days."d ".$hours."h ".$minutes."m ".$seconds."s");
}

########################################


1;

=head1 BUGS

Please report any bugs or feature requests to L<http://github.com/sni/Monitoring-Availability/issues>.

=head1 SEE ALSO

You can also look for information at:

=over 4

=item * Search CPAN

L<http://search.cpan.org/dist/Monitoring-Availability/>

=item * Github

L<http://github.com/sni/Monitoring-Availability>

=back

=head1 AUTHOR

Sven Nierlein, E<lt>nierlein@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Sven Nierlein

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__END__
