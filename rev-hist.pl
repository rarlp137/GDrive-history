#! /usr/bin/env perl

# TODO: 
# - make auth to unit state-vars
# - clean docs, getopts, pass2DBX?
# - rewrite according to Perl::Critic --brutal severity
# - outpace pragmas
# - strip into modules
# - patch-semantics

use strict;
use warnings;
use diagnostics;
use 5.20.00;
#use feature 'signatures'; # deprecated
no warnings qw/experimental::autoderef/;
use Getopt::Long;
use Pod::Usage qw(pod2usage);
#use Config::JSON;
# provides eDumper(), >human-readable than Dumper & w/ utf support
use Data::Dumper::AutoEncode; 
	$Data::Dumper::AutoEncode::ENCODING = 'utf8';
	$Data::Dumper::Indent = 1; # turn off all pretty print
	$Data::Dumper::Pair = "="; # specify hash key/value separator
	$Data::Dumper::Sortkeys = 1;
use Memoize::Storable; # for caching support
#use Contextual::Return; # for managing context-sensitive retn's
#use Hook::LexWrap; # for managing the pre- and post- subroutine wrappers

#use Data::Dump qw(dump); # $ cpanm Data::Dump
#use Data::DPath 'dpath';
#use Data::Focus qw(focus);
use Time::HiRes qw(time);
#use Hash::Transform;
#use Smart::Comments;
use Params::Validate qw(:all);

use DateTime;
use DateTime::Format::RFC3339;

use Mojo::JWT::Google;
## Crypt::OpenSSL::RSA # isok w/o, not necessary
use Mojo::Collection 'c';
use Mojo::UserAgent;
use utf8; # ::all
binmode STDOUT, ":encoding(UTF-8)";

# TODO: add the GetOpt's and usage

## init the globals

state %counter;
sub tickle_sub { # 4 debug purposes
	my ($arg) = shift;
	# Peek who's calling through the context:
	my ($upkg, $ufile,	$uline,	$call_sub)	= caller 2;# who called...
	my ($pkg, $file,	$line,	$sub_name)	= caller 1;# ...what?
	# Increment the calls counter
	$counter{$sub_name}{'from'}{$call_sub}{calls} ++;
	return 0;
}


sub shave($hash, @fkeys) { # nice filter-lens-transform
	my %shaved; # Data::Focus?
	@fkeys = grep { exists $hash->{$_} } @fkeys; # filter matching keys
	@shaved{@fkeys} = @$hash{@fkeys}; # map matches
	return \%shaved; # cast hash-ref
}

sub update_fields {
	my %arg = validate( @_, { # Validate arguments
		hash 	=> {type => HASHREF},
		funct	=> {type => CODEREF},
		fields	=> {type => ARRAYREF},
		debug	=> {type => SCALAR, optional => 1},});
	print Dumper {%arg} if $arg{debug};
	foreach my $field (@{$arg{fields}}) {
		${$arg{hash}}{$field} = 
			$arg{funct}->( str => ${$arg{hash}}{$field}); # apply directly
	}
}

# stitch the RFC-3339 date-time to unix time
sub time2ut {  # add wantarray
	my %arg = validate( @_, { str => {type => SCALAR},});
	my $f = DateTime::Format::RFC3339->new();
	my $dt = $f->parse_datetime($arg{str});
	return $dt->epoch;
}

state ($ua, $auth_key, $call_header);


# initiate the OAuth2.0 session
sub init_session { 
# TODO: expose for chain-continuation // done partially
	my $jwt = Mojo::JWT::Google->new( 
		from_json => './secret.json',
		issue_at  => time,
		scopes    => c('https://www.googleapis.com/auth/drive.readonly'),
		user_as   => 
			'some@email.com'
	);

	my $token_request_url = q(https://www.googleapis.com/oauth2/v3/token);
	my $grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

	$ua = Mojo::UserAgent->new;
	my $tok_res = $ua->post($token_request_url
		=> form => { grant_type => $grant_type, assertion => $jwt->encode } 
		)->res;
	my $json = $tok_res->json or die "No authorization provided";
	$auth_key = $json->{token_type} . ' ' . $json->{access_token};
	$call_header =  {'Authorization' => $auth_key};
}

init_session();


# Prepare the request string
sub prepare_request {
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		site 	=> { default => 'https://www.googleapis.com/drive' },
		version	=> {type => SCALAR, optional => 1, # v2 and v3 both work fine
			default => 'v3'},
		api		=> {type => SCALAR},# What API are we using?
		flags	=> {type => ARRAYREF|UNDEF, optional => 1}, # call properties
		fields	=> {type => ARRAYREF|UNDEF, optional => 1}, # call response fields
		
		debug	=> {type => SCALAR, optional => 1, default => ''},
	});
	print "\tRequest arguments: ", Dumper {%arg} if ($arg{debug} eq 'request');
	
	# Construct the URL base 
	my $url = $arg{site} .'/'. $arg{version} .'/'. $arg{api} ;
	
	# Append properties
	my @flags = (); #  preventive init for later use in fields augmentation
	if ($arg{flags}) { # ensure flags aren't empty
		@flags = @{ $arg{flags}  } ;
		$url .= '?' . join('&', @flags ) ;
	}
	my @fields= @{ $arg{fields} } ;
	# Append fields
	if ($arg{fields}) {
		$url .= ($arg{flags}?'&':'?') . # collate properties/fields separator
			  'fields='.join(',', @fields ) ;
	}
	
	print "GET request :\n\t$url\n" if ($arg{debug} eq 'request');
	return $url; # TODO rewrite in Contextual::Return
}

sub cached_api_call {
	...
}

sub actual_api_call {# consider to have plenty errors
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		url		=> {type => SCALAR}, # mandatory
		auth_key=> {type => SCALAR, optional => 
			  # nasty trick to enforce the existing auth key to be required:
			  sub { return defined $auth_key}}, # if no internal, passes 0
		debug	=> {type => SCALAR, optional => 1, default => ''},
	});
	print "\tRequest arguments: ", Dumper {%arg} if ($arg{debug} eq 'request');
	
	# Check if we're supplied with some specific auth-key
	if (defined $arg{auth_key}) { 
		$auth_key = $arg{auth_key}; 
		print "Using locally-proposed auth_key: $auth_key\n" if 
			($arg{debug} eq 'response');
	};
	my $tdiff = 0; # onsite, non-integrating!	
	my $call_res = ();
	if (defined $auth_key) {
		my $time0 = time;
			tickle_sub();
		my $url = $arg{url};
		#my $call_header =  {'Authorization' => $auth_key};
		$call_res = $ua->get( $url  => $call_header)->res 
			or die "Can't call $arg{api}-api!\n";
			#print Dumper $call_res, "\n"x2;
		if ($call_res->{error}) {
			# TODO: implement some error handling here
			my $error = $call_res->{error};
			print "\nError ", $error->{code}, ": ", $error->{message} || 0, "\n";
		}
		$tdiff = time - $time0; # TODO: strip down this crap
		print "Response: ", Dumper $call_res->json if 
			($arg{debug} eq 'response');
		print "Response took: ", sprintf("%03d",int($tdiff*1000))," msec\n" if 
			($arg{debug} eq 'time');
	} else {die "No authentification! \n"}
	if (defined $arg{target}) {
		$arg{target} = $call_res->json;
		return "OK, took $tdiff sec.";
	} else {
		return $call_res->json;
	};
	#...
}


sub call_api {
# wrapper
# TODO:
# - flatten to wrapper for memoization 
# - try not to break the outer calls
# - pledge to work with hashes
# - fix the debug semantics 
# 		D(&x): &h -> {&g'} => &h.&x -> {&g'.&x'}.&x
# - log api calls
# - implement API-call cache to minimize the actual API usage
	my %arg = validate( @_, { # Validate arguments
		target	=> {type => HASHREF, optional => 1},
		auth_key=> {type => SCALAR, optional => 1},
		request	=> {type => SCALAR}, # strict request string inquiry
		allow_cached
				=> {type => SCALAR, optional => 1, default => 1},
		debug	=> {type => SCALAR, optional => 1, 
			default => ''}, ## 'request', 'response' or 'time'
	});
	print "\tRequest arguments: ", Dumper {%arg} if ($arg{debug} eq 'request');

	my $request = $arg{request};
	my $call_res = actual_api_call(
		url => $request,
		#debug => 'request',
		);
	return $call_res;
};




# Fetch list of available files with id's to play w/ proto
sub file_list_get {#Fetch list of available files with id's to play w/
	my @fkeys = qw/id kind name trashed mimeType owners size md5Checksum 
		createdTime modifiedTime headRevisionId/;
	my @flags = qw/corpus=domain orderBy=folder/;
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		#fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1, default =>\@fkeys},
		flags	=> {type => ARRAYREF, optional => 1, default =>\@flags}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	
	my @fields =qw/files/;
	
	my $request_string = prepare_request(
		api		=> 'files', 
		flags 	=> \@flags,
		fields	=> \@fields,
	);
	
	my $response = call_api(
		request => $request_string,
		#debug => \$arg{debug},
	);
	
	foreach my $file ( @{ $response->{files} } ) { 
		my %fhash = %{ shave($file, @fkeys) } if (@fkeys);
		update_fields(\%fhash, \&time2ut, qw/createdTime modifiedTime/);
		print Dumper \%fhash if $arg{debug};
	}
	
	return $response;
}


# Fetch file properties proto
sub file_get {
	my @default_fields = qw/id kind name mimeType size description fileExtension 
		lastModifyingUser md5Checksum modifiedTime headRevisionId owners 
		parents permissions originalFilename properties shared sharingUser 
		trashed  createdTime version webContentLink/;
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		file_id	=> {type => SCALAR},
		fields	=> {type => ARRAYREF, optional => 1}, # rewrite?
		fkeys	=> {type => ARRAYREF, optional => 1},
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @fields = ($arg{fields}) ? $arg{fields} : @default_fields;
	
	my $request_string = prepare_request(
		api		=> "files/$arg{file_id}/",
		flags	=> undef,
		fields	=> \@fields,
		);
	my $response = call_api(
		request => $request_string,
		debug => 'all'#\$arg{debug},
		);
	
	my @f2upd = qw/createdTime modifiedTime/;
	update_fields(
		hash	=> \%$response, 
		funct	=> \&time2ut, 
		fields	=> \@f2upd
		);
	print Dumper $response if $arg{debug};
	return $response;
}

#file_get(file_id => $test_docyment,);
#my $test_document = '' unless $glob{argument => ::doc_id}; # 4 test purposes


sub filter_files() {
	# 2 implement
	...
}

sub file_list_load() {
	# 2 implement
	...
}

sub file_list_store() {
	# 2 implement
	...
}

# collect users, owners, modifiers
sub collect_issuers {
	# 2 implement
	...
}



# filter variety graphs for kinds, (strip & set appropriate timezone for each userId)?


# filter through the exc/inc-lusion list (personal files of mine); instead, one might grep through the sources


# export to watch-list / local csv w/ id and title ## handmade shit _@iffun

# for each file in list get list of revisions, get start-date & last-mod-date proto
## https://developers.google.com/drive/v3/reference/revisions#methods
## GET https://www.googleapis.com/drive/v3/files/ fileid /revisions?key={API_KEY}
### { "kind": "drive#revision", "id": revId, "modifiedTime": RFC 3339 date-time } 
sub file_revisions_get  {
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		file_id	=> {type => SCALAR},
		fields	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	
	my @fields = qw/kind revisions/;
	
	my $request_string = prepare_request(
		api => 'files/'.$arg{file_id}.'/revisions/', 
		flags	=> undef,
		fields	=> \@fields,
		);

	my $response = call_api(
		request => $request_string,
		#debug => \$arg{debug},
		);

	foreach my $revision ( @{ $response->{revisions} } ) {
		$revision = shave($revision, qw/id kind lastModifyingUser 
									 mimeType modifiedTime/);
		update_fields(\%$revision, \&time2ut, \@{qw/modifiedTime/});
		#$revision->{lastModifyingUser} = shave( $revision->{lastModifyingUser}, 
		#										qw/displayName kind/);
	}
	return $response;
}




# harm into each revision proto
## https://developers.google.com/drive/v3/reference/revisions/get
## https://developers.google.com/apis-explorer/#p/drive/v3/drive.revisions.get
## GET https://www.googleapis.com/drive/v3/files/ _fileId_ /revisions/ _revId_ ?
##	fields=id,keepForever,kind,lastModifyingUser,md5Checksum,mimeType,modifiedTime,originalFilename,publishAuto,
##	published,publishedOutsideDomain,size& key={API_KEY} 
### { "kind": "drive#revision", "id": revId ,
###	"lastModifyingUser": { "kind": "drive#user", "displayName": userName}}
sub file_revision_get {# ( $file_id, $revision_id )
	my @dfields = qw/id kind mimeType md5Checksum size modifiedTime
					  lastModifyingUser originalFilename published/;
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		file_id	=> {type => SCALAR},
		revision_id => {type => SCALAR},
		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my $request_string = prepare_request(
		api 	=> 'files/'.$arg{file_id}.'/revisions/'.$arg{revision_id}, 
		flags	=> undef,
		fields	=> \@dfields,
		);
	my $response = call_api(
		request => $request_string,
		#debug => \$arg{debug},
		);
	# only proto'ed. do stuff w/ patch semantics
	print Dumper $response if defined $arg{debug};
	return $response;
}

#file_revision_get(file_id=>$file_id, revision_id=>4069);


# Implement collector of LMUT's (possibly, w/ originated-from-UID)



# sew & populate the userId collaboration chain from each revision


# fetch comments & replies, collect them in 2-by-2 hash (fileId, authorId ; time , content->lenght)
## GET https://www.googleapis.com/drive/v3/files/ fileId /comments?
##	includeDeleted=true&pageSize=100& fields=comments,kind,nextPageToken& key={YOUR_API_KEY}
### { "kind": "drive#commentList", "comments": [ 
#	  { "kind": "drive#comment", commentId, times, author, "replies": [ 
#			{"kind": "drive#reply" is_derived_from: "drive#comment"+@action } ]
sub file_comments_get { 
# mandatory requirements -- need 2 set 'can comment'-permission for each of srcs
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		file_id	=> {type => SCALAR},
		page_size => {type => SCALAR, optional => 1, default => 10},
		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @flags = ['includeDeleted=true', "pageSize=".$arg{page_size}];
	my @fields = ['kind', 'comments', 'nextPageToken',]; # sensitive to undef
	my @comments = ();
	my $next_page = undef;
	my $result;
	my ($nor,$noc) = 0; # overall number of requests
	my $time0 = time;
	do { # too flacky, may use CSP?
		my $request_string = prepare_request(
			api		=> 'files/'.$arg{file_id}.'/comments',
			flags	=> @flags,
			fields	=> @fields,
			debug	=> "request",
			);
		print "\n\n$request_string\n\n";
		$result = call_api( # fetch w/ the bearer
			request => $request_string,
			debug => $arg{debug},
			);
		print eDumper $result if $arg{debug};
		$next_page = $result->{nextPageToken} if $result;
		$flags[0][-1] = "pageToken=$next_page" if $next_page;
		$nor++;
		foreach my $comment (@{ $result->{comments} }) {
			# shave comment
			push @comments, $comment;
		}
		print "\t\tnoc in resp: ", scalar @{$result->{comments}}, "\n";
	} while ($next_page);# || $result->{nextPageToken}
	print "\tnoc in comments: ", scalar @comments, "\n";
	my $tdiff = sprintf "%03d msec", (time - $time0)*1000 ;
	print "\toverall took $tdiff\n" if $arg{debug};
	#foreach my $comment ( @$comments ) {
	#	$comment = shave(\$comment, qw/kind id createdTime modifiedTime author 
	#								  deleted resolved replies/);
	#	# shave author and comments hashes?
	#	update_fields(\%$comment, \&time2ut, \@{qw/createdTime modifiedTime/});
	#}
	#print Dumper {@comments} if ($arg{debug} eq 'dump all');
	#return \%comments;
}

my $test_document = '' unless $glob{argument => ::doc_id}; # 4 test purposes
file_comments_get(file_id => $test_document, page_size => 2);
print Dumper {%counter};



# populate the userId replies chain from each reply-to-UID and reply-after-time, revep



# for each userId, collect time-pts ary (time : act-type) & cumulative totals by each kind



# export csv with prettyprint :)



# export json/dot with vertice and edge weights
