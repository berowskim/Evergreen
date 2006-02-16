package OpenILS::Application::Circ;
use base qw/OpenSRF::Application/;
use strict; use warnings;

use OpenILS::Application::Circ::Circulate;
use OpenILS::Application::Circ::Rules;
use OpenILS::Application::Circ::Survey;
use OpenILS::Application::Circ::StatCat;
use OpenILS::Application::Circ::Holds;
use OpenILS::Application::Circ::Money;
use OpenILS::Application::Circ::NonCat;
use OpenILS::Application::Circ::CopyLocations;

use OpenILS::Application::AppUtils;
my $apputils = "OpenILS::Application::AppUtils";
my $U = $apputils;
use OpenSRF::Utils;
use OpenILS::Utils::ModsParser;
use OpenILS::Event;
use OpenSRF::EX qw(:try);
use OpenSRF::Utils::Logger qw(:logger);
#my $logger = "OpenSRF::Utils::Logger";


# ------------------------------------------------------------------------
# Top level Circ package;
# ------------------------------------------------------------------------

sub initialize {
	my $self = shift;
	OpenILS::Application::Circ::Rules->initialize();
	OpenILS::Application::Circ::Circulate->initialize();
}


# ------------------------------------------------------------------------
# Returns an array of {circ, record} hashes checked out by the user.
# ------------------------------------------------------------------------
__PACKAGE__->register_method(
	method	=> "checkouts_by_user",
	api_name	=> "open-ils.circ.actor.user.checked_out",
	NOTES		=> <<"	NOTES");
	Returns a list of open circulations as a pile of objects.  each object
	contains the relevant copy, circ, and record
	NOTES

sub checkouts_by_user {
	my( $self, $client, $user_session, $user_id ) = @_;

	my( $requestor, $target, $copy, $record, $evt );

	( $requestor, $target, $evt ) = 
		$apputils->checkses_requestor( $user_session, $user_id, 'VIEW_CIRCULATIONS');
	return $evt if $evt;

	my $circs = $apputils->simplereq(
		'open-ils.storage',
		"open-ils.storage.direct.action.open_circulation.search.atomic", 
		{ usr => $target->id, checkin_time => undef } );
#		{ usr => $target->id } );

	my @results;
	for my $circ (@$circs) {

		( $copy, $evt )  = $apputils->fetch_copy($circ->target_copy);
		return $evt if $evt;

		$logger->debug("Retrieving record for copy " . $circ->target_copy);

		($record, $evt) = $apputils->fetch_record_by_copy( $circ->target_copy );
		return $evt if $evt;

		my $mods = $apputils->record_to_mvr($record);

		push( @results, { copy => $copy, circ => $circ, record => $mods } );
	}

	return \@results;

}



__PACKAGE__->register_method(
	method	=> "checkouts_by_user_slim",
	api_name	=> "open-ils.circ.actor.user.checked_out.slim",
	NOTES		=> <<"	NOTES");
	Returns a list of open circulation objects
	NOTES

sub checkouts_by_user_slim {
	my( $self, $client, $user_session, $user_id ) = @_;

	my( $requestor, $target, $copy, $record, $evt );

	( $requestor, $target, $evt ) = 
		$apputils->checkses_requestor( $user_session, $user_id, 'VIEW_CIRCULATIONS');
	return $evt if $evt;

	$logger->debug( 'User ' . $requestor->id . 
		" retrieving checked out items for user " . $target->id );

	# XXX Make the call correct..
	return $apputils->simplereq(
		'open-ils.storage',
		"open-ils.storage.direct.action.open_circulation.search.atomic", 
		{ usr => $target->id, checkin_time => undef } );
#		{ usr => $target->id } );
}




__PACKAGE__->register_method(
	method	=> "title_from_transaction",
	api_name	=> "open-ils.circ.circ_transaction.find_title",
	NOTES		=> <<"	NOTES");
	Returns a mods object for the title that is linked to from the 
	copy from the hold that created the given transaction
	NOTES

sub title_from_transaction {
	my( $self, $client, $login_session, $transactionid ) = @_;

	my( $user, $circ, $title, $evt );

	( $user, $evt ) = $apputils->checkses( $login_session );
	return $evt if $evt;

	( $circ, $evt ) = $apputils->fetch_circulation($transactionid);
	return $evt if $evt;
	
	($title, $evt) = $apputils->fetch_record_by_copy($circ->target_copy);
	return $evt if $evt;

	return $apputils->record_to_mvr($title);
}


__PACKAGE__->register_method(
	method	=> "set_circ_lost",
	api_name	=> "open-ils.circ.circulation.set_lost",
	NOTES		=> <<"	NOTES");
	Params are login, circid
	login must have SET_CIRC_LOST perms
	Sets a circulation to lost
	NOTES

__PACKAGE__->register_method(
	method	=> "set_circ_lost",
	api_name	=> "open-ils.circ.circulation.set_claims_returned",
	NOTES		=> <<"	NOTES");
	Params are login, circid
	login must have SET_CIRC_MISSING perms
	Sets a circulation to lost
	NOTES

sub set_circ_lost {
	my( $self, $client, $login, $circid ) = @_;
	my( $user, $circ, $evt );

	( $user, $evt ) = $apputils->checkses($login);
	return $evt if $evt;

	( $circ, $evt ) = $apputils->fetch_circulation( $circid );
	return $evt if $evt;

	if($self->api_name =~ /lost/) {
		if($evt = $apputils->checkperms(
			$user->id, $circ->circ_lib, "SET_CIRC_LOST")) {
			return $evt;
		}
		$circ->stop_fines("LOST");		
	}

	# XXX Back date the checkin time so the patron has no fines
	if($self->api_name =~ /claims_returned/) {
		if($evt = $apputils->checkperms(
			$user->id, $circ->circ_lib, "SET_CIRC_CLAIMS_RETURNED")) {
			return $evt;
		}
		$circ->stop_fines("CLAIMSRETURNED");
	}

	my $s = $apputils->simplereq(
		'open-ils.storage',
		"open-ils.storage.direct.action.circulation.update", $circ );

	if(!$s) { throw OpenSRF::EX::ERROR ("Error updating circulation with id $circid"); }
}

__PACKAGE__->register_method(
	method		=> "create_in_house_use",
	api_name		=> 'open-ils.circ.in_house_use.create',
	signature	=>	q/
		Creates an in-house use action.
		@param $authtoken The login session key
		@param params A hash of params including
			'location' The org unit id where the in-house use occurs
			'copyid' The copy in question
			'count' The number of in-house uses to apply to this copy
		@return An array of id's representing the id's of the newly created
		in-house use objects or an event on an error
	/);

sub create_in_house_use {
	my( $self, $client, $authtoken, $params ) = @_;

	my( $staff, $evt, $copy );
	my $org		= $params->{location};
	my $copyid	= $params->{copyid};
	my $count	= $params->{count} || 1;

	($staff, $evt) = $U->checkses($authtoken);
	return $evt if $evt;

	($copy, $evt) = $U->fetch_copy($copyid);
	return $evt if $evt;

	$evt = $U->check_perms($staff->id, $org, 'CREATE_IN_HOUSE_USE');
	return $evt if $evt;

	$logger->activity("User " . $staff->id .
		" creating $count in-house use(s) for copy $copyid at location $org");

	my @ids;
	for(1..$count) {
		my $ihu = Fieldmapper::action::in_house_use->new;

		$ihu->item($copyid);
		$ihu->staff($staff->id);
		$ihu->org_unit($org);
		$ihu->use_time('now');

		my $id = $U->simplereq(
			'open-ils.storage',
			'open-ils.storage.direct.action.in_house_use.create', $ihu );

		return $U->DB_UPDATE_FAILED($ihu) unless $id;
		push @ids, $id;
	}

	return \@ids;
}



__PACKAGE__->register_method(
	method	=> "view_circ_patrons",
	api_name	=> "open-ils.circ.copy_checkout_history.retrieve",
	notes		=> q/
		Retrieves the last X users who checked out a given copy
		@param authtoken The login session key
		@param copyid The copy to check
		@param count How far to go back in the item history
		@return An array of patron ids
	/);

sub view_circ_patrons {
	my( $self, $client, $authtoken, $copyid, $count ) = @_; 

	my( $requestor, $evt ) = $U->checksesperm(
			$authtoken, 'VIEW_COPY_CHECKOUT_HISTORY' );
	return $evt if $evt;

	return [] unless $count;

	my $circs = $U->storagereq(
		'open-ils.storage.direct.action.circulation.search_where.atomic',
			{ target_copy => $copyid  }, { limit => $count, order_by => "xact_start DESC" } );

	my @users;
	push(@users, $_->usr) for @$circs;
	return \@users;
}


1;
