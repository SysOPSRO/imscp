=head1 NAME

 Servers::httpd::apache_itk - i-MSCP Apache2/ITK Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2016 by Laurent Declercq <l.declercq@nuxwin.com>
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

package Servers::httpd::apache_itk;

use strict;
use warnings;
use Class::Autouse qw/ Servers::httpd::apache_itk::installer Servers::httpd::apache_itk::uninstaller /;
use File::Basename;
use File::Spec;
use File::Temp;
use iMSCP::Config;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::Ext2Attributes qw/ setImmutable clearImmutable isImmutable /;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Mount qw / mount umount isMountpoint addMountEntry removeMountEntry /;
use iMSCP::Net;
use iMSCP::ProgramFinder;
use iMSCP::Rights;
use iMSCP::TemplateParser;
use iMSCP::Service;
use List::MoreUtils qw(uniq);
use Scalar::Defer;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Apache2/ITK Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    Servers::httpd::apache_itk::installer->getInstance()->registerSetupListeners( $_[1] );
}

=item preinstall()

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdPreInstall', 'apache_itk' );
    $rs ||= $self->stop();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdPreInstall', 'apache_itk' );
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdInstall', 'apache_itk' );
    $rs ||= $rs = Servers::httpd::apache_itk::installer->getInstance()->install();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdInstall', 'apache_itk' );
}

=item postinstall()

 Process postinstall tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdPostInstall', 'apache_itk' );
    return $rs if $rs;

    local $@;
    eval { iMSCP::Service->getInstance()->enable( $self->{'config'}->{'HTTPD_SNAME'} ); };
    if ($@) {
        error( $@ );
        return 1;
    }

    $rs = $self->{'eventManager'}->register(
        'beforeSetupRestartServices',
        sub {
            push @{$_[0]}, [ sub { $self->start(); }, 'Httpd (Apache2/ITK)' ];
            0;
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdPostInstall', 'apache_itk' );
}

=item uninstall()

 Process uninstall tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdUninstall', 'apache_itk' );
    $rs ||= Servers::httpd::apache_itk::uninstaller->getInstance()->uninstall();
    $rs ||= $rs = $self->{'eventManager'}->trigger( 'afterHttpdUninstall', 'apache_itk' );
    $rs ||= $self->restart();
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdSetEnginePermissions' );
    $rs ||= $rs = Servers::httpd::apache_itk::installer->getInstance()->setEnginePermissions();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdSetEnginePermissions' );
}

=item addUser(\%data)

 Process addUser tasks

 Param hash \%data User data
 Return int 0 on success, other on failure

=cut

sub addUser
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddUser', $data );
    $self->setData( $data );
    $rs ||= iMSCP::SystemUser->new( username => $self->{'config'}->{'HTTPD_USER'} )->addToGroup( $data->{'GROUP'} );
    $rs || ($self->{'restart'} = 1);
    $rs ||= $self->flushData();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddUser', $data );
}

=item deleteUser(\%data)

 Process deleteUser tasks

 Param hash \%data User data
 Return int 0 on success, other on failure

=cut

sub deleteUser
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelUser', $data );
    $rs ||= iMSCP::SystemUser->new( username => $self->{'config'}->{'HTTPD_USER'} )->removeFromGroup(
        $data->{'GROUP'}
    );
    $rs || ($self->{'restart'} = 1);
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdDelUser', $data );
}

=item addDmn(\%data)

 Process addDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub addDmn
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddDmn', $data );
    $self->setData( $data );
    $rs ||= $self->_addCfg( $data );
    $rs ||= $self->_addFiles( $data );
    $rs || ($self->{'restart'} = 1);
    $rs ||= $self->flushData();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddDmn', $data );
}

=item restoreDmn(\%data)

 Process restoreDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub restoreDmn
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdRestoreDmn', $data );
    $self->setData( $data );
    $rs ||= $self->_addFiles( $data );
    $rs ||= $self->flushData();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdRestoreDmn', $data );
}

=item disableDmn(\%data)

 Process disableDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub disableDmn
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDisableDmn', $data );
    return $rs if $rs;

    # Ensure that all needed directories are present
    for ($self->_dmnFolders( $data )) {
        $rs = iMSCP::Dir->new( dirname => $_->[0] )->make( { user => $_->[1], group => $_->[2], mode => $_->[3] } );
        return $rs if $rs;
    }

    $self->setData( $data );

    my $net = iMSCP::Net->getInstance();
    my $isApache24 = version->parse( "$self->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.4.0' );

    my @domainIPs = ($data->{'BASE_SERVER_IP'}, $data->{'DOMAIN_IP'});
    $rs = $self->{'eventManager'}->trigger( 'onAddHttpdVhostIps', $data, \@domainIPs );
    return $rs if $rs;

    # Remove duplicate IP if any
    @domainIPs = uniq( map { $net->normalizeAddr( $_ ) } @domainIPs );

    $self->setData(
        {
            BASE_SERVER_VHOST => $data->{'BASE_SERVER_VHOST'},
            AUTHZ_ALLOW_ALL   => $isApache24 ? 'Require all granted' : 'Allow from all',
            HTTPD_LOG_DIR     => $self->{'config'}->{'HTTPD_LOG_DIR'},
            DOMAIN_IPS        =>  join(' ', map { ($net->getAddrVersion( $_ ) eq 'ipv4' ? $_ : "[$_]") . ':80' } @domainIPs),
            USER_WEB_DIR      => $main::imscpConfig{'USER_WEB_DIR'}
        }
    );

    # Create http vhost

    if ($data->{'HSTS_SUPPORT'}) {
        $self->setData(
            {
                FORWARD      => "https://$data->{'DOMAIN_NAME'}/",
                FORWARD_TYPE => '301'
            }
        );
    }

    $rs = $self->buildConfFile(
        "$self->{'apacheTplDir'}/".($data->{'HSTS_SUPPORT'} ? 'domain_redirect.tpl' : 'domain_disabled.tpl'),
        $data,
        { destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
    );
    $rs ||= $self->enableSites( "$data->{'DOMAIN_NAME'}.conf" );
    return $rs if $rs;

    # Create https vhost (or delete it if SSL is disabled)

    if ($data->{'SSL_SUPPORT'}) {
        $self->setData(
            {
                CERTIFICATE => "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$data->{'DOMAIN_NAME'}.pem",
                DOMAIN_IPS  =>  join(' ', map { ($net->getAddrVersion( $_ ) eq 'ipv4' ? $_ : "[$_]") . ':443' } @domainIPs),
            }
        );
        $rs = $self->buildConfFile(
            "$self->{'apacheTplDir'}/domain_disabled_ssl.tpl",
            $data,
            { destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf" }
        );
        $rs ||= $self->enableSites( "$data->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;
    } elsif (-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf") {
        $rs = $self->disableSites( "$data->{'DOMAIN_NAME'}_ssl.conf" );
        $rs ||= iMSCP::File->new(
            filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf"
        )->delFile();
        return $rs if $rs;
    }

    # Ensure that custom httpd conffile exists (cover case where file has been removed for any reasons)
    unless (-f "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf") {
        $rs = $self->buildConfFile(
            "$self->{'apacheTplDir'}/custom.conf.tpl",
            $data,
            { destination => "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
        );
        return $rs if $rs;
    }

    # Transitional - Remove deprecated `domain_disable_page' directory if any
    if ($data->{'DOMAIN_TYPE'} eq 'dmn' && -d $data->{'WEB_DIR'}) {
        clearImmutable( $data->{'WEB_DIR'} );
        $rs = iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/domain_disable_page" )->remove();
        return $rs if $rs;
        setImmutable( $data->{'WEB_DIR'} ) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    }

    $self->flushData();
    $self->{'eventManager'}->trigger( 'afterHttpdDisableDmn', $data );
}

=item deleteDmn(\%data)

 Process deleteDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub deleteDmn
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelDmn', $data );
    $rs ||= $self->disableSites( "$data->{'DOMAIN_NAME'}.conf", "$data->{'DOMAIN_NAME'}_ssl.conf" );
    return $rs if $rs;

    for ("$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}.conf",
        "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf",
        "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf"
    ) {
        next unless -f $_;
        $rs = iMSCP::File->new( filename => $_ )->delFile();
        return $rs if $rs;
    }

    $rs = $self->umountLogsFolder( $data );
    return $rs if $rs;

    unless ($data->{'SHARED_MOUNT_POINT'} || !-d $data->{'WEB_DIR'}) {
        (my $userWebDir = $main::imscpConfig{'USER_WEB_DIR'}) =~ s%/+$%%;
        my $parentDir = dirname( $data->{'WEB_DIR'} );

        clearImmutable( $parentDir );
        clearImmutable( $data->{'WEB_DIR'}, 'recursive' );

        $rs = iMSCP::Dir->new( dirname => $data->{'WEB_DIR'} )->remove();
        return $rs if $rs;

        if ($parentDir ne $userWebDir) {
            my $dir = iMSCP::Dir->new( dirname => $parentDir );

            if ($dir->isEmpty()) {
                clearImmutable( dirname( $parentDir ) );
                $rs = $dir->remove();
                return $rs if $rs;
            }
        }

        if ($data->{'WEB_FOLDER_PROTECTION'} eq 'yes' && $parentDir ne $userWebDir) {
            do {
                setImmutable( $parentDir ) if -d $parentDir;
            } while (($parentDir = dirname( $parentDir )) ne $userWebDir);
        }
    }

    $rs = iMSCP::Dir->new( dirname => "$data->{'HOME_DIR'}/logs/$data->{'DOMAIN_NAME'}" )->remove();
    $rs ||= iMSCP::Dir->new( dirname => "$self->{'config'}->{'HTTPD_LOG_DIR'}/$data->{'DOMAIN_NAME'}" )->remove();
    $rs || ($self->{'restart'} = 1);
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdDelDmn', $data );
}

=item addSub(\%data)

 Process addSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub addSub
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddSub', $data );
    $self->setData( $data );
    $rs ||= $self->_addCfg( $data );
    $rs ||= $self->_addFiles( $data );
    $rs || ($self->{'restart'} = 1);
    $rs ||= $self->flushData();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddSub', $data );
}

=item restoreSub(\%data)

 Process restoreSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub restoreSub
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdRestoreSub', $data );
    $self->setData( $data );
    $rs ||= $self->_addFiles( $data );
    $rs ||= $self->flushData();
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdRestoreSub', $data );
}

=item disableSub(\%data)

 Process disableSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub disableSub
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDisableSub', $data );
    $rs ||= $self->disableDmn( $data );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdDisableSub', $data );
}

=item deleteSub(\%data)

 Process deleteSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub deleteSub
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelSub', $data );
    $rs ||= $self->deleteDmn( $data );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdDelSub', $data );
}

=item AddHtuser(\%data)

 Process AddHtuser tasks

 Param hash \%data Htuser data
 Return int 0 on success, other on failure

=cut

sub addHtuser
{
    my ($self, $data) = @_;

    my $fileName = $self->{'config'}->{'HTACCESS_USERS_FILENAME'};
    my $filePath = "$data->{'WEB_DIR'}/$fileName";

    clearImmutable( $data->{'WEB_DIR'} );

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddHtuser', \$fileContent, $data );
    return $rs if $rs;

    $fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;
    $fileContent .= "$data->{'HTUSER_NAME'}:$data->{'HTUSER_PASS'}\n";

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdAddHtuser', \$fileContent, $data );
    $rs ||= $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'} );
    return $rs if $rs;

    setImmutable( $data->{'WEB_DIR'} ) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    0;
}

=item deleteHtuser(\%data)

 Process deleteHtuser tasks

 Param hash \%data Htuser data
 Return int 0 on success, other on failure

=cut

sub deleteHtuser
{
    my ($self, $data) = @_;

    my $fileName = $self->{'config'}->{'HTACCESS_USERS_FILENAME'};
    my $filePath = "$data->{'WEB_DIR'}/$fileName";

    clearImmutable( $data->{'WEB_DIR'} );

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelHtuser', \$fileContent, $data );
    return $rs if $rs;

    $fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdDelHtuser', \$fileContent, $data );
    $rs ||= $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'} );
    return $rs if $rs;

    setImmutable( $data->{'WEB_DIR'} ) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    0;
}

=item addHtgroup(\%data)

 Process addHtgroup tasks

 Param hash \%data Htgroup data
 Return int 0 on success, other on failure

=cut

sub addHtgroup
{
    my ($self, $data) = @_;

    my $fileName = $self->{'config'}->{'HTACCESS_GROUPS_FILENAME'};
    my $filePath = "$data->{'WEB_DIR'}/$fileName";

    clearImmutable( $data->{'WEB_DIR'} );

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddHtgroup', \$fileContent, $data );
    return $rs if $rs;

    $fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;
    $fileContent .= "$data->{'HTGROUP_NAME'}:$data->{'HTGROUP_USERS'}\n";

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdAddHtgroup', \$fileContent, $data );
    $rs ||= $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'} );
    return $rs if $rs;

    setImmutable( $data->{'WEB_DIR'} ) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    0;
}

=item deleteHtgroup(\%data)

 Process deleteHtgroup tasks

 Param hash \%data Htgroup data
 Return int 0 on success, other on failure

=cut

sub deleteHtgroup
{
    my ($self, $data) = @_;

    my $fileName = $self->{'config'}->{'HTACCESS_GROUPS_FILENAME'};
    my $filePath = "$data->{'WEB_DIR'}/$fileName";

    clearImmutable( $data->{'WEB_DIR'} );

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelHtgroup', \$fileContent, $data );
    return $rs if $rs;

    $fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;

    $rs = $file->set( $fileContent );
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdDelHtgroup', \$fileContent, $data );
    $rs ||= $file->save();
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'} );
    return $rs if $rs;

    setImmutable( $data->{'WEB_DIR'} ) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';
    0;
}

=item addHtaccess(\%data)

 Process addHtaccess tasks

 Param hash \%data Htaccess data
 Return int 0 on success, other on failure

=cut

sub addHtaccess
{
    my ($self, $data) = @_;

    # Here we process only if AUTH_PATH directory exists
    # Note: It's temporary fix for 1.1.0-rc2 (See #749)
    return 0 unless -d $data->{'AUTH_PATH'};

    my $fileUser = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_USERS_FILENAME'}";
    my $fileGroup = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_GROUPS_FILENAME'}";
    my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

    my $isImmutable = isImmutable( $data->{'AUTH_PATH'} );
    clearImmutable( $data->{'AUTH_PATH'} ) if $isImmutable;

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddHtaccess', \$fileContent, $data );
    return $rs if $rs;

    my $bTag = "### START i-MSCP PROTECTION ###\n";
    my $eTag = "### END i-MSCP PROTECTION ###\n";
    my $tagContent = "AuthType $data->{'AUTH_TYPE'}\nAuthName \"$data->{'AUTH_NAME'}\"\nAuthUserFile $fileUser\n";

    if ($data->{'HTUSERS'} eq '') {
        $tagContent .= "AuthGroupFile $fileGroup\nRequire group $data->{'HTGROUPS'}\n";
    } else {
        $tagContent .= "Require user $data->{'HTUSERS'}\n";
    }

    $fileContent = replaceBloc( $bTag, $eTag, '', $fileContent );
    $fileContent = $bTag.$tagContent.$eTag.$fileContent;

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdAddHtaccess', \$fileContent, $data );
    $rs ||= $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->owner( $data->{'USER'}, $data->{'GROUP'} );
    setImmutable( $data->{'AUTH_PATH'} ) if $isImmutable;
    $rs;
}

=item deleteHtaccess(\%data)

 Process deleteHtaccess tasks

 Param hash \%data Htaccess data
 Return int 0 on success, other on failure

=cut

sub deleteHtaccess
{
    my ($self, $data) = @_;

    # Here we process only if AUTH_PATH directory exists
    # Note: It's temporary fix for 1.1.0-rc2 (See #749)
    return 0 unless -d $data->{'AUTH_PATH'};

    my $fileUser = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_USERS_FILENAME'}";
    my $fileGroup = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_GROUPS_FILENAME'}";
    my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

    my $isImmutable = isImmutable( $data->{'AUTH_PATH'} );
    clearImmutable( $data->{'AUTH_PATH'} ) if $isImmutable;

    my $file = iMSCP::File->new( filename => $filePath );
    my $fileContent = $file->get() if -f $filePath;
    $fileContent = '' unless defined $fileContent;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDelHtaccess', \$fileContent, $data );
    return $rs if $rs;

    my $bTag = "### START i-MSCP PROTECTION ###\n";
    my $eTag = "### END i-MSCP PROTECTION ###\n";

    $fileContent = replaceBloc( $bTag, $eTag, '', $fileContent );

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdDelHtaccess', \$fileContent, $data );
    return $rs if $rs;

    if ($fileContent ne '') {
        $rs = $file->set( $fileContent );
        $rs ||= $file->save();
        $rs ||= $file->mode( 0640 );
        $rs ||= $file->owner( $data->{'USER'}, $data->{'GROUP'} );
    } elsif (-f $filePath) {
        $rs = $file->delFile();
    }

    setImmutable( $data->{'AUTH_PATH'} ) if $isImmutable;
    $rs;
}

=item addIps(\%data)

 Process addIps tasks

 Param hash \%data IPs data as provided by the Modules::Ips module
 Return int 0 on success, other on failure

=cut

sub addIps
{
    my ($self, $data) = @_;

    my $file = iMSCP::File->new( filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_nameserver.conf" );
    my $fileContent = $file->get();
    unless (defined $fileContent) {
        error( sprintf( 'Could not read %s file', $file->{'filename'} ) );
        return 1;
    }

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddIps', \$fileContent, $data );
    return $rs if $rs;

    # Cleanup previous entries if any
    $fileContent =~ s/^NameVirtualHost[^\n]+\n//gim;

    unless (version->parse( "$self->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.4.0' )) {
        my $net = iMSCP::Net->getInstance();

        for (@{$data->{'SSL_IPS'}}) {
            if ($net->getAddrVersion( $_ ) eq 'ipv4') {
                $fileContent .= "NameVirtualHost $_:443\n";
            } else {
                $fileContent .= "NameVirtualHost [$_]:443\n";
            }
        }

        for (@{$data->{'IPS'}}) {
            if ($net->getAddrVersion( $_ ) eq 'ipv4') {
                $fileContent .= "NameVirtualHost $_:80\n";
            } else {
                $fileContent .= "NameVirtualHost [$_]:80\n";
            }
        }
    } else {
        $fileContent =~ s/^# NameVirtualHost entries\n//im;
    }

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdAddIps', \$fileContent, $data );
    $rs ||= $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $self->enableSites( '00_nameserver.conf' );
    $rs || ($self->{'restart'} = 1);
    $rs;
}

=item buildConf($cfgTpl, $filename [, \%data ])

 Build the given configuration template

 Param string $cfgTpl Template content
 Param string $filename Template filename
 Param hash \%data OPTIONAL Data as provided by Alias|Domain|Subdomain|SubAlias modules or installer
 Return string Template content

=cut

sub buildConf
{
    my ($self, $cfgTpl, $filename, $data) = @_;

    $self->{'eventManager'}->trigger( 'beforeHttpdBuildConf', \$cfgTpl, $filename, $data );
    $cfgTpl = process( $self->{'data'}, $cfgTpl );
    $self->{'eventManager'}->trigger( 'afterHttpdBuildConf', \$cfgTpl, $filename, $data );
    $cfgTpl;
}

=item buildConfFile($file [, \%data = { } [, \%options = { } ]])

 Build the given configuration file

 Param string $file Absolute path to config file or config filename relative to the i-MSCP apache config directory
 Param hash \%data OPTIONAL Data as provided by Alias|Domain|Subdomain|SubAlias modules or installer
 Param hash \%options OPTIONAL Options:
  - destination: Destination file path (default to $self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/<filebasename>)
  - user: File owner
  - group: File group
  - mode:  File mode
 Return int 0 on success, other on failure

=cut

sub buildConfFile
{
    my ($self, $file, $data, $options) = @_;

    $data ||= { };
    $options ||= { };

    my ($filename, $path) = fileparse( $file );

    my $rs = $self->{'eventManager'}->trigger(
        'onLoadTemplate', 'apache_itk', $filename, \ my $cfgTpl, $data, $options
    );
    return $rs if $rs;

    unless (defined $cfgTpl) {
        $file = "$self->{'apacheCfgDir'}/$file" unless -d $path && $path ne './';
        $cfgTpl = iMSCP::File->new( filename => $file )->get();
        unless (defined $cfgTpl) {
            error( sprintf( 'Could not read %s file', $file ) );
            return 1;
        }
    }

    $rs = $self->{'eventManager'}->trigger( 'beforeHttpdBuildConfFile', \$cfgTpl, $filename, $data, $options );
    return $rs if $rs;

    $cfgTpl = $self->buildConf( $cfgTpl, $filename, $data );

    $rs = $self->{'eventManager'}->trigger( 'afterHttpdBuildConfFile', \$cfgTpl, $filename, $data, $options );
    return $rs if $rs;

    $options->{'destination'} ||= "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$filename";

    my $fileHandler = iMSCP::File->new( filename => $options->{'destination'} );
    $rs = $fileHandler->set( $cfgTpl );
    $rs ||= $fileHandler->save();
    $rs ||= $fileHandler->owner(
        $options->{'user'} // $main::imscpConfig{'ROOT_USER'}, $options->{'group'} // $main::imscpConfig{'ROOT_GROUP'}
    );
    $rs ||= $fileHandler->mode( $options->{'mode'} // 0644 );
}

=item setData(\%data)

 Make the given data available for this server

 Param hash \%data Server data
 Return int 0 on success, other on failure

=cut

sub setData
{
    my ($self, $data) = @_;

    @{$self->{'data'}}{keys %{$data}} = values %{$data};
    0;
}

=item flushData()

 Flush all data set via the setData() method

 Return int 0

=cut

sub flushData
{
    my $self = shift;

    delete $self->{'data'};
    0;
}

=item getTraffic($timestamp)

 Get httpd traffic data

 Return hash Traffic data or die on failure

=cut

sub getTraffic
{
    my $self = shift;

    my $timestamp = time();
    my $trafficDbPath = "$main::imscpConfig{'IMSCP_HOMEDIR'}/http_traffic.db";

    # Load traffic database (create it if doesn't exist)
    tie my %trafficDb, 'iMSCP::Config', fileName => $trafficDbPath, nowarn => 1;

    require Date::Format;
    Date::Format->import();
    my $ldate = time2str( '%Y%m%d', $timestamp );

    my $db = iMSCP::Database->factory();
    my $dbh = $db->startTransaction();

    eval {
        # Collect traffic data
        my $sth = $dbh->prepare( 'SELECT vhost, bytes FROM httpd_vlogger WHERE ldate <= ? FOR UPDATE' );
        $sth->execute( $ldate );

        while (my $row = $sth->fetchrow_hashref()) {
            $trafficDb{$row->{'vhost'}} += $row->{'bytes'};
        }

        # Delete traffic data source
        $dbh->do( 'DELETE FROM httpd_vlogger WHERE ldate <= ?', undef, $ldate );
        $dbh->commit();
    };

    if ($@) {
        $dbh->rollback();
        %trafficDb = ();
        $db->endTransaction();
        die( sprintf( 'Could not collect traffic data: %s', $@ ) );
    }

    $db->endTransaction();

    # Schedule deletion of full traffic database. This is only done on success. On failure, the traffic database is kept
    # in place for later processing. In such case, data already processed are zeroed by the traffic processor script.
    $self->{'eventManager'}->register(
        'afterVrlTraffic', sub { -f $trafficDbPath ? iMSCP::File->new( filename => $trafficDbPath )->delFile() : 0; }
    );
    \%trafficDb;
}

=item getRunningUser()

 Get user name under which the Apache server is running

 Return string User name under which the apache server is running

=cut

sub getRunningUser
{
    my $self = shift;

    $self->{'config'}->{'HTTPD_USER'};
}

=item getRunningGroup()

 Get group name under which the Apache server is running

 Return string Group name under which the apache server is running

=cut

sub getRunningGroup
{
    my $self = shift;

    $self->{'config'}->{'HTTPD_GROUP'};
}

=item enableSites(@sites)

 Enable the given sites

 Param array @sites List of sites to enable
 Return int 0 on sucess, other on failure

=cut

sub enableSites
{
    my ($self, @sites) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdEnableSites', \@sites );
    return $rs if $rs;

    for (@sites) {
        unless (-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_") {
            warning( sprintf( "Site %s doesn't exists", $_ ) );
            next;
        }

        my $rs = execute( [ 'a2ensite', $_ ], \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;
        $self->{'restart'} = 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdEnableSites', @sites );
}

=item disableSites(@sites)

 Disable the given sites

 Param array @sites List of sites to disable
 Return int 0 on sucess, other on failure

=cut

sub disableSites
{
    my ($self, @sites) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDisableSites', \@sites );
    return $rs if $rs;

    for (@sites) {
        next unless -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_";
        my $rs = execute( [ 'a2dissite', $_ ], \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;
        $self->{'restart'} = 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdDisableSites', @sites );
}

=item enableModules($modules)

 Enable the given Apache modules

 Param string $modules List of modules to enable
 Return int 0 on sucess, other on failure

=cut

sub enableModules
{
    my ($self, @modules) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdEnableModules', \@modules );
    return $rs if $rs;

    for (@modules) {
        next unless -f "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/$_.load";
        $rs = execute( [ 'a2enmod', $_ ], \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;
        $self->{'restart'} = 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdEnableModules', @modules );
}

=item disableModules(@modules)

 Disable the given Apache modules

 Param array @modules List of modules to disable
 Return int 0 on sucess, other on failure

=cut

sub disableModules
{
    my ($self, @modules) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDisableModules', \@modules );
    return $rs if $rs;

    for (@modules) {
        next unless -l "$self->{'config'}->{'HTTPD_MODS_ENABLED_DIR'}/$_.load";
        $rs = execute( [ 'a2dismod', $_ ], \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;
        $self->{'restart'} = 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdDisableModules', @modules );
}

=item enableConfs(@conffiles)

 Enable the given configuration files

 Param array @conffiles List of configuration files to enable
 Return int 0 on sucess, other on failure

=cut

sub enableConfs
{
    my ($self, @conffiles) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdEnableConfs', \@conffiles );
    return $rs if $rs;

    if (iMSCP::ProgramFinder::find( 'a2enconf' ) && -d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
        for (@conffiles) {
            unless (-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/$_") {
                warning( sprintf( "Configuration file %s doesn't exists", $_ ) );
                next;
            }

            my $rs = execute( [ 'a2enconf', $_ ], \ my $stdout, \ my $stderr );
            debug( $stdout ) if $stdout;
            error( $stderr ) if $stderr && $rs;
            return $rs if $rs;
            $self->{'restart'} = 1;
        }
    }

    $self->{'eventManager'}->trigger( 'afterHttpdEnableConfs', @conffiles );
}

=item disableConfs(@conffiles)

 Disable the given configuration files

 Param array @conffiles Lilst of configuration files to disable
 Return int 0 on sucess, other on failure

=cut

sub disableConfs
{
    my ($self, @conffiles) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdDisableConfs', \@conffiles );
    return $rs if $rs;

    if (iMSCP::ProgramFinder::find( 'a2disconf' ) && -d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
        for (@conffiles) {
            next unless -f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/$_";
            my $rs = execute( [ 'a2disconf', $_ ], \ my $stdout, \ my $stderr );
            debug( $stdout ) if $stdout;
            error( $stderr ) if $stderr && $rs;
            return $rs if $rs;
            $self->{'restart'} = 1;
        }
    }

    $self->{'eventManager'}->trigger( 'afterHttpdDisableConfs', @conffiles );
}

=item forceRestartApache()

 Force Apache to be restarted

 Return int 0

=cut

sub forceRestart
{
    my $self = shift;

    $self->{'forceRestart'} = 1;
    0;
}

=item startApache()

 Start httpd service

 Return int 0 on success, other on failure

=cut

sub start
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdStart' );
    return $rs if $rs;

    local $@;
    eval { iMSCP::Service->getInstance()->start( $self->{'config'}->{'HTTPD_SNAME'} ); };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdStart' );
}

=item stopApache()

 Stop httpd service

 Return int 0 on success, other on failure

=cut

sub stop
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdStop' );
    return $rs if $rs;

    local $@;
    eval { iMSCP::Service->getInstance()->stop( $self->{'config'}->{'HTTPD_SNAME'} ); };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdStop' );
}

=item restartApache()

 Restart or reload httpd service

 Return int 0 on success, other on failure

=cut

sub restart
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdRestart' );
    return $rs if $rs;

    local $@;
    eval {
        if ($self->{'forceRestart'}) {
            iMSCP::Service->getInstance()->restart( $self->{'config'}->{'HTTPD_SNAME'} );
        } else {
            iMSCP::Service->getInstance()->reload( $self->{'config'}->{'HTTPD_SNAME'} );
        }
    };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterHttpdRestart' );
}

=item mountLogsFolder(\%data)

 Mount logs folder which belong to the given domain into customer's logs folder

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub mountLogsFolder
{
    my ($self, $data) = @_;

    my $fsSpec = File::Spec->canonpath( "$self->{'config'}->{'HTTPD_LOG_DIR'}/$data->{'DOMAIN_NAME'}" );
    my $fsFile = File::Spec->canonpath( "$data->{'HOME_DIR'}/logs/$data->{'DOMAIN_NAME'}" );
    my $fields = { fs_spec => $fsSpec, fs_file => $fsFile, fs_vfstype => 'none', fs_mntops => 'bind' };
    my $rs = $self->{'eventManager'}->trigger( 'beforeMountLogsFolder', $data, $fields );
    $rs ||= iMSCP::Dir->new( dirname => $fsFile )->make();
    $rs ||= addMountEntry( "$fields->{'fs_spec'} $fields->{'fs_file'} $fields->{'fs_vfstype'} $fields->{'fs_mntops'}" );
    $rs ||= mount( $fields ) unless isMountpoint( $fields->{'fs_file'} );
    $rs ||= $self->{'eventManager'}->trigger( 'afterMountLogsFolder', $data, $fields );
}

=item umountLogsFolder(\%data)

 Umount logs folder which belong to the given domain from customer's logs folder

 Note: In case of a partial path, any file systems below this path will be umounted.

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub umountLogsFolder
{
    my ($self, $data) = @_;

    # If domain type is 'dmn' (full account) we operate recursively to handle case of dangling mounts
    my $fsFile = File::Spec->canonpath(
        "$data->{'HOME_DIR'}/logs".($data->{'DOMAIN_TYPE'} ne 'dmn' ? "/$data->{'DOMAIN_NAME'}" : '')
    );
    my $rs = $self->{'eventManager'}->trigger( 'beforeUnmountLogsFolder', $data, $fsFile );
    $rs ||= removeMountEntry( qr%.*?[ \t]+\Q$fsFile\E(?:/|[ \t]+)[^\n]+% );
    $rs ||= umount( $fsFile );
    $rs ||= $self->{'eventManager'}->trigger( 'afterUmountMountLogsFolder', $data, $fsFile );
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::httpd::apache_itk

=cut

sub _init
{
    my $self = shift;

    $self->{'start'} = 0;
    $self->{'restart'} = 0;
    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'apacheCfgDir'} = "$main::imscpConfig{'CONF_DIR'}/apache";
    $self->{'apacheTplDir'} = "$self->{'apacheCfgDir'}/parts";
    $self->{'config'} = lazy
        {
            tie my %c, 'iMSCP::Config', fileName => "$self->{'apacheCfgDir'}/apache.data";
            \%c;
        };
    $self->{'phpCfgDir'} = "$main::imscpConfig{'CONF_DIR'}/php";
    $self->{'phpConfig'} = lazy
        {
            tie my %c, 'iMSCP::Config', fileName => "$self->{'phpCfgDir'}/php.data";
            \%c;
        };
    $self->{'eventManager'}->register( 'afterHttpdBuildConfFile', sub { $self->_cleanTemplate( @_ )} );
    $self;
}

=item _addCfg(\%data)

 Add configuration files for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub _addCfg
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddCfg', $data );
    return $rs if $rs;

    $self->setData( $data );

    my $net = iMSCP::Net->getInstance();
    my $isApache24 = version->parse( "$self->{'config'}->{'HTTPD_VERSION'}" ) >= version->parse( '2.4.0' );

    my @domainIPs = ($data->{'BASE_SERVER_IP'}, $data->{'DOMAIN_IP'});
    $rs = $self->{'eventManager'}->trigger( 'onAddHttpdVhostIps', $data, \@domainIPs );
    return $rs if $rs;

    # Remove duplicate IP if any
    @domainIPs = uniq( map { $net->normalizeAddr( $_ ) } @domainIPs );

    $self->setData(
        {
            BASE_SERVER_VHOST      => $data->{'BASE_SERVER_VHOST'},
            HTTPD_LOG_DIR          => $self->{'config'}->{'HTTPD_LOG_DIR'},
            HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'},
            AUTHZ_ALLOW_ALL        => $isApache24 ? 'Require all granted' : 'Allow from all',
            AUTHZ_DENY_ALL         => $isApache24 ? 'Require all denied' : 'Deny from all',
            DOMAIN_IPS             => join(' ', map { ($net->getAddrVersion( $_ ) eq 'ipv4' ? $_ : "[$_]") . ':80' } @domainIPs)
        }
    );

    # Create http vhost

    if ($data->{'HSTS_SUPPORT'}) {
        $self->setData(
            {
                FORWARD      => "https://$data->{'DOMAIN_NAME'}/",
                FORWARD_TYPE => '301'
            }
        );
    }

    $rs = $self->buildConfFile(
        "$self->{'apacheTplDir'}/".(($data->{'HSTS_SUPPORT'} || $data->{'FORWARD'} ne 'no') ? 'domain_redirect.tpl' : 'domain.tpl'),
        $data,
        { destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
    );
    $rs ||= $self->enableSites( "$data->{'DOMAIN_NAME'}.conf" );
    return $rs if $rs;

    # Create https vhost (or delete it if SSL is disabled)

    if ($data->{'SSL_SUPPORT'}) {
        $self->setData(
            {
                CERTIFICATE  => "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$data->{'DOMAIN_NAME'}.pem",
                DOMAIN_IPS   => join(' ', map { ($net->getAddrVersion( $_ ) eq 'ipv4' ? $_ : "[$_]") . ':443' } @domainIPs),
                FORWARD      => $data->{'FORWARD'},
                FORWARD_TYPE => $data->{'FORWARD_TYPE'}
            }
        );
        $rs = $self->buildConfFile(
            "$self->{'apacheTplDir'}/".($data->{'FORWARD'} ne 'no' ? 'domain_redirect_ssl.tpl' : 'domain_ssl.tpl'),
            $data,
            { destination => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf" }
        );
        $rs ||= $self->enableSites( "$data->{'DOMAIN_NAME'}_ssl.conf" );
        return $rs if $rs;
    } elsif (-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf") {
        $rs = $self->disableSites( "$data->{'DOMAIN_NAME'}_ssl.conf" );
        $rs ||= iMSCP::File->new(
            filename => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf"
        )->delFile();
        return $rs if $rs;
    }

    unless (-f "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf") {
        $rs = $self->buildConfFile(
            "$self->{'apacheTplDir'}/custom.conf.tpl",
            $data,
            { destination => "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
        );
    }

    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddCfg' );
}

=item _dmnFolders(\%data)

 Get Web folders list to create for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return array List of Web folders to create

=cut

sub _dmnFolders
{
    my ($self, $data) = @_;

    my @folders = ();

    $self->{'eventManager'}->trigger( 'beforeHttpdDmnFolders', \@folders );
    push(
        @folders,
        [
            "$self->{'config'}->{'HTTPD_LOG_DIR'}/$data->{'DOMAIN_NAME'}",
            $main::imscpConfig{'ROOT_USER'},
            $main::imscpConfig{'ROOT_GROUP'},
            0755
        ]
    );
    $self->{'eventManager'}->trigger( 'afterHttpdDmnFolders', \@folders );
    @folders;
}

=item _addFiles(\%data)

 Add default directories and files for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0 on sucess, other on failure

=cut

sub _addFiles
{
    my ($self, $data) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforeHttpdAddFiles', $data );
    return $rs if $rs;

    for ($self->_dmnFolders( $data )) {
        $rs = iMSCP::Dir->new( dirname => $_->[0] )->make( { user => $_->[1], group => $_->[2], mode => $_->[3] } );
        return $rs if $rs;
    }

    if ($data->{'DOMAIN_TYPE'} eq 'dmn' || $data->{'FORWARD'} eq 'no') {
        # Whether or not permissions must be fixed recursively
        my $fixPermissions = iMSCP::Getopt->fixPermissions;

        # Prepare Web folder
        my $skelDir;
        if ($data->{'DOMAIN_TYPE'} eq 'dmn') {
            $skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/domain";
        } elsif ($data->{'DOMAIN_TYPE'} eq 'als') {
            $skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/alias";
        } else {
            $skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/subdomain";
        }

        my $tmpDir = File::Temp->newdir();
        $rs = execute( "cp -RT $skelDir $tmpDir", \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;

        if ($data->{'FORWARD'} eq 'no') {
            # Build default page if needed (if htdocs doesn't exists or is empty)
            if (!-d "$data->{'WEB_DIR'}/htdocs"
                || iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/htdocs" )->isEmpty()
            ) {
                if (-d "$tmpDir/htdocs") {
                    # Test needed in case admin removed the index.html file from the skeleton
                    if (-f "$tmpDir/htdocs/index.html") {
                        my $fileSource = "$tmpDir/htdocs/index.html";
                        $rs = $self->buildConfFile( $fileSource, $data, { destination => $fileSource } );
                        return $rs if $rs;
                    }
                } else {
                    error( "Web folder skeleton must provides the `htdocs' directory." );
                    return 1;
                }

                # Force recursive permissions for newly created Web folders
                $fixPermissions = 1;
            } else {
                $rs = iMSCP::Dir->new( dirname => "$tmpDir/htdocs" )->remove();
                return $rs if $rs;
            }
        } else { # Remove unwanted files/directories for forwarded dmn
            for(iMSCP::Dir->new( dirname => $tmpDir )->getAll()) {
                next if /^(?:backups|errors|logs|\.htgroup|\.htpasswd|phptmp)$/;
                if (-f "$tmpDir/$_") {
                    $rs = iMSCP::File->new( filename => "$tmpDir/$_" )->delFile();
                } else {
                    $rs = iMSCP::Dir->new( dirname => "$tmpDir/$_" )->remove();
                    return $rs if $rs;
                }
            }
        }

        if ($data->{'DOMAIN_TYPE'} eq 'dmn') {
            if (-d "$data->{'WEB_DIR'}/errors"
                && !iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/errors" )->isEmpty()
            ) {
                $rs = iMSCP::Dir->new( dirname => "$tmpDir/errors" )->remove();
                return $rs if $rs;
            } elsif (!-d "$tmpDir/errors") {
                error( "The `domain' Web folder skeleton must provides the `errors' directory." );
                return 1;
            } else {
                $fixPermissions = 1;
            }

            if ($self->{'config'}->{'MOUNT_CUSTOMER_LOGS'} ne 'yes') {
                $rs = $self->umountLogsFolder( $data );
                $rs ||= iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/logs" )->remove();
                $rs ||= iMSCP::Dir->new( dirname => "$tmpDir/logs" )->remove();
                return $rs if $rs;
            } elsif (!-d "$tmpDir/logs") {
                error( "The `domain' Web folder skeleton must provides the `logs' directory." );
                return 1;
            }
        }

        my $parentDir = dirname( $data->{'WEB_DIR'} );

        # Fix #IP-1327 - Ensure that parent Web folder exists
        unless (-d $parentDir) {
            clearImmutable( dirname( $parentDir ) );
            $rs = iMSCP::Dir->new( dirname => $parentDir )->make(
                { user => $data->{'USER'}, group => $data->{'GROUP'}, mode => 0750 }
            );
            return $rs if $rs;
        } else {
            clearImmutable( $parentDir );
        }

        clearImmutable( $data->{'WEB_DIR'} ) if -d $data->{'WEB_DIR'};

        # Copy Web folder

        $rs = execute( "cp -nRT $tmpDir $data->{'WEB_DIR'}", \ $stdout, \ $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr ) if $stderr && $rs;
        return $rs if $rs;

        # Cleanup (Transitional)

        if ($data->{'DOMAIN_TYPE'} eq 'dmn') {
            # Remove deprecated `domain_disable_page' directory if any
            $rs = iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/domain_disable_page" )->remove();
            return $rs if $rs;
        } elsif (!$data->{'SHARED_MOUNT_POINT'}) {
            # Remove deprecated phptmp directory if any
            $rs = iMSCP::Dir->new( dirname => "$data->{'WEB_DIR'}/phptmp" )->remove();
            $rs ||= iMSCP::Dir->new( dirname => "$tmpDir/phptmp" )->remove();
            return $rs if $rs;
        }

        # Fix permissions

        # Fix user/group and mode for root Web folder
        # root Web folder vuxxx:vuxxx 0750 (no recursive)
        $rs = setRights( $data->{'WEB_DIR'}, { user => $data->{'USER'}, group => $data->{'GROUP'}, mode => '0750' } );
        return $rs if $rs;

        # Get list of directories/files (firt depth only)
        my @files = iMSCP::Dir->new( dirname => $skelDir )->getAll();

        # Fix user/group for first Web folder depth, e.g:
        # 00_private           vuxxx:vuxxx (recursive with --fix-permissions)
        # backups              vuxxx:vuxxx (recursive with --fix-permissions)
        # cgi-bin              vuxxx:vuxxx (recursive with --fix-permissions)
        # error                vuxxx:vuxxx (recursive with --fix-permissions)
        # htdocs               vuxxx:vuxxx (recursive with --fix-permissions)
        # .htgroup             skipped
        # .htpasswd            skipped
        # logs                 skipped
        # phptmp               vuxxx:vuxxx (recursive with --fix-permissions)
        for my $file(@files) {
            next if $file =~ /^(?:\.htgroup|\.htpasswd|logs)$/ || !-e "$data->{'WEB_DIR'}/$file";
            $rs = setRights(
                "$data->{'WEB_DIR'}/$file",
                { user => $data->{'USER'}, group => $data->{'GROUP'}, recursive => $fixPermissions }
            );
            return $rs if $rs;
        }

        # Fix dirmode/filemode for first Web folder depth, e.g:
        # 00_private           0750 (no recursive)
        # backups              0750 (recursive with --fix-permissions)
        # cgi-bin              0750 (no recursive)
        # error                0750 (recursive with --fix-permissions)
        # htdocs               0750 (no recursive)
        # .htgroup             0640
        # .htpasswd            0640
        # logs                 skipped
        # phptmp               0750 (recursive with --fix-permissions)
        for my $file (@files) {
            next if $file eq 'logs' || !-e "$data->{'WEB_DIR'}/$file";
            $rs = setRights(
                "$data->{'WEB_DIR'}/$file",
                {
                    dirmode   => '0750',
                    filemode  => '0640',
                    recursive => $file =~ /^(?:00_private|cgi-bin|htdocs)$/ ? 0 : $fixPermissions
                }
            );
            return $rs if $rs;
        }

        # Fix user/group for .htgroup and .htpasswd files
        # .htgroup             root:www-data
        # .htpasswd            root:www-data
        for my $file('.htgroup', '.htpasswd') {
            next unless -e "$data->{'WEB_DIR'}/$file";
            $rs = setRights(
                "$data->{'WEB_DIR'}/$file",
                { user => $main::imscpConfig{'ROOT_USER'}, group => $self->{'config'}->{'HTTPD_GROUP'}, recursive => 1 }
            );
            return $rs if $rs;
        }

        if ($data->{'DOMAIN_TYPE'} eq 'dmn' && -d "$data->{'WEB_DIR'}/logs") {
            # Fix user/group and mode for logs directory
            # logs root:vuxxx 0750 (no recursive)
            $rs = setRights(
                "$data->{'WEB_DIR'}/logs",
                { user => $main::imscpConfig{'ROOT_USER'}, group => $data->{'GROUP'}, mode => '0750' }
            );
            return $rs if $rs;
        }

        if ($data->{'WEB_FOLDER_PROTECTION'} eq 'yes') {
            my $dir = $data->{'WEB_DIR'};
            my $userWebDir = File::Spec->canonpath( $main::imscpConfig{'USER_WEB_DIR'} );
            do { setImmutable( $dir ); } while (($dir = dirname( $dir )) ne $userWebDir);
        }
    }

    $rs = $self->mountLogsFolder( $data ) if $self->{'config'}->{'MOUNT_CUSTOMER_LOGS'} eq 'yes';
    $rs ||= $self->{'eventManager'}->trigger( 'afterHttpdAddFiles', $data );
}

=item _cleanTemplate(\$cfgTpl, $filename, \%data)

 Event listener which is responsible to remove useless configuration snippets in vhost template files

 Param string \$cfgTpl Template content
 Param string $filename Template filename
 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0

=cut

sub _cleanTemplate
{
    my ($self, $cfgTpl, $filename, $data) = @_;

    if ($filename =~ /^domain(?:_ssl)?\.tpl$/) {
        $$cfgTpl = replaceBloc( "# SECTION suexec BEGIN.\n", "# SECTION suexec END.\n", '', $$cfgTpl );

        unless ($data->{'CGI_SUPPORT'} eq 'yes') {
            $$cfgTpl = replaceBloc( "# SECTION cgi_support BEGIN.\n", "# SECTION cgi_support END.\n", '', $$cfgTpl );
        }

        if ($data->{'PHP_SUPPORT'} eq 'yes') {
            $$cfgTpl = replaceBloc( "# SECTION php_disabled BEGIN.\n", "# SECTION php_disabled END.\n", '', $$cfgTpl );
        } else {
            $$cfgTpl = replaceBloc( "# SECTION php_enabled BEGIN.\n", "# SECTION php_enabled END.\n", '', $$cfgTpl );
        }

        $$cfgTpl = replaceBloc( "# SECTION fcgid BEGIN.\n", "# SECTION fcgid END.\n", '', $$cfgTpl );
        $$cfgTpl = replaceBloc( "# SECTION php_fpm BEGIN.\n", "# SECTION php_fpm END.\n", '', $$cfgTpl );
    }

    if ($filename =~ /^domain(?:_disabled|_redirect)?(_ssl)?\.tpl$/) {
        my $isSSLVhost = defined $1;

        if ($data->{'FORWARD'} ne 'no') {
            if ($data->{'FORWARD_TYPE'} eq 'proxy' && (!$data->{'HSTS_SUPPORT'} || $isSSLVhost)) {
                $$cfgTpl = replaceBloc(
                    "# SECTION standard_redirect BEGIN.\n", "# SECTION standard_redirect END.\n", '', $$cfgTpl
                );
                if ($data->{'FORWARD'} !~ /^https/) {
                    $$cfgTpl = replaceBloc("# SECTION ssl_proxy BEGIN.\n", "# SECTION ssl_proxy END.\n", '', $$cfgTpl);
                }
            } else {
                $$cfgTpl = replaceBloc(
                    "# SECTION proxy_redirect BEGIN.\n", "# SECTION proxy_redirect END.\n", '', $$cfgTpl
                );
            }
        } else {
            $$cfgTpl = replaceBloc(
                "# SECTION proxy_redirect BEGIN.\n", "# SECTION proxy_redirect END.\n", '', $$cfgTpl
            );
        }

        if ($isSSLVhost && !$data->{'HSTS_SUPPORT'}) {
            $$cfgTpl = replaceBloc( "# SECTION hsts BEGIN.\n", "# SECTION hsts END.\n", '', $$cfgTpl );
        }
    }

    $$cfgTpl =~ s/^[ \t]+#.*?(?:BEGIN|END)\.\n//gim;
    $$cfgTpl =~ s/\n{3}/\n\n/g;
    0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
