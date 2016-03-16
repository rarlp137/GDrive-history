#! /usr/bin/env perl
#use strict;
use warnings;
use 5.20.00;
use feature 'signatures'; no warnings qw(experimental::signatures);
use Data::Dumper; # Perl core module

#use Data::DPath 'dpath';
#use Data::Focus qw(focus);
#use Benchmark;
#use Hash::Transform;
#use Smart::Comments;

use DateTime;
use DateTime::Format::RFC3339;

use Mojo::JWT::Google;
## Crypt::OpenSSL::RSA # isok w/o, not necessary
use Mojo::Collection 'c';
use Mojo::UserAgent;

binmode STDOUT, ":utf8";


sub shave($hash, @fkeys) { # awesome filter-lens-transform
	my %shaved; # Data::Focus?
	@fkeys = grep { exists $hash->{$_} } @fkeys; # filter matching keys
	@shaved{@fkeys} = @$hash{@fkeys}; # map matches
	return %shaved; # cast hash-ref
}

sub time2ut($) {
	my $f = DateTime::Format::RFC3339->new();
	my $dt = $f->parse_datetime(shift);
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

sub call_api($api, @flags) { 
# What API are we using?
	my $url = 'https://www.googleapis.com/drive/v3/'. $api;
	my $flags = (scalar @flags > 0)?( '?' . join('&', @flags) ):'';
	$url .=$flags;
	my $call_header =  {'Authorization' => $auth_key};
	my $call_res = $ua->get( $url  => $call_header)->res 
		or die "Can't call $api with $flags!\n";

	return $call_res->json;
};


sub get_file_list() {#Fetch list of available files with id's to play w/
=pod 
L<https://developers.google.com/drive/v3/reference/files/list>
# "mimeType": "application/vnd.google-apps.folder";; "kind": "drive#file",
# GET https://www.googleapis.com/drive/v3/files?corpus=domain&orderBy=folder&fields=files%2Ckind&key={API_KEY}
### { "kind": "drive#fileList", "files": [  {  id  } , ... ]

=cut
	my $response = call_api('files', qw/corpus=domain orderBy=folder fields=files/);
	foreach my $file ( @{ $response->{files} } ) { 
		# focus($file) -> over( 1, ['createdTime', 'modifiedTime'], sub{ time2ut($_[0]) } );
		my @fkeys = qw/id kind name trashed mimeType owners size 
					   md5Checksum createdTime modifiedTime headRevisionId/;
		my %fhash = shave($file, @fkeys);

#		$fhash{createdTime} = time2ut($fhash{createdTime});
#		my %rules = (	createdTime => 'createdTime',
#						modifiedTime=> sub { print($_) },
#					);
#		my $transform = Hash::Transform->new(%rules);
#		%fhash = $transform->apply(%fhash);							
	}
}

# stitch each of the RFC-3339 date-time to unix time, strip & set appropriate timezone for each userId

# filter variety graphs for kinds


# filter through the exc/inc-lusion list (personal files of mine); instead, one might grep through the sources


# export to watch-list / local csv w/ id and title ## handmade shit _@iffun

# for each file in list get list of revisions, get start-date & last-mod-date
## https://developers.google.com/drive/v3/reference/revisions#methods
## GET https://www.googleapis.com/drive/v3/files/ fileid /revisions?key={API_KEY}
### { "kind": "drive#revision", "id": revId, "modifiedTime": RFC 3339 date-time } 

# harm into each revision & collect LMUT's (possibly, w/ originated-from-UID)
## https://developers.google.com/drive/v3/reference/revisions/get
## https://developers.google.com/apis-explorer/#p/drive/v3/drive.revisions.get
## GET https://www.googleapis.com/drive/v3/files/ _fileId_ /revisions/ _revId_ ?fields=id%2CkeepForever%2Ckind%2ClastModifyingUser%2Cmd5Checksum%2CmimeType%2CmodifiedTime%2CoriginalFilename%2CpublishAuto%2Cpublished%2CpublishedOutsideDomain%2Csize& key={API_KEY} 
### { "kind": "drive#revision", "id": revId , "lastModifyingUser": { "kind": "drive#user", "displayName": userName}}





# sew & populate the userId collaboration chain from each revision




# https://developers.google.com/drive/v3/reference/changes/getStartPageToken



# fetch comments & replies, collect them in 2-by-2 hash (fileId, authorId ; time , content->lenght)
## GET https://www.googleapis.com/drive/v3/files/ fileId /comments?includeDeleted=true&pageSize=100& fields=comments%2Ckind%2CnextPageToken& key={YOUR_API_KEY}
### { "kind": "drive#commentList", "comments": [ 
#	  { "kind": "drive#comment", commentId, times, author, "replies": [ 
#			{"kind": "drive#reply" is_derived_from: "drive#comment" } ]



# populate the userId replies chain from each reply-to-UID and reply-after-time, revep



# for each userId, collect time-pts ary (time : act-type) & cumulative totals by each kind



# export csv with prettyprint :)



# export json/dot with vertice and edge weights
