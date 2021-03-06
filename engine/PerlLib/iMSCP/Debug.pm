=head1 NAME

 iMSCP::Debug - Debug library

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2019 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package iMSCP::Debug;

use strict;
use warnings;
use File::Spec;
use iMSCP::Boolean;
use iMSCP::Log;
use parent 'Exporter';

our @EXPORT = qw/
    debug warning error fatal newDebug endDebug getMessage getLastError
    getMessageByType setVerbose setDebug output silent
/;

BEGIN {
    $SIG{'__DIE__'} = sub {
        fatal( @_ ) if defined $^S && !$^S
    };
    $SIG{'__WARN__'} = sub {
        warning( @_ );
    };
}

my $self;
$self = {
    debug   => FALSE,
    verbose => FALSE,
    loggers => [ iMSCP::Log->new( id => 'default' ) ],
    logger  => sub { $self->{'loggers'}->[$#{ $self->{'loggers'} }] }
};

=head1 DESCRIPTION

 Debug library

=head1 CLASS METHODS

=over 4

=item setDebug( $debug )

 Enable or disable debug mode

 Param bool $debug Enable verbose mode if true, disable otherwise
 Return undef

=cut

sub setDebug
{
    if ( $_[0] ) {
        $self->{'debug'} = TRUE;
        return;
    }

    # Remove any debug log message from all loggers
    for ( @{ $self->{'loggers'} } ) {
        $_->retrieve( tag => 'debug', remove => TRUE );
    }

    $self->{'debug'} = FALSE;
    undef;
}

=item setVerbose( $verbose )

 Enable or disable verbose mode

 Param bool $verbose Enable debug mode if true, disable otherwise
 Return undef

=cut

sub setVerbose
{
    $self->{'verbose'} = $_[0] // FALSE;
    undef;
}

=item silent( )

 Method kept for backward compatibility with plugins

 Return undef

=cut

sub silent
{
    undef;
}

=item newDebug( $loggerID )

 Create a new logger
 
 New logger will becomes the current logger

 Param string $loggerID Logger unique identifier ( used as log file name)
 Return int 0

=cut

sub newDebug
{
    my ( $loggerID ) = @_;

    fatal( "A log file unique identifier is expected" )
        unless length $loggerID;

    for my $logger ( @{ $self->{'loggers'} } ) {
        $logger->getId() ne $loggerID or die(
            "A logger with same identifier already exists"
        )
    }

    push @{ $self->{'loggers'} }, iMSCP::Log->new( id => $loggerID );
    0;
}

=item endDebug( )

 Write all log messages from the current logger and remove it from loggers stack (unless it is the default logger)

 Return int 0

=cut

sub endDebug
{
    my $logger = $self->{'logger'}();

    return 0 if $logger->getId() eq 'default';

    # Remove logger from loggers stack
    pop @{ $self->{'loggers'} };

    # warn, error and fatal log messages must be always stored in default
    # logger for later processing
    for ( $logger->retrieve( tag => qr/(?:warn|error|fatal)/ ) ) {
        $self->{'loggers'}->[0]->store( %{ $_ } );
    }

    my $logDir = $::imscpConfig{'LOG_DIR'} || '/tmp';
    if ( $logDir ne '/tmp' && !-d $logDir ) {
        require iMSCP::Dir;
        local $@;
        eval {
            iMSCP::Dir->new( dirname => $logDir )->make( {
                user  => $::imscpConfig{'ROOT_USER'},
                group => $::imscpConfig{'ROOT_GROUP'},
                mode  => 0750
            } );
        };
        $logDir = '/tmp' if $@;
    }

    _writeLogfile( $logger, File::Spec->catfile( $logDir, $logger->getId()));
}

=item debug( $message [, $caller ] )

 Log a debug message in the current logger

 Param string $message Debug message
 Param string $caller OPTIONAL Caller
 Return undef

=cut

sub debug
{
    my ( $message, $caller ) = @_;
    $caller //= getCaller();

    if ( $self->{'debug'} ) {
        $self->{'logger'}()->store(
            message => $caller ? "$caller: $message" : $message,
            tag     => 'debug'
        );
    }

    if ( $self->{'verbose'} ) {
        print STDOUT output(
            $caller ? "$caller: $message" : $message, 'debug'
        );
    }

    undef;
}

=item warning( $message [, $caller ] )

 Log a warning message in the current logger

 Param string $message Warning message
 Param string $caller OPTIONAL Caller
 Return undef

=cut

sub warning
{
    my ( $message, $caller ) = @_;
    $caller //= getCaller();

    $self->{'logger'}()->store(
        message => $caller ? "$caller: $message" : $message,
        tag     => 'warn'
    );
    undef;
}

=item error( $message [, $caller ] )

 Log an error message in the current logger

 Param string $message Error message
 Param string $caller OPTIONAL Caller
 Return undef

=cut

sub error
{
    my ( $message, $caller ) = @_;
    $caller //= getCaller();

    $self->{'logger'}()->store(
        message => $caller ? "$caller: $message" : $message,
        tag     => 'error'
    );
    undef;
}

=item fatal( $message [, $caller ] )

 Log a fatal message in the current logger and exit with status 255

 Param string $message Fatal message
 Param string $caller OPTIONAL Caller
 Return void

=cut

sub fatal
{
    my ( $message, $caller ) = @_;
    $caller //= getCaller();

    $self->{'logger'}()->store(
        message => $caller ? "$caller: $message" : $message,
        tag     => 'fatal'
    );
    exit 255;
}

=item getLastError()

 Get last error messages from the current logger as a string

 Return string Last error messages

=cut

sub getLastError
{
    scalar getMessageByType( 'error' );
}

=item getMessageByType( $type [, \%options ] )

 Get message by type from current logger, according given options

 Param string $type Type or regexp
 Param hash %option|\%options Hash containing options (amount, chrono, remove)
 Return array|string An array of messages or a string of messages

=cut

sub getMessageByType
{
    my ( $type, $options ) = @_;
    $options ||= {};

    my @messages = map { $_->{'message'} } $self->{'logger'}()->retrieve(
        tag    => ref $type eq 'Regexp' ? $type : qr/$type/i,
        amount => $options->{'amount'},
        chrono => $options->{'chrono'} // TRUE,
        remove => $options->{'remove'} // FALSE
    );
    wantarray ? @messages : join "\n", @messages;
}

=item output( $text [, $level ] )

 Prepare the given text to be show on the console according the given level

 Param string $text Text to format
 Param string $level OPTIONAL Format level
 Return string Formatted message

=cut

sub output
{
    my ( $text, $level ) = @_;

    return "$text\n" unless $level;

    my $output = '';

    if ( $level eq 'debug' ) {
        $output = "[\033[0;34mDEBUG\033[0m] $text\n";
    } elsif ( $level eq 'info' ) {
        $output = "[\033[0;34mINFO\033[0m]  $text\n";
    } elsif ( $level eq 'warn' ) {
        $output = "[\033[0;33mWARN\033[0m]  $text\n";
    } elsif ( $level eq 'error' ) {
        $output = "[\033[0;31mERROR\033[0m] $text\n";
    } elsif ( $level eq 'fatal' ) {
        $output = "[\033[0;31mFATAL\033[0m] $text\n";
    } elsif ( $level eq 'ok' ) {
        $output = "[\033[0;32mDONE\033[0m]  $text\n";
    } else {
        $output = "$text\n";
    }

    $output;
}

=item getCaller()

 Return first subroutine caller or main, excluding eval and __ANON__
 Return string

=cut

sub getCaller
{
    my $caller;
    my $stackIDX = 2;
    do {
        $caller = ( ( caller $stackIDX++ )[3] || 'main' );
    } while $caller eq '(eval)' || index( $caller, '__ANON__' ) != -1;
    $caller;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _writeLogfile($logger, $logfilePath)

 Write all log messages from the given logger

 Param iMSCP::Log $logger Logger
 Param string $logfilePath Logfile path in which log messages must be writen

 Return int 0

=cut

sub _writeLogfile
{
    my ( $logger, $logfilePath ) = @_;

    if ( open( my $fh, '>', $logfilePath ) ) {
        # Make error message free of any ANSI escape sequences
        for my $log ( $logger->flush() ) {
            $log =~ s/\x1b\[[0-9;]*[mGKH]//g;
            print { $fh } "[$log->{'when'}] [$log->{'tag'}] $log->{'message'}\n";
        }

        close $fh;
        return 0;
    }

    print output( sprintf(
        "Couldn't open log file '%s' for writing: %s", $logfilePath, $! ),
        'error'
    );
    0;
}

=item _getMessages( $logger )

 Flush and return all log messages from the given logger as a string

 Param Param iMSCP::Log $logger Logger
 Return string String representing concatenation of all messages found in the given log object

=cut

sub _getMessages
{
    my ( $logger ) = @_;

    my $bf = '';
    for my $log ( $logger->flush() ) {
        $bf .= "[$log->{'when'}] [$log->{'tag'}] $log->{'message'}\n";
    }
    $bf;
}

=item END

 Process ending tasks and print warn, error and fatal log messages to STDERR if any

=cut

END {
    my $exitCode = $?;

    my $countLoggers = scalar @{ $self->{'loggers'} };
    while ( $countLoggers > 0 ) {
        endDebug();
        $countLoggers--;
    }

    for ( $self->{'logger'}()->retrieve(
        tag => qr/(?:warn|error|fatal)/, remove => TRUE
    ) ) {
        print STDERR output( $_->{'message'}, $_->{'tag'} );
    }

    $? = $exitCode;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
