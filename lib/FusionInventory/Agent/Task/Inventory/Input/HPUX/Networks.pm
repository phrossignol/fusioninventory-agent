package FusionInventory::Agent::Task::Inventory::Input::HPUX::Networks;

use strict;
use warnings;

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Unix;
use FusionInventory::Agent::Tools::Network;

#TODO Get pcislot virtualdev

sub isEnabled {
    return canRun('lanscan');
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    # set list of network interfaces
    my $routes = getRoutingTable(command => 'netstat -nr', logger => $logger);
    my @interfaces = _getInterfaces(logger => $logger);

    foreach my $interface (@interfaces) {
        $interface->{IPGATEWAY} = $params{routes}->{$interface->{IPSUBNET}}
            if $interface->{IPSUBNET};

        $inventory->addEntry(
            section => 'NETWORKS',
            entry   => $interface
        );
    }

    $inventory->setHardware({
        DEFAULTGATEWAY => $routes->{'0.0.0.0'}
    });
}

sub _getInterfaces {
    my (%params) = @_;

    my @prototypes = _parseLanscan(
        command => 'lanscan -iap',
        logger  => $params{logger}
    );

    my %ifStatNrv = _parseNetstatNrv();

    my @interfaces;
    foreach my $prototype (@prototypes) {

        my $lanadminInfo = _getLanadminInfo(
            command => "lanadmin -g $prototype->{lan_id}",
            logger  => $params{logger}
        );
        $prototype->{TYPE}  = $lanadminInfo->{'Type (value)'};
        $prototype->{SPEED} = $lanadminInfo->{Speed} > 1000000 ?
            $lanadminInfo->{Speed} / 1000000 : $lanadminInfo->{Speed};

        if ($ifStatNrv{$prototype->{DESCRIPTION}}) {
            # if this interface name has been found in netstat output, let's
            # use the list of interfaces found there, using the prototype
            # to provide additional informations
            foreach my $interface (@{$ifStatNrv{$prototype->{DESCRIPTION}}}) {
                foreach my $key (qw/MACADDR STATUS TYPE SPEED/) {
                    next unless $prototype->{$key};
                    $interface->{$key} = $prototype->{$key};
                }
                push @interfaces, $interface;
            }
        } else {
            # otherwise, we promote this prototype to an interface, using
            # ifconfig to provide additional informations
            my $ifconfigInfo = _getIfconfigInfo(
                command => "ifconfig $prototype->{DESCRIPTION}",
                logger  => $params{logger}
            );
            $prototype->{STATUS}    = $ifconfigInfo->{status};
            $prototype->{IPADDRESS} = $ifconfigInfo->{address};
            $prototype->{IPMASK}    = $ifconfigInfo->{netmask};
            delete $prototype->{lan_id};
            push @interfaces, $prototype;
        }
    }

    foreach my $interface (@interfaces) {
        if ($interface->{IPADDRESS} && $interface->{IPADDRESS} eq '0.0.0.0') {
            $interface->{IPADDRESS} = undef;
            $interface->{IPMASK}    = undef;
        } else {
            $interface->{IPSUBNET} = getSubnetAddress(
                $interface->{IPADDRESS},
                $interface->{IPMASK}
            );
        }
    }

    return @interfaces;
}

sub _parseLanscan {
    my (%params) = @_;

    my $handle = getFileHandle(%params);
    return unless $handle;

    my @interfaces;
    while (my $line = <$handle>) {
        next unless $line =~ /^
            0x($alt_mac_address_pattern)
            \s
            (\S+)
            \s
            \S+
            \s+
            (\S+)
            /x;

        my $interface = {
            MACADDR     => alt2canonical($1),
            STATUS      => 'Down',
            DESCRIPTION => $2,
            lan_id      => $3,
        };

        push @interfaces, $interface;
    }
    close $handle;

    return @interfaces;
}

sub _getLanadminInfo {
    my $handle = getFileHandle(@_);
    return unless $handle;

    my $info;
    while (my $line = <$handle>) {
        next unless $line =~ /^(\S.+\S) \s+ = \s (.+)$/x;
        $info->{$1} = $2;
    }
    close $handle;

    return $info;
}

sub _getIfconfigInfo {
    my $handle = getFileHandle(@_);
    return unless $handle;

    my $info;
    while (my $line = <$handle>) {
        if ($line =~ /<UP/) {
            $info->{status} = 'Up';
        }
        if ($line =~ /inet ($ip_address_pattern)/) {
            $info->{address} = $1;
        }
        if ($line =~ /netmask ($hex_ip_address_pattern)/) {
            $info->{netmask} = hex2canonical($1);
        }
    }
    close $handle;

    return $info;
}

# will be need to get the bonding configuration
sub _getNwmgrInfo {
    my $handle = getFileHandle(@_);
    return unless $handle;

    my $info;
    while (my $line = <$handle>) {
        if ($line =~ /^(\w+)\s+(\w+)\s+0x(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})\s+(\w+)\s+(\w*)/) {
            my $netif = $1;

            $info->{$netif} = {
                status => $2,
                mac => join(':', ($3, $4, $5, $6, $7, $8)),
                driver => $9,
                media => $10,
                related_if => $11

            }

        }
    }
    close $handle;

    return $info;
}

sub _parseNetstatNrv {
    my (%params) = (
        command => 'netstat -nrv',
        @_
    );

    my $handle = getFileHandle(%params);
    return unless $handle;

    my %interfaces;
    while (my $line = <$handle>) {
        next unless $line =~ /^
            ($ip_address_pattern) # address
            \/
            ($ip_address_pattern) # mask
            \s+
            ($ip_address_pattern) # gateway
            \s+
            [A-Z]* H [A-Z]*       # host flag
            \s+
            \d
            \s+
            ([\w:]+)              # interface name
            \s+
            (\d+)                 # MTU
            $/x;

        my $address   = $1;
        my $mask      = $2;
        my $gateway   = $3 if $3 ne $1;
        my $interface = $4;
        my $mtu       = $5;

        if ($interface =~ /^(\w+):/) {
            # interface alias, eg: lan0:1
            $interface = $1;
        }

        push @{$interfaces{$interface}}, {
            IPADDRESS   => $address,
            IPMASK      => $mask,
            IPGATEWAY   => $gateway,
            DESCRIPTION => $interface,
            MTU         => $mtu
        }
    }
    close $handle;

    return %interfaces;
}

1;
