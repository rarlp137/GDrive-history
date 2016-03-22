#! /usr/bin/env perl
use strict;
use warnings;
use diagnostics;
use 5.20.00;
use feature 'signatures'; no warnings qw(experimental::signatures);
no warnings qw(experimental::autoderef);
use Getopt::Long;
#use Config::JSON;
use Data::Dumper; # Perl core module
#use Data::Dump qw(dump); # $ cpanm Data::Dump
#use Data::DPath 'dpath';
#use Data::Focus qw(focus);
use Time::HiRes qw(time);
#use Hash::Transform;
#use Smart::Comments;
use Params::Validate qw(:all); # for internal signature ctrl

use DateTime;
use DateTime::Format::RFC3339;

use Mojo::JWT::Google;
## Crypt::OpenSSL::RSA # isok w/o, not necessary
use Mojo::Collection 'c';
use Mojo::UserAgent;
use utf8;
binmode STDOUT, ":encoding(UTF-8)";

## add the GetOpt's and usage

## init the globals

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
sub time2ut { 
	my %arg = validate( @_, { str => {type => SCALAR},});
	my $f = DateTime::Format::RFC3339->new();
	my $dt = $f->parse_datetime($arg{str});
	return $dt->epoch;
}

# initiate OAuth2.0 session
my $jwt = Mojo::JWT::Google->new( 
	from_json => './secret.json',
    issue_at  => time,
    scopes    => c('https://www.googleapis.com/auth/drive.readonly'),
    user_as   => 'some@email.com'
);

my $token_request_url = q(https://www.googleapis.com/oauth2/v3/token);
my $grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
 
my $ua = Mojo::UserAgent->new;
my $tok_res = $ua->post($token_request_url
  => form => { grant_type => $grant_type, assertion => $jwt->encode } 
  )->res;
my $json = $tok_res->json;
my $auth_key = $json->{token_type} . ' ' . $json->{access_token};

# API caller proto
sub call_api {
	my %arg = validate( @_, { # Validate arguments
		target	=> {type => HASHREF, optional => 1},
		site 	=> { default => 'https://www.googleapis.com/drive/v3/' },
		api		=> {type => SCALAR},# What API are we using?
		debug	=> {type => SCALAR, optional => 1, default => ''}, ## 'request', 'response' or 'time'
		flags	=> {type => ARRAYREF|UNDEF, optional => 1}, # call properties
		fields	=> {type => ARRAYREF|UNDEF, optional => 1}, # call response fields
		auth_key=> {type => SCALAR, optional => 
			  sub { return defined $auth_key}},
	});
	print "\tRequest arguments: ", Dumper {%arg} if 
		($arg{debug} eq 'request');
	
	my $url = $arg{site} . $arg{api} ;
	my @flags = ();
	if ($arg{flags}) {
		@flags = @{ $arg{flags}  } ;
		$url .= '?' . join('&', @flags ) ;
	}
	if ($arg{fields}) {
		my @fields= @{ $arg{fields} } ;
		$url .= ($arg{flags}?'&':'?') . 'fields='.join(',', @fields ) ;
	}
	print "GET request :\n\t$url\n" if ($arg{debug} eq 'request');
	if (defined $arg{auth_key}) { 
		$auth_key = $arg{auth_key}; 
		print "Using locally-proposed auth_key: $auth_key\n" if 
			($arg{debug} eq 'response');
	};
	my $tdiff = 0; # onsite, non-integrating!
	my $call_res;
	if (defined $auth_key) {
		my $time0 = time;
		my $call_header =  {'Authorization' => $auth_key};
		$call_res = $ua->get( $url  => $call_header)->res 
			or die "Can't call $arg{api}-api!\n";
		if ($call_res->{error}) {
			
			# implement some error handling here
			
		}
		$tdiff = time - $time0;
		print "Response: ", Dumper $call_res->json if 
			($arg{debug} eq 'response');
		print "Response took: $tdiff s\n" if 
			($arg{debug} eq 'time');
	} else {die "No authentification! \n"}
	if (defined $arg{target}) {
		$arg{target} = $call_res->json;
		return "OK, took $tdiff sec.";
	} else {
		return $call_res->json;
	};
};



# Fetch list of available files with id's to play w/ proto
sub file_list_get {#Fetch list of available files with id's to play w/
#L<https://developers.google.com/drive/v3/reference/files/list>
#Resp: { "kind": "drive#fileList", "files": [  {  id  } , ... ]
	my @fkeys = qw/id kind name trashed mimeType owners size md5Checksum 
		createdTime modifiedTime headRevisionId/;
	my @flags = qw/corpus=domain orderBy=folder/;
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1, default =>\@fkeys},
		flags	=> {type => ARRAYREF, optional => 1, default =>\@flags}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	
	my @fields =qw/files/;
	my $response = call_api(
		api => 'files', 
		flags => \@flags,
		fields=> \@fields,
		#debug => \$arg{debug}, # now has none, 4 validation concerns
	);
	foreach my $file ( @{ $response->{files} } ) { 
		my %fhash = %{ shave($file, @fkeys) } if (@fkeys);
		update_fields(\%fhash, \&time2ut, qw/createdTime modifiedTime/);
		print Dumper \%fhash if $arg{debug};
	}
	
	
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
		flags	=> {type => ARRAYREF, optional => 1}, ## need 2 rewrite
		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1},
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @fields = ($arg{fields}) ? $arg{fields} : @default_fields;
	my $response = call_api(
			api		=> "files/$arg{file_id}/",
			flags	=> undef,
			fields	=> \@fields,
			);
	
	my @f2upd = qw/createdTime modifiedTime/;
	update_fields(
		hash	=> \%$response, 
		funct	=> \&time2ut, 
		fields	=> \@f2upd
		);
	print Dumper $response if $arg{debug};
	
	
}



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
	my $response = call_api(
			api => 'files/'.$arg{file_id}.'/revisions/', 
			flags	=> undef,
			fields	=> \@fields,
			);
	foreach my $revision ( @{ $response->{revisions} } ) {
		$revision = shave($revision, qw/id kind lastModifyingUser 
									 mimeType modifiedTime/);
		update_fields(\%$revision, \&time2ut, \@{qw/modifiedTime/});
		#$revision->{lastModifyingUser} = shave( $revision->{lastModifyingUser}, 
		#										qw/displayName kind/);
	}
	print Dumper $response;
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
	my $response = call_api(
		api 	=> 'files/'.$arg{file_id}.'/revisions/'.$arg{revision_id}, 
		flags	=> undef,
		fields	=> \@dfields,
		);
	# only proto'ed. need 2 implement the holy patch semantics as in gdrive-merge to harm ATL
	# https://developers.google.com/drive/v3/reference/changes/getStartPageToken & ibid., overall
	print Dumper $response if defined $arg{debug};
	return $response;
}


# Implement collector of LMUT's (possibly, w/ originated-from-UID)



# sew & populate the userId collaboration chain from each revision


# fetch comments & replies, collect them in 2-by-2 hash (fileId, authorId ; time , content->lenght)
## GET https://www.googleapis.com/drive/v3/files/ fileId /comments?
##	includeDeleted=true&pageSize=100& fields=comments,kind,nextPageToken& key={YOUR_API_KEY}
### { "kind": "drive#commentList", "comments": [ 
#	  { "kind": "drive#comment", commentId, times, author, "replies": [ 
#			{"kind": "drive#reply" is_derived_from: "drive#comment"+@action } ]
sub file_comments_get { # mandatory requirements -- need 2 set 'can comment'-permission for each of srcs
	my %arg = validate( @_, {
		target	=> {type => HASHREF, optional => 1},
		file_id	=> {type => SCALAR},
		page_size => {type => SCALAR, optional => 1, default => 10},
		fields	=> {type => ARRAYREF, optional => 1},
		fkeys	=> {type => ARRAYREF, optional => 1}, # critical
		flags	=> {type => ARRAYREF, optional => 1}, 
		shave	=> {type => SCALAR, optional => 1},
		debug 	=> {type => SCALAR, optional => 1, default => undef},
		});
	my @flags = ['includeDeleted=true', "pageSize=".$arg{page_size}, ''];
	my @fields = ['kind', 'comments', 'nextPageToken'];
	my @comments = ();
	my $next_page = undef;
	my $result;
	my ($nor,$noc) = 0; # overall number of requests
	do { # too flacky, may use CSP?
		$result = call_api( # fetch w/ returning the nxt-bearer
			api		=> 'files/'.$arg{file_id}.'/comments',
			flags	=> @flags,
			fields	=> @fields,
			debug	=> 'request',
		);
		print Dumper $result if $arg{debug};
		$next_page = $result->{nextPageToken} if $result;
		pop $flags[0]; push $flags[0], "pageToken=$next_page" if $next_page;
		$nor++; # for debug purposes
		foreach my $comment (@{ $result->{comments} }) { # lazy to use map-magic
			#	$comment = shave(\$comment, qw/kind id createdTime modifiedTime author 
			#					deleted resolved replies/);
			#	# shave author and comments hashes?
			#	update_fields(\%$comment, \&time2ut, \@{qw/createdTime modifiedTime/});
			#}
			push @comments, $comment;
			# stir the entire stuff for distilled hash
		}
		print "\t\tnoc in resp: ", scalar @{$result->{comments}}, "\n" if $arg{debug};
	} while ($next_page);# || $result->{nextPageToken}
	print "\tnoc in comments: ", scalar @comments, "\n" if $arg{debug};
	#print Dumper {@comments} if ($arg{debug} eq 'dump all');
	#return \%comments;
}
my $test_document = '' unless $glob{argument => ::doc_id}; # 4 test purposes
file_comments_get(file_id => $test_document, page_size => 2);



# populate the userId replies chain from each reply-to-UID and reply-after-time, revep



# for each userId, collect time-pts ary (time : act-type) & cumulative totals by each kind



# export csv with prettyprint :)



# export json/dot with vertice and edge weights
