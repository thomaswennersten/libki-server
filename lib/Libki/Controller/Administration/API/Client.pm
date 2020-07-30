package Libki::Controller::Administration::API::Client;
use Moose;
use namespace::autoclean;
use Libki::Clients qw( wakeonlan );

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Libki::Controller::Administration::API::Client - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

=head2 modify_time

Client API that updates a user's session minutes.

The param 'minutes' can be an integer to replace the existing minutes.
If the number is prepended with a '+' or '-' the number will be added
or subtracted from the existing session minutes respectively.

=cut

sub modify_time : Local : Args(0) {
    my ( $self, $c ) = @_;

    my $success = 0;

    my $client_id = $c->request->params->{'id'};
    my $minutes   = $c->request->params->{'minutes'};

    my $client = $c->model('DB::Client')->find($client_id);

    if ( $client && $client->session ) {
        my $session = $client->session;

        if ( $minutes =~ /^[+-]/ ) {
            $minutes = $session->minutes + $minutes;
        }

        $minutes = 0 if ( $minutes < 0 );

        $success = 1 if $session->update( { minutes => $minutes } );
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 logout

Logs a user out and deletes the session for storage.

=cut

sub logout : Local : Args(1) {
    my ( $self, $c, $client_id ) = @_;
    my $success = 0;

    my $client = $c->model('DB::Client')->find($client_id);

    if ( defined($client) && defined( $client->session ) ) {
        if ( $client->session->delete() ) {
            $success = 1;
        }
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 unlock

Unlocks a client by creating a session for a guest account.

=cut

sub unlock : Local : Args(1) {
    my ( $self, $c, $client_id ) = @_;

    my $success = 0;
    my $client = $c->model('DB::Client')->find($client_id);

    if ( defined($client) && $client->status eq 'online' && ! defined( $client->session ) ) {
        # get guest user for this client
        my $prefix_setting = $c->setting('GuestPassPrefix');
        my $prefix = $prefix_setting || 'guest';

        my $username = $prefix . "_" . $client->name;
        my $user = $c->model('DB::User')->find( { username => $username } );

        unless ( $user ) {
            my $password = String::Random::random_string("nnnn");
            my $now = $c->now();

            $user = $c->model('DB::User')->create(
                {
                    instance          => $c->instance,
                    username          => $username,
                    password          => $password,
                    status            => 'enabled',
                    is_guest          => 'Yes',
                    created_on        => $now,
                    updated_on        => $now,
                }
            );
        }

        # reset allowance and calculate session time
        my $advanced_rule = $c->get_rule(
            {
                rule            => 'guest_daily',
                client_location => $client->location,
                client_type     => $client->type,
                client_name     => $client->name,
                client_type     => $client->type,
                user_category   => $user->category,
            }
        );

        my $minutes_allotment = $advanced_rule if ( defined $advanced_rule );
        $minutes_allotment = $c->setting('DefaultGuestTimeAllowance') unless ( defined( $minutes_allotment ) );

        $c->model('DB::Allotment')->update_or_create(
            {
                instance => $c->instance,
                user_id  => $user->id,
                location => ( $c->setting('TimeAllowanceByLocation') && defined($client->location) ) ? $client->location : '',
                minutes  => $minutes_allotment,
            }
        );

        my %result = $c->check_login($client,$user);

        # create session
        if ( ! $result{'error'} && $result{'minutes'} > 0 ) {
            my $session_id = $c->sessionid;
            my $session = $c->model('DB::Session')->create(
                {
                    instance   => $c->instance,
                    user_id    => $user->id,
                    client_id  => $client->id,
                    status     => 'active',
                    minutes    => $result{'minutes'},
                    session_id => $session_id,
                }
            );

            if ( $session ) {
                $client->update( { status => 'unlock' } );
                $success = 1;

                $c->model('DB::Statistic')->create(
                    {
                        instance        => $c->instance,
                        username        => $c->user->username,
                        client_name     => $client->name,
                        client_location => $client->location,
                        client_type     => $client->type,
                        action          => 'UNLOCK',
                        created_on      => $c->now,
                        session_id      => $session_id,
                    }
                );
            }
        }
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 reservation

Creates or cancels a reservation for the given client and user.

=cut

sub reservation : Local : Args(1) {
    my ( $self, $c, $client_id ) = @_;

    my $client = $c->model('DB::Client')->find($client_id);

    my $instance = $c->instance;
    my $action    = $c->request->params->{action}   || q{};
    my $username  = $c->request->params->{username} || q{};
    my $user = $c->model('DB::User')->single( { instance => $instance, username => $username } );

    if ( !$user ) {
        my $config = $c->instance_config;

        if ( $config->{SIP}->{enable} ) {
            my $ret = Libki::SIP::authenticate_via_sip( $c, $user, $username, my $password = undef, my $test_mode = 0, my $admin_auth = 1 );
            $user = $ret->{user} if $ret->{success};
        }
        elsif ( $config->{LDAP}->{enable} ) {
            #TODO: Add the same ability to force create a user as long as the user exists if we don't have the users password, as we do for SIP
            #my $ret = Libki::LDAP::authenticate_via_ldap( $c, $user, $username, q{} );
        }
    }

    my $reservation = undef;
    if ( $user ) {
        $reservation =  $c->model('DB::Reservation')->find({ user_id => $user->id,client_id => $client_id});
    }
    else {
        $c->stash( 'success' => 0, 'reason' => 'INVALID_USER');
    }

    if ( $action eq 'reserve' && $user) {
        if( !$reservation ) {
            my $begin_time = $c->request->params->{'reservation_date'}.' '
                                                  .$c->request->params->{'reservation_hour'}.':'
                                                  .$c->request->params->{'reservation_minute'}.':00';

            my %check = $c->check_reservation($client,$user,$begin_time);

            if($check{'error'}) {
                $c->stash( 'success' => 0, 'reason' => $check{'error'}, 'detail' => $check{'detail'} );
            }
            else {
                $c->model('DB::Reservation')->create( {
                                                        instance   => $instance,
                                                        user_id    => $user->id,
                                                        client_id  => $client_id,
                                                        begin_time => $begin_time,
                                                        end_time   => $check{'end_time'}
                                                    } );
                $c->stash( 'success' => 1 );
            }
        }
        else {
           $c->stash( 'success' => 0, 'reason' => 'USER_ALREADY_RESERVED' );
        }
    }
    elsif ( $action eq 'cancel' && $reservation) {
        if( $reservation ) {
           my $success = $reservation->delete() ? 1 : 0;
           $c->stash( success => $success );
        }
        else {
           $c->stash( success => 0 ,'reason' => 'NOTFOUND');
        }
    }
    $c->forward( $c->view('JSON') );
}

=head2 toggle_status

 Switch client status.

=cut

sub toggle_status : Local : Args(1) {
    my ( $self, $c, $id ) = @_;
    my $instance = $c->instance;

    my $success = 0;
    my $client = $c->model('DB::Client')->find({ instance => $instance, id => $id });
    if($client) {
        my $status = ( $client->status eq 'suspended' ) ? 'offline' : 'suspended';
        $client->set_column( 'status', $status );

        if ( $client->update() ) {
            $success = 1;
        }
    }
    $c->stash( 'success' => $success, status => $client->status );
    $c->forward( $c->view('JSON') );
}

=head2 delete_client

 Delete client.

=cut

sub delete_client : Local : Args(1) {
    my ( $self, $c, $id ) = @_;
    my $instance = $c->instance;

    my $success = 0;
    my $client = $c->model('DB::Client')->find({ instance => $instance, id => $id });
    if($client) {
        $c->model('DB::Reservation')->search({ client_id => $id })->delete();
        $success = 1 if ( $client->delete() );
    }
    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 shutdown

Shutdown a specific client by changing it's status.
The status change will send a message to the client to initiate shutdown.

=cut

sub shutdown : Local : Args(1) {
    my ( $self, $c, $client_id ) = @_;

    my $success = 0;
    my $client = $c->model('DB::Client')->find($client_id);
    my $status = $c->setting('ClientShutdownAction') || 'shutdown';

    if ($client->status eq 'online') {
        $success = 1 if $client->update( { status => $status } );
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 restart

Restarts a specific client by changing it's status.
The status change will send a message to the client to initiate reboot.

=cut

sub restart : Local : Args(1) {
    my ( $self, $c, $client_id ) = @_;

    my $success = 0;
    my $client = $c->model('DB::Client')->find($client_id);

    if ($client->status eq 'online') {
        $success = 1 if $client->update( { status => 'restart' } );
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 shutdown_all

Shutdown all clients by changing their statuses.
The status change will send a message to each client to initiate shutdown.

=cut

sub shutdown_all : Local : Args(0) {
    my ( $self, $c ) = @_;

    my $success = 0;
    my $clients = $c->model('DB::Client')->search({ instance => $c->instance });
    my $status  = $c->setting('ClientShutdownAction') || 'shutdown';

    while ( my $client = $clients->next() ) {
        if ($client->status eq 'online') {
            $success = 1 if $client->update( { status => $status } );
        }
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 restart_all

Restarts all clients by changing their statuses.
The status change will send a message to each client to initiate reboot.

=cut

sub restart_all : Local : Args(0) {
    my ( $self, $c ) = @_;

    my $success = 0;
    my $clients = $c->model('DB::Client')->search({ instance => $c->instance });

    while ( my $client = $clients->next() ) {
        if ($client->status eq 'online') {
            $success = 1 if $client->update( { status => 'restart' } );
        }
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head2 wakeup

Wake up all clients using wake on lan.

=cut

sub wakeup : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $success = 0;

    my $wol_mode = $c->setting('WOLMode') || "server";
    if ( $wol_mode eq "server" ) {
        $success = Libki::Clients::wakeonlan($c);
    } elsif ( $wol_mode eq "client" ) {
        my $clients = $c->model('DB::Client')->search({ instance => $c->instance });
        while ( my $client = $clients->next() ) {
            if ($client->status eq 'online') {
                $success = 1 if $client->update( { status => 'wakeup' } );
            }
        }
    }

    $c->stash( 'success' => $success );
    $c->forward( $c->view('JSON') );
}

=head1 AUTHOR

Kyle M Hall <kyle@kylehall.info>

=cut

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of 
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the  
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.   

=cut

__PACKAGE__->meta->make_immutable;

1;
