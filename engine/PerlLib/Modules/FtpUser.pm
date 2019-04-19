=head1 NAME

 Modules::FtpUser - i-MSCP FtpUser module

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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

package Modules::FtpUser;

use strict;
use warnings;
use iMSCP::Boolean;
use iMSCP::Debug qw/ error getLastError warning /;
use parent 'Modules::Abstract';

=head1 DESCRIPTION

 i-MSCP FtpUser module.

=head1 PUBLIC METHODS

=over 4

=item getType( )

 Get module type

 Return string Module type

=cut

sub getType
{
    'FtpUser';
}

=item process( \%data )

 Process module

 Param hashref \%data Ftp user data
 Return int 0 on success, other on failure

=cut

sub process
{
    my ( $self, $data ) = @_;

    my $rs = $self->_loadData( $data->{'id'} );
    return $rs if $rs;

    my @sql;
    if ( $self->{'status'} =~ /^to(?:add|change|enable)$/ ) {
        $rs = $self->add();
        @sql = ( 'UPDATE ftp_users SET status = ? WHERE userid = ?', undef,
            ( $rs ? getLastError( 'error' ) || 'Unknown error' : 'ok' ), $data->{'id'} );
    } elsif ( $self->{'status'} eq 'todisable' ) {
        $rs = $self->disable();
        @sql = ( 'UPDATE ftp_users SET status = ? WHERE userid = ?', undef,
            ( $rs ? getLastError( 'error' ) || 'Unknown error' : 'disabled' ), $data->{'id'} );
    } elsif ( $self->{'status'} eq 'todelete' ) {
        $rs = $self->delete();
        @sql = $rs
            ? ( 'UPDATE ftp_users SET status = ? WHERE userid = ?', undef,
            ( getLastError( 'error' ) || 'Unknown error' ), $data->{'id'} )
            : ( 'DELETE FROM ftp_users WHERE userid = ?', undef, $data->{'id'} );
    } else {
        warning( sprintf( 'Unknown action (%s) for ftp user (ID %d)', $self->{'status'}, $data->{'id'} ));
        return 0;
    }

    local $@;
    eval {
        local $self->{'_dbh'}->{'RaiseError'} = TRUE;
        $self->{'_dbh'}->do( @sql );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    $rs;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _loadData( $ftpUserId )

 Load data

 Param int $ftpUserId Ftp user unique identifier
 Return int 0 on success, other on failure

=cut

sub _loadData
{
    my ( $self, $ftpUserId ) = @_;

    local $@;
    eval {
        local $self->{'_dbh'}->{'RaiseError'} = TRUE;
        my $row = $self->{'_dbh'}->selectrow_hashref( 'SELECT * FROM ftp_users WHERE userid = ?', undef, $ftpUserId );
        $row or die( sprintf( 'Data not found for ftp user (ID %d)', $ftpUserId ));
        %{ $self } = ( %{ $self }, %{ $row } );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _getData( $action )

 Data provider method for servers and packages

 Param string $action Action
 Return hashref Reference to a hash containing data

=cut

sub _getData
{
    my ( $self, $action ) = @_;

    $self->{'_data'} = do {
        my $userName = my $groupName = $::imscpConfig{'SYSTEM_USER_PREFIX'} . (
            $::imscpConfig{'SYSTEM_USER_MIN_UID'}+$self->{'admin_id'}
        );

        {
            ACTION         => $action,
            STATUS         => $self->{'status'},
            OWNER_ID       => $self->{'admin_id'},
            USERNAME       => $self->{'userid'},
            PASSWORD_CRYPT => $self->{'passwd'},
            PASSWORD_CLEAR => $self->{'rawpasswd'},
            SHELL          => $self->{'shell'},
            HOMEDIR        => $self->{'homedir'},
            USER_SYS_GID   => $self->{'uid'},
            USER_SYS_GID   => $self->{'gid'},
            USER_SYS_NAME  => $userName,
            USER_SYS_GNAME => $groupName
        }
    } unless %{ $self->{'_data'} };

    $self->{'_data'};
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
