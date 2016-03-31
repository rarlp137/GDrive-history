=for TODO: 
- rewrite APIs in Contextual::Return-style
- implement the try-outs and retry in actual_call()
- strip the globals
- implement stated tie-interface
- add call-queues and expose for further chain-continuation 
- implement stuff w/ patch semantics & return users _and_ document @ rev.
- implement the get_all() wrapper
=cut

package GDrive::API;
use strict;
use warnings;
use diagnostics;
use 5.20.00;
use utf8;
use feature 'state';
#use Carp; # no confessions
#no warnings qw/experimental::autoderef/;
#use feature 'signatures'; no warnings qw/experimental::signatures/;
use Data::Dumper::AutoEncode; 
	$Data::Dumper::AutoEncode::ENCODING='utf8';#4some
use Clone qw(clone);
use Params::Validate qw(:all);
#use Devel::Examine::Subs; # For around monkey-patching, but... nnnewp :/
# ami 2 lazy 2 monkey-patch 't w/ the Dumper::AutoEncode, thus, 'll keep as'tis:
use Tie::Persistent;
# There 'll be a 'humanize' script 4 stripping teh \x{1}-sht 2b more readable
# TODO: include existing humanize-cache.pl right after the tie unties
# use Time::Out qw(timeout); # Mojo's internal timeouts R behaving okay
use Sub::Retry; 
use Try::Tiny;
use Log::Log4perl qw(:easy); # logwarn(), logdie()
Log::Log4perl->easy_init( 
	{ 	level	=> $INFO, # logs: DEBUG, INFO, WARN, ALWAYS, ERROR, FATAL
#		file	=> ">test.log", # overwrite
		file	=> "STDOUT",	utf8	=> 1,
		#category=> "Google::Drive",
		layout	=> "%d  %F{1}:%L\t%M{2}:\t %m%n",
		# log4perl.PatternLayout.cspec.U = sub { return "UID $<" }
#	},{ level    => $WARN, # WARN, ALWAYS, ERROR, FATAL
#		file     => "STDOUT",	category => "",	layout   => '%m%n' 
	},);
use DateTime;
use DateTime::Format::RFC3339; # 'ere, really?
use Time::HiRes qw(time);

use Mojo::JWT::Google;
use Mojo::Collection 'c';
use Mojo::UserAgent;

#use vars qw($Autosync $Readable $BackupFile);

# Init the class variables
our ($jwt, $ua, $auth_key, $call_header) = ();
our %cache = ();
#use Data::Dumper::AutoEncode; # provides eDumper() -- 
# more human-readable than Dumper and w/ utf support
#	$Data::Dumper::AutoEncode::ENCODING = 'utf8'; # Some systems 



# Trivial constructor with  file tieback
sub new { # Not the Schwartzian way, e.g., return __PACKAGE__ }
# Oh, Cheezus...
    my $class =shift;
	my %spec = (
		serial	# for the implementation the multi-instance and async's (later).
			=> { type => SCALAR, optional => 1}, 
		cacheable	# allow the file-cache?
			=> { type => SCALAR, optional => 1, 
						depends => 'cache_file', default => 1},
		cache_file	# file to sore our cache
			=> { type => SCALAR, optional => 1, default => 'cache.txt'},
		readable # setting 'readable' to 0 speedups the cache-file IO ops
			=> {type => SCALAR, optional => 1, default => 1},
		#cache_tactics=> {type => SCALAR, optional => 1, default => 'force'},
	);
	my $args = validate( @_, \%spec );

	if( $args->{cacheable} ){
		my $filename = $args->{cache_file};
		INFO "\t Trying to tie the cache with '$filename'";
		tie %cache, 'Tie::Persistent', $filename, 'rw'; # may chg the flag?
		
		# Check for file IO speeding-up argument
		$Tie::Persistent::Readable = 'true' unless ($args->{readable} == 0);
		# Setting the autosynchronisation
		(tied %cache)->autosync(1);
#		push @{$cache{obj}}, $args if $args->{cacheable}; # no instance pushin'
# TODO: check for defined expiration timing
	};
	# Anyway, return our API object
    my $self = bless { 
#		serial => $args->{serial}, # not'n 'ere -_-
	}, $class;
	return $self;
}


# Initiate the OAuth2.0 session
sub init_session { 
	my $meaningless = shift;
	my %arg = validate( @_, {		
		user	=> { type => SCALAR}, # email of the issuer
		auth_key # provide exogenous authentification key
			=> { type => SCALAR, optional => 1},
		secret_json	# secret-file
			=> { type => SCALAR, optional => 1},
#		readable 	=> {type => SCALAR, optional => 1, default => 1},
#		cache_tactics=> {type => SCALAR, optional => 1, default => 'force'},
	
		target	=> {type => HASHREF, optional => 1 },
		debug	=> { type => SCALAR, optional => 1 },
	} );
	if ( defined $arg{secret_json} ) {
		if ( defined $auth_key || defined $arg{auth_key} ) {
			# Skip the authentification, initiate user-agent
			$ua = Mojo::UserAgent->new;
			INFO "We got an agent!\n";
		} else { # ...if there's no $auth_key nowhere...
			INFO "Trying to get the authorisation...\n";
			$jwt = Mojo::JWT::Google->new( 
				from_json=> $arg{secret_json},#'../secret.json',
				issue_at => time,
				scopes   =>c('https://www.googleapis.com/auth/drive.readonly'),
				user_as	 => $arg{user},
			);
			INFO "Me got the session!\n";
			my $token_request_url=q(https://www.googleapis.com/oauth2/v3/token);
			my $grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

			# Try to obtain the authentification
			$ua = Mojo::UserAgent->new;
			INFO "Me got an agent!\n";
			my $tok_res = $ua->post($token_request_url
				=> form => { grant_type => $grant_type, 
							 assertion => $jwt->encode } )->res;
			INFO "Me got the result!\n";

			my $json = $tok_res->json or die "No authorization provided";
			$auth_key = $json->{token_type} . ' ' . $json->{access_token};
			DEBUG "Me got the Auth: \n\t\"$auth_key\" !\n";
			FATAL "Me won the lotto..." if $@;
		}
	} else {
		WARN "We aint got no authorisation! ...let's work with the cache?";
		return 0;
		# Still, we can work with cache
	}
	# Reinstance existing init state into target with clone($ref)
	%{$arg{target}} = %{clone \%arg} if $arg{target} ; # forgetfull
# TODO: rewrite in Contextual::Return
	return $auth_key; # ...if we want the auth-key
					# ...elseif we may want the user agent
}

# Prepare the request string
sub prepare_request {
	my $meaningless = shift;
	my %arg = validate( @_, {
		site 	=> { default => 'https://www.googleapis.com/drive' },
		version	=> {type => SCALAR, optional => 1, # v2 and v3 both work fine
			default => 'v3'}, # R we waiting 4 v4?
		api		=> {type => SCALAR},# What API are we using?
# TODO: try coercing w/ the hash-way, e.g. {properties => \[], fields => \[],}
		flags	 # call properties
			=> {type => ARRAYREF|UNDEF, optional=>1},
		fields	 # call response fields
			=> {type => ARRAYREF|UNDEF, optional=>1},		

		target	=> {type => HASHREF, optional => 1},
		debug	=> {type => SCALAR, optional => 1, default => ''},
	});#	DEBUG "\tRequest arguments: ", Dumper{%arg};
# TODO: error handling is not implemented!!!
	# Construct the URL base 
	my  $url = $arg{site} .'/'. $arg{version} .'/'. $arg{api} ;
	# Append properties
	if ($arg{flags}) { # ensure flags aren't empty
		$url .= '?' . join('&', @{ $arg{flags}  } ) ;
	}
	# Append fields
	if ($arg{fields}) {
		$url .= ($arg{flags}?'&':'?') . # collate properties/fields separator
			  'fields='.join(',', @{ $arg{fields} } ) ;
	}
	# Reinstance existing call state into target with clone($ref)	
	%{$arg{target}} = %{clone \%arg} if $arg{target} ; # forgetfull

	return $url; 
}



# Perform the actual call
sub actual_call {# consider to have plenty errors
	my %arg = validate( @_, {
		url		=> {type => SCALAR}, # mandatory URI string
		auth_key # context-mandatory authentification key
			=> {type => SCALAR, optional => 
			  # nasty trick to enforce the existing auth key to be required:
			  sub { return defined $auth_key}}, # if no internal, passes 0
		timeout  # call timeout
			=> {type => SCALAR, optional =>1, default => 100},
		attempts # number of attempts
			=> {type => SCALAR, optional =>1, default => 0},

		target	=> {type => HASHREF, optional => 1},
		debug	=> {type => SCALAR, optional => 1, default => ''},
	});
	DEBUG "\tRequest arguments: ", Dumper {%arg};
	
	# Check if we're supplied with some specific auth-key
	if (defined $arg{auth_key}) { 
		$auth_key = $arg{auth_key}; 
		WARN "Using locally-proposed auth_key: $auth_key\n"
	};
	my $tdiff = 0; # onsite, non-integrating!	
	# Initiate the result holder
	my $call_res = ();
	if (defined $auth_key) {
		my $time0 = time;
#			tickle_sub();
		my $url = $arg{url};
		if (defined $arg{timeout}) { # pass the timeout restrictions to UA
			$ua	->connect_timeout($arg{timeout});
			$ua ->request_timeout($arg{timeout});
		};
		# Prepare the authorisation header
		$call_header =  {'Authorization' => $auth_key};
# TODO: Implement the try-outs and retry
		# Do we need to implement retry-times? M/b later...
			#$call_res = retry $arg{attempts}, $arg{pause_btw}, sub {
				#return timeout $arg{time_out} => sub {
				#	return 
				$call_res = $ua->get( $url  => $call_header)->res 
				or FATAL "Can't call $arg{api}-api!\n";
				#	}};

		if ($call_res->{error}) {
# TODO: Implement some error handling here
			DEBUG Dumper $call_res;
			my $error = $call_res->{error};
			ERROR "\nError ", $error->{code}, ": ", 
					$error->{message} || 0, "\n"x2;
		}
		$tdiff = time - $time0;
		DEBUG "Response: ", Dumper $call_res->json;
		INFO "Response took: ", sprintf("%03d",int($tdiff*1000))," msec\n";
	} else {FATAL "No authentification! \n"}
	if (defined $arg{target}) { # don't actually return anything important
		$arg{target} = $call_res->json;
		return "OK, took $tdiff sec."; # ami do want the time?
	} else {
		return $call_res->json;
	};
	#...
}



# Wrapper for cached API. Use it as an API fearlessly, just pushing up 
#	the expiration time & !forget to update the cache sometimes
sub call_api {
# TODO:
# + flatten to wrapper for memoization 
# + add timestamps
# + try not to break the outer calls
# + pledge to work with hashes
# + fix the debug semantics 
# -		D(&x): &h -> {&g'} => &h.&x -> {&g'.&x'}.&x ...mmm, got a bit easier
# + log api calls : Log4perl
# + implement API-call cache to minimize the actual API usage
# - strip the globals, implement stated tie-interface
	my $meaningless = shift;
	my %arg = validate( @_, { # Validate arguments
		auth_key=> {type => SCALAR, optional => 1},

		request	=> {type => SCALAR}, # strict request string inquiry
		allow_cached
				=> {type => SCALAR, optional => 1, default => 1},

		expiration  # time in seconds
				=> {type => SCALAR, optional => 1},

		attempts # number of attempts
				=> {type => SCALAR, optional => 1, default => 1},
		pause_btw # pause between attempts
				=>{type => SCALAR, optional => 1, default => 0},
		timeout # time limit for api call
				=> {type => SCALAR, optional => 1, default => 1},

		target	=> {type => HASHREF, optional => 1},
		debug	=> {type => SCALAR, optional => 1, 
			default => ''}, ## 'request', 'response' or 'time'
	});
	# Expiration-check needs to be always a post-eval op to save the data
	my $rq = $arg{request};
	my $xpt; # overall expirity time
	if ($arg{expiration}) {
		$xpt = time - $arg{expiration}; # ...depending on the data-source
	}else{ $xpt = time; }

	# Small implementation of expiring memoization w/ filecache.
	my $call_res = (); # Initialize the callers_result
	if( $arg{allow_cached} ) { # crappy IfThenElse-spaghetti
# TODO: rewrite with continuations or, 
#       anyways, who cares, make this stuff much prettier asap.
		my $who = (split "::", (caller 1)[3])[0..2]; # what sub we're working 4?
		# Check for nonexpired value to exist in cache
		if (defined $cache{$rq}{body} && ($cache{$rq}{timestamp} > $xpt) ){
			# What did the hitted for?
			INFO "\t Hitting the cache (for $who )!";
			$cache{$rq}{hits}++; # add some statistics
			return $cache{$rq}{body}; # emulate API
# TODO: add  time_to_expire?
		} else { # check cache data to be nonexpired & timestamped
			if (defined $cache{$rq}{timestamp} && 
					( $xpt < $cache{$rq}{timestamp} ) ){
				INFO "\tMissed the cache ;("; # ah, we really missed that...
				$cache{$rq}{miss}++;
			} else {
				WARN "\t Cache for caller ($who) expired...";
				$cache{$rq}{exps}++; # count expirations
				$cache{$rq}{body} = undef; # unlink the result
			}
			if (defined $arg{timeout}) { # check for internal timeouts to apply
				WARN "\t Patching with timed request: max", $arg{timeout}, "s.";
				$call_res = actual_call( # call w/
					url=>$rq, timeout => $arg{timeout}	);
			} else { # straight call
				WARN "\t Patching with unrestrained request";
				$call_res = actual_call( url=>$rq );
			}

			# Did we got an error from the actual_call? looks safer
			if(defined $call_res->{error}) { # for any errors to appear
				# Tppend error statistics
				$cache{$rq}{error}{count}++; # but don't kill the existing body
				push @{$cache{$rq}{error}{'times'}}, time;
				ERROR "Terrible things happened ;(" # aint no dying right now!
			} else { # append timestamped data
				# All went okay
				INFO "\t Updating the cache:)";
				$cache{$rq}{body} = $call_res;
				$cache{$rq}{timestamp} = time;
				return $call_res;
			}
		}
	} else { # Perform direct call
		return actual_api_call( url=>$rq ); # for straight & non-caching
	}
};


# TODO:
# + validate args, prepare returnals
# - expose for chain-continuation 
# - rewrite more pleasant behaviour &w/ exception handling


# Fetch the list of available files with id's to play w/
sub file_list_get {
=for Reference:
L<https://developers.google.com/drive/v3/reference/files/list>
# "mimeType": "application/vnd.google-apps.folder";; "kind": "drive#file",
# { "kind": "drive#fileList", "files": [  {  id  } , ... ]
=cut
	my $self = shift;
	my @fkeys = qw/id kind name trashed mimeType owners size md5Checksum 
		createdTime modifiedTime headRevisionId/;
	my @flags = qw/corpus=domain orderBy=folder/;
	my %arg = validate( @_, {
		#fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1, default =>\@fkeys},
		flags	=> {type => ARRAYREF, optional => 1, default =>\@flags}, 
		shave	=> {type => SCALAR, optional => 1},
		expiration # expiration time for file-list cache
				=> {type => SCALAR, optional =>1, default => 3600},

		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @fields =qw/files/;
	
	my $request_string = $self->prepare_request(
		api		=> 'files', 
		flags 	=> \@flags,
		fields	=> \@fields,
	);
	
	my $response = $self->call_api(
		request => $request_string,
		expiration => $arg{expiration},
		#debug => \$arg{debug},
	);
#	foreach my $file ( @{ $response->{files} } ) { 
#		my %fhash = %{ shave($file, @fkeys) } if (@fkeys);
#		update_fields(\%fhash, \&time2ut, qw/createdTime modifiedTime/);
#		print Dumper \%fhash if $arg{debug};
#	}
	return $response; # 4now, we'll just push it unprocessed to outer context
}


# Get the meta- and fileinfo
sub file_get {
	my $self = shift;
	my @default_fields = qw/id kind name mimeType size description fileExtension 
		lastModifyingUser md5Checksum modifiedTime headRevisionId owners 
		parents permissions originalFilename properties shared sharingUser 
		trashed  createdTime version webContentLink/;
	my %arg = validate( @_, {
		file_id	=> {type => SCALAR},

		expiration # expiration time for inspected-file cache
				=> {type => SCALAR, optional =>1, default => 3600},

		fields	=> {type => ARRAYREF, optional => 1}, # rewrite?
		fkeys	=> {type => ARRAYREF, optional => 1},
		shave	=> {type => SCALAR, optional => 1},

		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @fields = ($arg{fields}) ? $arg{fields} : @default_fields;
	
	my $request_string = $self->prepare_request(
		api		=> "files/$arg{file_id}/",
		flags	=> undef,
		fields	=> \@fields,
	);
	my $response = $self->call_api(
		request => $request_string,
		expiration => 100,
		debug => 'all'#\$arg{debug},
	);
	
#	my @f2upd = qw/createdTime modifiedTime/;
#	update_fields(
#		hash	=> \%$response, 
#		funct	=> \&time2ut, 
#		fields	=> \@f2upd
#		);
	DEBUG Dumper $response if $arg{debug};
	return $response;
}



# Get all revisions for specific file
sub file_revisions_get  {
=for Reference:
L<https://developers.google.com/drive/v3/reference/revisions#methods>
# { "kind": "drive#revision", "id": revId, "modifiedTime": RFC 3339 date-time } 
=cut
	my $self = shift;
	my %arg = validate( @_, {
		file_id	=> {type => SCALAR},
# TODO: more fields to go...
		expiration # expiration time for file-list cache
				=> {type => SCALAR, optional =>1, default => 3600},

		fields	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},

		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	
	my @fields = qw/kind revisions/;
	
	my $request_string = $self->prepare_request(
		api => 'files/'.$arg{file_id}.'/revisions/', 
		flags	=> undef,
		fields	=> \@fields,
	);

	my $response = $self->call_api(
		request => $request_string,
		expiration => 100,
		#debug => \$arg{debug},
	);
#	foreach my $revision ( @{ $response->{revisions} } ) {
#		$revision = shave($revision, qw/id kind lastModifyingUser 
#									 mimeType modifiedTime/);
#		update_fields(\%$revision, \&time2ut, \@{qw/modifiedTime/});
		#$revision->{lastModifyingUser} = shave( $revision->{lastModifyingUser}, 
		#										qw/displayName kind/);
#	}
	return $response;
}



# TODO: for each file in list collect revisions, get start-date & last-mod-date
sub files_revisions_get {
	my $self = shift;
	my %arg = validate( @_, {
		files_id	=> {type => ARRAYREF},
		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @files = $arg{files_ids};
	foreach my $file (@files) {
		
	}
}


# harm into each revision & collect LMUT's (possibly, w/ originated-from-UID)
sub file_revision_get { # ( $file_id, $revision_id ) are mandatory
=for Reference:
<https://developers.google.com/drive/v3/reference/revisions/get>
# { "kind": "drive#revision", "id": revId , "lastModifyingUser": { 
#		"kind": "drive#user", "displayName": userName}}
=cut
	my $self = shift;
	my @dfields = qw/id kind mimeType md5Checksum size modifiedTime
					  lastModifyingUser originalFilename published/;
	my %arg = validate( @_, {
		file_id	=> {type => SCALAR}, # And how can one test such str?
		revision_id => {type => SCALAR},
# TODO: more fields to go...

		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},

		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
	});
	my $request_string = $self->prepare_request(
		api 	=> 'files/'.$arg{file_id}.'/revisions/'.$arg{revision_id}, 
		flags	=> undef,
		fields	=> \@dfields,
	);
	my $response = $self->call_api(
		request => $request_string,
		expiration => 100,
#		debug => \$arg{debug},
	);
# only proto'ed. 
# TODO: do stuff w/ patch semantics & return users _and_ document @ rev.
	return $response;
}



# Fetch comments & replies, collect them
# Has requirements -- need to manually set the 'can comment'-privilege 
#    for urs for each file
sub file_comments_get {
=for Reference:
L<https://developers.google.com/drive/v2/reference/comments>
# { "kind": "drive#commentList", "comments": [ 
#	  { "kind": "drive#comment", commentId, times, author, "replies": [ 
#			{"kind": "drive#reply" is_derived_from: "drive#comment"+action } ]
=cut
	my $self = shift;
	my %arg = validate( @_, {
		file_id	=> {type => SCALAR}, # mandatory
		page_size # max 100, useful for inline timeout setting
		# ~240ms for 2, ~1242ms for 10, ~1693ms for 100
		# TODO: check the argument for more than 100[ppr]
				=> {type => SCALAR, optional => 1, default => 10},

		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},

		expiration
				=> {type => SCALAR, optional => 1, default => 300},

		target	=> {type => HASHREF, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => 0},
		});
	my @flags = ['includeDeleted=true', "pageSize=".$arg{page_size}];
	my @fields = ['kind', 'comments', 'nextPageToken',]; # sensitive to undef

	my @comments = ();
	my $next_page = undef;
	my $result;
	my ($nor,$noc,$replies) = 0; # Counters for comments & replies
# TODO: need to rewrite the timing things
	my $time0 = time; # too ugly...
	do { # too flacky, may use CSP?
		my %hashval = ();
		my $request_string = $self->prepare_request(
			api		=> 'files/'.$arg{file_id}.'/comments',
			flags	=> @flags,
			fields	=> @fields,
			debug	=> "request",
#			target => \%hashval, # gat callee's state arguments for debug purp.
		);
		#INFO (caller 0)[3], Dumper {%hashval};
		$result = $self->call_api( # fetch w/ the bearer
			request => $request_string,
# TODO: need to set timeout globally. Later. Wanna sleep.
			timeout => 2, # same
			expiration => $arg{expiration}, # kludge
			debug => $arg{debug}, # nope, delegate elsewhere
		);

		$next_page = $result->{nextPageToken} if $result;
		DEBUG 'Next page token : "', $next_page,'"';
		#pop $flags[0]; push $flags[0], "pageToken=$next_page" if $next_page;
		$flags[0][-1] = "pageToken=$next_page" if $next_page;
		
		$nor++;
		foreach my $comment (@{ $result->{comments} }) {
# TODO: shave comments and replies
			$replies += scalar @{$comment->{replies}}; # Count replies
			push @comments, $comment;
		}
		INFO "comments in current resp: ",scalar @{$result->{comments}};
	} while ($next_page);# || $result->{nextPageToken}
	INFO "total noc in comments: ", scalar @comments, "\n";
	INFO "total number of replies in file: $replies";
	# dis looks ugly:
	my $tdiff = sprintf "%03d msec", (time - $time0)*1000 ;
	INFO "overall took $tdiff\n" if $arg{debug};

	return @comments; # not dat easy:
# TODO: rewrite in Contextual::Return
}

# TODO: append comments in 2-by-2 hash (fileId, authorId, time, content->lenght)

# Gosh, does it seems to finally work w/o a stub? Ami 'cunt 'bliev :/...


1;
