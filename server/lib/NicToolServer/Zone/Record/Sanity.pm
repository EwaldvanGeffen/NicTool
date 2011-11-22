package NicToolServer::Zone::Record::Sanity;
# ABSTRACT: sanity tests for zone records

use strict;

@NicToolServer::Zone::Record::Sanity::ISA = qw(NicToolServer::Zone::Record);

sub new_zone_record {
    my ( $self, $data ) = @_;
    my $error = $self->new_or_edit_basic_verify($data);
    return $error if $error;

    # do any new_zone_record specific checks here

    return $self->throw_sanity_error if $self->{errors};
    return $self->SUPER::new_zone_record($data);
}

sub edit_zone_record {
    my ( $self, $data ) = @_;
    my $zr = $self->get_zone_record($data);
    return $zr if $zr->{error_code} ne 200;
    $data->{nt_zone_id} = $zr->{nt_zone_id};
    foreach (qw(type address)) {
        $data->{$_} = $zr->{$_} unless exists $data->{$_};
    }
    my $error = $self->new_or_edit_basic_verify($data);
    return $error if $error;

    # do any edit_zone_record specific checks here
    $self->push_sanity_error( 'nt_zone_record_id',
        "Cannot edit deleted record!" )
        if $self->check_object_deleted( 'zonerecord',
                $data->{nt_zone_record_id} )
            and $data->{deleted} ne '0';
    return $self->throw_sanity_error if $self->{errors};

    return $self->SUPER::edit_zone_record($data);
}

sub new_or_edit_basic_verify {
    my ( $self, $data ) = @_;

    my $z = $self->find_zone( $data->{nt_zone_id} ) or do {
        $self->{errors}{nt_zone_id} = 1;
        push( @{ $self->{error_messages} }, 'invalid zone_id' );
    };
    if ( $self->check_object_deleted( 'zone', $data->{nt_zone_id} ) ) {
        $self->push_sanity_error( 'nt_zone_id',
            "Cannot create/edit records in a deleted zone." );
    }

    my $zone_text = $z->{zone};

    if ( $data->{name} eq "*" ) {    # fully qualify the * record
        $data->{name} = '*' . ".$zone_text.";
    }

    $self->_expand_shortcuts( $data, $zone_text );  # expand @ and & shortcuts
    $self->_valid_name_chars( $data );
    $self->_valid_name( $data, $zone_text );
    $self->_valid_address_chars( $data, $zone_text );
    $self->_valid_rr_type($data);

    if ( $data->{name} =~ /([a-zA-Z0-9\-\.]+)\.$zone_text\.$/ ) {

        # strip domain from end. records should NOT be stored as absolute
        $data->{name} = $1;
    }

    $self->_valid_cname($data, $zone_text);
    $self->_valid_a($data);
    $self->_valid_aaaa($data);
    $self->_valid_srv($data);

# TODO make this check that record exists within nictool, or that it's absolute.
    if ( $data->{type} =~ /^MX|NS|CNAME|PTR|SRV$/ ) {

        my @parts = split( /\./, $data->{address} );
        foreach my $address (@parts) {
            if ( $address !~ /[a-zA-Z0-9\-\.\/]+/ ) {
                $self->error( 'address', 
                    "Address for $data->{type} records must be a valid host."
                );
            }
            if ( $address =~ /^[-\/]/ ) {    # can't start with a dash
                $self->error( 'address', 
                    "Address for $data->{type} cannot start with a dash or slash."
                );
            }
        }
        $data->{address} = $data->{address} . ".$zone_text."
            unless $data->{address} =~ /\.$/;
    }

    $self->_valid_fqdn( $data, $zone_text );
    $self->_valid_ns( $data, $zone_text );
    $self->_valid_mx( $data, $zone_text );

    # invalid ip is: if first octet if < 1 || > 255, for rest, if < 0 or > 255
    # we get rid of "07" or "001" garbage here too.
    if ( $data->{type} eq 'A' ) {
        $self->valid_ip_address( $data->{address} ) or 
            $self->error( 'address', 
                'Address for A records must be a valid IP address.'
            );
    }

    if ( $data->{type} eq 'AAAA' ) {
        $self->valid_ip_address( $data->{address} ) or
            $self->error( 'address', 
                'Address for AAAA records must be a valid IPv6 address.'
            );
    }

# check to make sure a sub-domain in zones doesn't clobber a record that user is trying to add/edit..
    if ( $data->{name} !~ /$zone_text\.$/ ) {

# if zone is zone.com., it's the origin, which should have already been checked
# for subdomain collisions. If it isn't, go check ...
# oh - and split input up in case it's like blah.blah.blah.zone.com and blah.blah.zone.com exists as a domain..
        my @nparts = split( /\./, $data->{name} );
        my @tocheck;
        my $basestr = $zone_text;
        while ( my $x = pop(@nparts) ) {
            $basestr = $x . "." . $basestr;
            push( @tocheck, $basestr );
        }
        @tocheck = reverse(@tocheck);
        while ( my $name = pop(@tocheck) ) {

            #warn "checking if exists $name";
            if ( $self->zone_exists( $name, 0 ) ) {
                $self->error( 'name', 
                    "Cannot create/edit Record '$data->{name}' in zone '$z->{zone}': it conflicts with existing zone '$name'."
                );
                last;
            }
        }
    }    # TODO - make the above not so nasty

    # check the record's TTL
    if ( !$data->{ttl}                  # no default TTL
       && !$data->{nt_zone_record_id} ) # it's a new entry
    {    
        $data->{ttl} = 86400;           # set default.
    };
    $self->valid_ttl( $data->{ttl} ) if defined $data->{ttl};

    return $self->throw_sanity_error if $self->{errors};
}

sub record_exists {
    my ( $self, $record, $record_type, $zone_id, $rid ) = @_;

    my $sql = "SELECT * FROM nt_zone_record WHERE deleted=0 AND type=?
         AND nt_zone_id = ? AND name = ?";
    if ($rid) {
        $sql .= " AND nt_zone_record_id <> $rid";
    }
    my $zrs = $self->exec_query( $sql, [ $record_type, $zone_id, $record ] );

    return ref( $zrs->[0] ) ? 1 : 0;
}

sub rr_types {
    {   'NS'    => 'Name Server (NS)',
        'MX'    => 'Mail Exchanger (MX)',
        'A'     => 'Address (A)',
        'AAAA'  => 'Address IPv6 (AAAA)',
        'CNAME' => 'Canonical Name (CNAME)',
        'PTR'   => 'Pointer (PTR)',
        'TXT'   => 'Text (TXT)',
        'SRV'   => 'Service (SRV)',
        'SPF'   => 'Sender Policy Framework (SPF)',
    };
}

sub _expand_shortcuts {
    my ( $self, $data, $zone_text ) = @_;

    # expand any @ symbol shortcuts
    if ( $data->{name} =~ /\.\@$/ )
    {    # replace something.@ with something.zone name
        $data->{name} =~ s/\.\@$//;
        $data->{name} = $data->{name} . ".$zone_text.";
    }

    if ( $data->{name} =~ /^\@$/ ) {    # replace @ with zone name
        $data->{name} = "$zone_text.";
    }

    if ( $data->{address} =~ /\.\@$/ )
    {    # replace something.@ with something.zone name
        $data->{address} =~ s/\.\@$//;
        $data->{address} = $data->{address} . ".$zone_text.";
    }

    if ( $data->{address} =~ /^\@$/ ) {    # replace @ with zone name
        $data->{address} = "$zone_text.";
    }

    # expand the & shortcut
    if ( $data->{address} =~ /\.\&$/ )
    {    # replace something.& with something.in-addr.arpa.
        $data->{address} =~ s/\.\&$//;
        $data->{address} = $data->{address} . ".in-addr.arpa.";
    }

    # no return, changes are made to the original hash via its reference
}

sub _valid_name_chars {

    my ( $self, $data, $zone_text ) = @_;

    return if ! defined $data->{name};  # an edit may not have this defined

    # normal domain characters: RFC 1035 (a-z, 0-9, and hyphen)
    return if $data->{name} =~ /^([a-zA-Z0-9\-\.]+)$/;  # no ickies

    $data->{name} =~ /([^a-zA-Z0-9\-\.])/;  # match ickies

    if ( $data->{name} =~ /^(\*$|\*\.)/ ) {

        # wildcard * or *.something is OK
    }
    elsif ( $1 eq '_' && ( $data->{type} =~ /^TXT|SRV$/ ) ) {

        # allow _ character in name field of TXT and SRV records
    }
    else {
        if ( $data->{name} =~ /\*/ ) {
            $self->error('name',
                "only *.something or * (by itself) is a valid wildcard record"
            );
        }
        else {
            $self->error('name', "invalid character or string in record name -- $1");
        }
    }
}

sub _valid_name {

    my ( $self, $data, $zone_text ) = @_;

    return if ! defined $data->{name};  # edit may not include 'name'

    if ( $data->{name} =~ /\.$/ ) {               # ends with .
        if ( $data->{name} !~ /$zone_text\.$/ ) { # ends with zone.com.
            $self->error('name', "absolute host names are NOT allowed. Remove the dot and the host will automatically live within the current zone.");
        }
    }

    $self->valid_label('name', $data->{name} );
}

sub _valid_address_chars {

    my ( $self, $data, $zone_text ) = @_;

    if ( $data->{type} =~ /^TXT|SPF$/ ) {
        # any character is valid in TXT records - see RFC 1464
        # SPF format is same as TXT record - RFC 4408
        return;
    }

    my $valid_chars = "[^a-zA-Z0-9\-\.]";

    # https://www.tnpi.net/support/forums/index.php/topic,990.0.html
    if ( $data->{type} eq "AAAA" ) {
        $valid_chars = "[^a-zA-Z0-9\-\.:]";  # allow : char for AAAA (IPv6)
    };

    if ( $data->{address} =~ /\// 
        && $data->{address} !~ /in-addr\.arpa\.$/i ) {
        $self->error( 'address', "invalid character in record address"
            ." '/'.  Not allowed in non-reverse-lookup addresses" );
    }
    elsif ( $data->{address} =~ /($valid_chars)/ ) {
        $self->error('address',
            "invalid character in record address -- $1"
        );
    };
}

sub _valid_rr_type {

    my ( $self, $data ) = @_;

    return if ! $data->{type};

    # the form is upper case. The following checks catch
    # the correct type, even if user f's with form input
    $data->{type} =~ tr/a-z/A-Z/; 

    my $valid_type = 0;
    foreach my $rrt ( keys %{ $self->rr_types } ) {
        if ( $data->{type} eq $rrt ) {
            $valid_type = 1;
        }
    }
    unless ($valid_type) {
        $self->error('type', "Invalid record type $data->{type}" );
    }
}

sub _valid_cname {
    my ( $self, $data, $zone_name ) = @_;

    return if $data->{type} ne 'CNAME';

    my @args = ( $data->{name}, 'CNAME', 
        $data->{nt_zone_id}, $data->{nt_zone_record_id} );

    if ($self->record_exists( @args ) ) {
        $self->error( 'name', "multiple cname records with the same name are NOT allowed. (use plain old round robin)" );
        return;
    };

    @args[1] = 'A';
    if ( $self->record_exists( @args ) ) {
        $self->error( 'name', "record $data->{name} already exists within zone as an Address (A) record: RFC 1034 & 2181");
        return;
    };

    @args[1] = 'MX';
    if ( $self->record_exists( @args ) ) {
        $self->error( 'name', "record $data->{name} already exists as a Mail Exchanger (MX) record: RFC 1034 & 2181");
        return;
    };
}

sub _valid_a {
    my ( $self, $data ) = @_;

    return if $data->{type} ne 'A';

    if ( $self->record_exists( 
        $data->{name}, 'CNAME', $data->{nt_zone_id}, $data->{nt_zone_record_id} ) ) {
            $self->error( 'name', "record $data->{name} already exists within zone as an Alias (CNAME) record." );
    };
}

sub _valid_aaaa {
    my ( $self, $data ) = @_;

    return if $data->{type} ne 'AAAA';

    $self->error( 'name',
        "record $data->{name} already exists within zone as an Alias (CNAME) record."
        ) if ( $self->record_exists(
                $data->{name}, 'CNAME',
                $data->{nt_zone_id}, $data->{nt_zone_record_id}
                )
            );
}

sub _valid_mx {
    my ( $self, $data, $zone_text ) = @_;

    return if $data->{type} ne 'MX';

    # weight must be 16 bit integer
    $self->valid_16bit_int( 'weight', $data->{weight} );

    # MX records do not point to a CNAME
    if ($self->record_exists( $data->{address}, 'CNAME', 
            $data->{nt_zone_id}, $data->{nt_zone_record_id} ) ) {
        $self->error( 'address', "MX records must not point to a CNAME: RFC 2181" );
        return;
    };

    # MX records cannot share a name with a CNAME
    if ($self->record_exists( $data->{name}, 'CNAME', 
            $data->{nt_zone_id}, $data->{nt_zone_record_id} ) ) {
        $self->error( 'name', "MX records must not exist as a CNAME: RFCs 1034, 2181" );
        return;
    };
}

sub _valid_ns {
    my ( $self, $data, $zone_text ) = @_;

    return if $data->{type} ne 'NS';

    #catch redundant NS records
##!CHANGELOG:Creating or editing NS Records with 'name' set to the 'zone' of
    # the enclosing zone will be disallowed (these records will be created
    # automatically at export time). -gws
    if ( $data->{name} eq "$zone_text." ) {
        $self->error( 'name',
            "The NS Records for '$zone_text.' will automatically be created when the Zone is published to a Nameserver."
        );
    }

    # NS records do not point to a CNAME
    if ($self->record_exists( $data->{address}, 'CNAME', 
            $data->{nt_zone_id}, $data->{nt_zone_record_id} ) ) {
        $self->error( 'address', "NS records must not point to a CNAME: RFC 2181" );
        return;
    };
}

sub _valid_fqdn {
    my ( $self, $data, $zone_text ) = @_;

    return if ( $data->{type} ne 'MX' && $data->{type} ne 'NS' );

    my $entered_address = $data->{address};
    if ( $entered_address =~ /^(.*)\.$zone_text\.$/ ) {
        $entered_address = $1;
    }

# per RFC 1035 MX and NS records must point to absolute hostnames, not ip addresses (thanks Matt!)
    my $nondigits
        = scalar map {/\D/} split( /\./, $entered_address );    # is it an IP?
    if ( !$nondigits ) {
        $self->error('address',
            "Address for $data->{type} cannot be an IP address (RFC 1035)." );
    }

    if ( $data->{address} !~ /\.$/ ) {    # if it does not end in .
        $self->error('address',
            "Address for $data->{type} must point to a Fully Qualified Domain Name (with a '.' at the end) (RFC 1035).  You can use the '\@' character to stand for the zone this record belongs to." );
    }
}

sub _valid_srv {
    my ( $self, $data ) = @_;

    return if $data->{type} ne 'SRV';

    # weight, priority, and port must all be 16 bit integers
    my %values_to_check = (
        'weight'   => 'Weight',
        'priority' => 'Priority',
        'other'    => 'Port',
    );

    foreach my $check ( keys %values_to_check ) {
        if ( !$self->valid_16bit_int( $check, $data->{$check} ) ) {
            $self->error( $check,
                "$values_to_check{$check} is required to be a 16bit integer, see RFC 2782"
            );
        }
    }
}

1;

__END__

=head1 SYNOPSIS

    
=cut

