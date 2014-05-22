#
#  Copyright 2009-2013 MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

package MongoDB::BulkWrite;

# ABSTRACT: MongoDB bulk write interface

use version;
our $VERSION = 'v0.703.5'; # TRIAL

use MongoDB::Error;
use MongoDB::OID;
use MongoDB::WriteResult;
use MongoDB::BulkWriteView;
use Try::Tiny;
use Safe::Isa;
use Syntax::Keyword::Junction qw/any/;

use Moose;
use namespace::clean -except => 'meta';

=attr collection (required)

The L<MongoDB::Collection> where the operations are to be performed.

=cut

has 'collection' => (
    is       => 'ro',
    isa      => 'MongoDB::Collection',
    required => 1,
);

=attr ordered (required)

A boolean for whether or not operations should be ordered (true) or
unordered (false).

=cut

has 'ordered' => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
);

has '_executed' => (
    is       => 'rw',
    isa      => 'Bool',
    init_arg => undef,
    default  => 0,
);

has '_queue' => (
    is       => 'rw',
    isa      => 'ArrayRef[ArrayRef]',
    init_arg => undef,
    default  => sub { [] },
    traits   => ['Array'],
    handles  => {
        _enqueue_write => 'push',
        _all_writes    => 'elements',
        _count_writes  => 'count',
        _clear_writes  => 'clear',
    }
);

has '_database' => (
    is         => 'ro',
    isa        => 'MongoDB::Database',
    lazy_build => 1,
);

sub _build__database {
    my ($self) = @_;
    return $self->collection->_database;
}

has '_client' => (
    is         => 'ro',
    isa        => 'MongoDB::MongoClient',
    lazy_build => 1,
);

sub _build__client {
    my ($self) = @_;
    return $self->_database->_client;
}

has '_use_write_cmd' => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
);

sub _build__use_write_cmd {
    my ($self) = @_;
    my $use_it = $self->_client->_use_write_cmd;
    return $use_it;
}

with 'MongoDB::Role::_WriteQueue';

sub find {
    my ( $self, $doc ) = @_;

    confess "find requires a criteria document. Use an empty hashref for no criteria."
      unless defined $doc;

    unless ( @_ == 2 && ref $doc eq any(qw/HASH ARRAY Tie::IxHash/) ) {
        confess "argument to find must be a single hashref, arrayref or Tie::IxHash";
    }

    if ( ref $doc eq 'ARRAY' ) {
        confess "array reference to find must have key/value pairs"
          if @$doc % 2;
        $doc = {@$doc};
    }

    return MongoDB::BulkWriteView->new(
        query       => $doc,
        write_queue => $self,
    );
}

sub insert {
    my ( $self, $doc ) = @_;

    unless ( @_ == 2 && ref $doc eq any(qw/HASH ARRAY Tie::IxHash/) ) {
        confess "argument to insert must be a single hashref, arrayref or Tie::IxHash";
    }

    if ( ref $doc eq 'ARRAY' ) {
        confess "array reference to insert must have key/value pairs"
          if @$doc % 2;
        $doc = {@$doc};
    }

    if ( ref $doc eq 'Tie::IxHash' ) {
        $doc->STORE( '_id', MongoDB::OID->new ) unless $doc->EXISTS('_id');
    }
    else {
        $doc->{_id} = MongoDB::OID->new unless exists $doc->{_id};
    }

    $self->_enqueue_write( [ insert => $doc ] );
    return $self;
}

=method execute

    $bulk->execute;

XXX discuss how order affects errors

=cut

my %OP_MAP = (
    insert => [ insert => 'documents' ],
    update => [ update => 'updates' ],
    delete => [ delete => 'deletes' ],
);

sub execute {
    my ( $self, $write_concern ) = @_;
    if ( $self->_executed ) {
        MongoDB::Error->throw("bulk op execute called more than once");
    }
    else {
        $self->_executed(1);
    }

    $write_concern ||= $self->_client->_write_concern;

    my $ordered       = $self->ordered;
    my $use_write_cmd = $self->_use_write_cmd;

    # If using legacy write ops, then there will never be a valid nModified
    # result so we set that to undef in the constructor; otherwise, we set it
    # to 0 so that results accumulate normally. If a mongos on a mixed cluster
    # later fails to set it, results merging will handle it that case.
    my $result = MongoDB::WriteResult->new( nModified => $use_write_cmd ? 0 : undef, );

    unless ( $self->_count_writes ) {
        MongoDB::Error->throw("no bulk ops to execute");
    }

    for my $batch ( $ordered ? $self->_batch_ordered : $self->_batch_unordered ) {
        if ($use_write_cmd) {
            $self->_execute_write_command_batch( $batch, $result, $ordered, $write_concern );
        }
        else {
            $self->_execute_legacy_batch( $batch, $result, $ordered, $write_concern );
        }
    }

    # only reach here with an error for unordered bulk ops
    $self->_assert_no_write_error($result);

    # write concern errors are thrown only for the entire batch
    $self->_assert_no_write_concern_error($result);

    return $result;
}

# _execute_write_command_batch may split batches if they are too large and
# execute them separately

sub _execute_write_command_batch {
    my ( $self, $batch, $result, $ordered, $write_concern ) = @_;

    my ( $type, $docs )   = @$batch;
    my ( $cmd,  $op_key ) = @{ $OP_MAP{$type} };

    my $boolean_ordered = $ordered ? boolean::true : boolean::false;
    my $coll_name = $self->collection->name;

    my @left_to_send = ($docs);

    while (@left_to_send) {
        my $chunk = shift @left_to_send;

        my $cmd_doc = [
            $cmd    => $coll_name,
            $op_key => $chunk,
            ordered => $boolean_ordered,
            ( $write_concern ? ( writeConcern => $write_concern ) : () )
        ];

        my $cmd_result = try {
            $self->_database->_try_run_command($cmd_doc);
        }
        catch {
            if ( $_->$_isa("MongoDB::_CommandSizeError") ) {
                if ( @$chunk == 1 ) {
                    MongoDB::DocumentSizeError->throw(
                        message  => "document too large",
                        document => $chunk->[0],
                    );
                }
                else {
                    unshift @left_to_send, $self->_split_chunk( $chunk, $_->size );
                }
            }
            else {
                die $_;
            }
            return;
        };

        next unless $cmd_result;

        my $r = MongoDB::WriteResult->_parse(
            op       => $type,
            op_count => scalar @$chunk,
            result   => $cmd_result,
        );

        # append corresponding ops to errors
        if ( $r->count_writeErrors ) {
            for my $error ( @{ $r->writeErrors } ) {
                $error->{op} = $chunk->[ $error->{index} ];
                # convert boolean::true|false back to 1 or 0
                for my $k (qw/upsert multi/) {
                    $error->{op}{$k} = 0+ $error->{op}{$k} if exists $error->{op}{$k};
                }
            }
        }

        $result->merge_result($r);
        $self->_assert_no_write_error($result) if $ordered;
    }

    return;
}

sub _split_chunk {
    my ( $self, $chunk, $size ) = @_;

    my $max_wire_size = $self->_client->_max_bson_wire_size;

    my $avg_cmd_size       = $size / @$chunk;
    my $new_cmds_per_chunk = int( $max_wire_size / $avg_cmd_size );

    my @split_chunks;
    while (@$chunk) {
        push @split_chunks, [ splice( @$chunk, 0, $new_cmds_per_chunk ) ];
    }

    return @split_chunks;
}

sub _batch_ordered {
    my ($self) = @_;
    my @batches;
    my $last_type = '';
    my $count     = 0;

    my $max_batch_count = $self->_client->_max_write_batch_size;

    for my $op ( $self->_all_writes ) {
        my ( $type, $doc ) = @$op;
        if ( $type ne $last_type || $count == $max_batch_count ) {
            push @batches, [ $type => [$doc] ];
            $last_type = $type;
            $count     = 1;
        }
        else {
            push @{ $batches[-1][-1] }, $doc;
            $count++;
        }
    }

    return @batches;
}

sub _batch_unordered {
    my ($self) = @_;
    my %batches = map { ; $_ => [ [] ] } keys %OP_MAP;

    my $max_batch_count = $self->_client->_max_write_batch_size;

    for my $op ( $self->_all_writes ) {
        my ( $type, $doc ) = @$op;
        if ( @{ $batches{$type}[-1] } == $max_batch_count ) {
            push @{ $batches{$type} }, [$doc];
        }
        else {
            push @{ $batches{$type}[-1] }, $doc;
        }
    }

    # insert/update/delete are guaranteed to be in random order on Perl 5.18+
    my @batches;
    for my $type ( grep { scalar @{ $batches{$_}[-1] } } keys %batches ) {
        push @batches, map { [ $type => $_ ] } @{ $batches{$type} };
    }
    return @batches;
}

sub _assert_no_write_error {
    my ( $self, $result ) = @_;
    if ( my $write_errors = $result->count_writeErrors ) {
        MongoDB::WriteError->throw(
            message => "writeErrors: $write_errors",
            result  => $result,
        );
    }
    return;
}

sub _assert_no_write_concern_error {
    my ( $self, $result ) = @_;
    if ( my $write_concern_errors = $result->count_writeConcernErrors ) {
        MongoDB::WriteConcernError->throw(
            message => "writeConcernErrors: $write_concern_errors",
            result  => $result,
        );
    }
    return;
}

# XXX the _execute_legacy_(insert|update|delete) commands duplicate code in
# Collection.pm, but that code is wrapped up in a way that doesn't easily allow
# grabbing result details.  We can't parse a response directly because the
# network receive code is tightly coupled to a cursor.  These functions work
# around these limitations for the time being

sub _execute_legacy_batch {
    my ( $self, $batch, $result, $ordered, $write_concern ) = @_;
    my ( $type, $docs ) = @$batch;

    my $coll   = $self->collection;
    my $client = $self->_client;
    my $ns     = $coll->full_name;
    my $method = "_gen_legacy_$type";

    # check write_concern with 'eq' for string "0" because write concern can be
    # 'majority' or a tag-set and it would be an error to check that with '=='
    my $w_0 = defined $write_concern->{w} && $write_concern->{w} eq "0";

    for my $doc (@$docs) {
        # legacy server doesn't check keys on insert; we fake an error if it happens
        if ( $type eq 'insert' && ( my $r = $self->_check_no_dollar_keys($doc) ) ) {
            if ($w_0) {
                last if $ordered;
            }
            else {
                $result->merge_result($r);
                $self->_assert_no_write_error($result) if $ordered;
            }
            next;
        }

        my $op_string = $self->$method( $ns, $doc );

        # this isn't quite right; a command should allow a max-sized object plus
        # some overhead, but this is consistent with how Collection.pm does it
        if ( length($op_string) > $client->max_bson_size ) {
            if ($w_0) {
                last if $ordered;
            }
            else {
                $result->merge_result( $self->_fake_doc_size_error($doc) );
                $self->_assert_no_write_error($result) if $ordered;
            }
            next;
        }

        my $gle_result;

        # Even for {w:0}, if the batch is ordered we have to check each result
        # and break on the first error, but we don't throw the error to the user.
        if ( $ordered || !$w_0 ) {
            my $op_result = $coll->_make_safe_cursor( $op_string, $write_concern )->next;
            $gle_result = $self->_get_writeresult_from_gle( $type, $op_result, $doc );
            last if $w_0 && $gle_result->count_writeErrors;
        }
        else {
            # Fire and forget and mock up an empty result to get the right op count
            $client->send($op_string);
            $gle_result = MongoDB::WriteResult->_parse(
                op       => $type,
                op_count => 1,
                result   => { n => 0 },
            );
        }

        $result->merge_result($gle_result);
        $self->_assert_no_write_error($result) if $ordered;
    }

    return;
}

sub _get_writeresult_from_gle {
    my ( $self, $type, $gle, $doc ) = @_;
    my ( @writeErrors, $writeConcernError, @upserted );

    # Still checking for $err here because it's not yet handled during
    # reply unpacking
    if ( exists $gle->{'$err'} ) {
        MongoDB::DatabaseError->throw(
            message => $gle->{'$err'},
            result  => MongoDB::CommandResult->new( result => $gle ),
        );
    }

    # 'ok' false means GLE itself failed
    if ( !$gle->{ok} ) {
        MongoDB::DatabaseError->throw(
            message => $gle->{errmsg},
            result  => MongoDB::CommandResult->new( result => $gle ),
        );
    }

    # usually we shouldn't check wnote or jnote, but the Bulk API QA test says we should
    # detect no journal or replication not enabled, so we check for special strings.
    # These strings were checked back to MongoDB 1.8.5.
    if ( exists $gle->{jnote} && $gle->{jnote} =~ /^journaling not enabled/ ) {
        MongoDB::DatabaseError->throw(
            message => $gle->{jnote},
            result  => MongoDB::CommandResult->new( result => $gle ),
        );
    }
    if ( exists $gle->{wnote} && $gle->{wnote} =~ /^no replication has been enabled/ ) {
        MongoDB::DatabaseError->throw(
            message => $gle->{wnote},
            result  => MongoDB::CommandResult->new( result => $gle ),
        );
    }

    my $affected = 0;
    my $errmsg =
        defined $gle->{err}    ? $gle->{err}
      : defined $gle->{errmsg} ? $gle->{errmsg}
      :                          undef;
    my $wtimeout = $gle->{wtimeout};

    if ($wtimeout) {
        my $code = $gle->{code} || WRITE_CONCERN_ERROR;
        $writeConcernError = {
            errmsg  => $errmsg,
            errInfo => { wtimeout => $wtimeout },
            code    => $code
        };
    }

    if ( defined $errmsg && !$wtimeout ) {
        my $code = $gle->{code} || UNKNOWN_ERROR;
        # index is always 0 because ops are executed individually; later
        # merging of results will fix up the index values as usual
        my $error_doc = {
            errmsg => $errmsg,
            code   => $code,
            index  => 0,
            op     => $doc,
        };
        # convert boolean::true|false back to 1 or 0
        for my $k (qw/upsert multi/) {
            $error_doc->{op}{$k} = 0+ $error_doc->{op}{$k} if exists $error_doc->{op}{$k};
        }
        $error_doc->{errInfo} = $gle->{errInfo} if exists $gle->{errInfo};
        push @writeErrors, $error_doc;
    }
    else {
        # GLE: n only returned for update/remove, so we infer it for insert
        $affected =
            $type eq 'insert' ? 1
          : defined $gle->{n} ? $gle->{n}
          :                     0;

        # index is always 0 because ops are executed individually; later
        # merging of results will fix up the index values as usual
        push @upserted, { index => 0, _id => $gle->{upserted} } if $gle->{upserted};
    }

    my $result = MongoDB::WriteResult->_parse(
        op       => $type,
        op_count => 1,
        result   => {
            n                 => $affected,
            writeErrors       => \@writeErrors,
            writeConcernError => $writeConcernError,
            ( @upserted ? ( upserted => \@upserted ) : () ),
        },
    );

    return $result;
}

sub _gen_legacy_insert {
    my ( $self, $ns, $doc ) = @_;
    # $doc is a document to insert

    # for bulk, we don't accumulate IDs
    my ( $insert, undef ) = MongoDB::write_insert( $ns, [$doc], 0 );

    return $insert;
}

sub _gen_legacy_update {
    my ( $self, $ns, $doc ) = @_;
    # $doc is { q: $query, u: $update, multi: $multi, upsert: $upsert }

    my $flags = 0;
    $flags |= 1 << 0 if $doc->{upsert};
    $flags |= 1 << 1 if $doc->{multi};

    return MongoDB::write_update( $ns, $doc->{q}, $doc->{u}, $flags );
}

sub _gen_legacy_delete {
    my ( $self, $ns, $doc ) = @_;
    # $doc is { q: $query, limit: $limit }

    return MongoDB::write_remove( $ns, $doc->{q}, $doc->{limit} ? 1 : 0 );
}

sub _check_no_dollar_keys {
    my ( $self, $doc ) = @_;

    my @keys = ref $doc eq 'Tie::IxHash' ? $doc->Keys : keys %$doc;
    if ( my @bad = grep { substr( $_, 0, 1 ) eq '$' } @keys ) {
        my $errdoc = {
            index  => 0,
            errmsg => "Document can't have '\$' prefixed field names: @bad",
            code   => UNKNOWN_ERROR
        };

        return MongoDB::WriteResult->new(
            op_count    => 1,
            nModified   => undef,
            writeErrors => [$errdoc]
        );
    }

    return;
}

sub _fake_doc_size_error {
    my ( $self, $doc ) = @_;

    my $errdoc = {
        index  => 0,
        errmsg => "Document too large",
        code   => UNKNOWN_ERROR
    };

    return MongoDB::WriteResult->new(
        op_count    => 1,
        writeErrors => [$errdoc]
    );
}

__PACKAGE__->meta->make_immutable;

1;