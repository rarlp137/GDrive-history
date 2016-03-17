#! /usr/bin/env perl
#use strict;
use warnings;
use 5.20.00;
use feature 'signatures'; no warnings qw(experimental::signatures);
use Getopt::Long;
#use Config::JSON;
use Data::Dumper; # Perl core module
#use Data::Dump qw(dump); # $ cpanm Data::Dump
#use Data::DPath 'dpath';
#use Data::Focus qw(focus);
#use Benchmark;
#use Hash::Transform;
#use Smart::Comments;
#use Params::Validate qw(:all);

use DateTime;
use DateTime::Format::RFC3339;

use Mojo::JWT::Google;
## Crypt::OpenSSL::RSA # isok w/o, not necessary
use Mojo::Collection 'c';
use Mojo::UserAgent;

binmode STDOUT, ":utf8";


sub shave($hash, @fkeys) { # nice filter-lens-transform
	my %shaved; # Data::Focus?
	@fkeys = grep { exists $hash->{$_} } @fkeys; # filter matching keys
	@shaved{@fkeys} = @$hash{@fkeys}; # map matches
	return \%shaved; # cast hash-ref
}

sub update_fields($hash, $fun, @fields) {
	foreach my $field (@fields) { # apply directly
		$hash->{$field} = &$fun($hash->{$field});
	}
}

# stitch the RFC-3339 date-time to unix time
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

# API caller proto
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

# Fetch list of available files with id's to play w/ proto
sub get_file_list() {
#L<https://developers.google.com/drive/v3/reference/files/list>
#Resp: "mimeType": "application/vnd.google-apps.folder";; "kind": "drive#file",
# GET https://www.googleapis.com/drive/v3/files?corpus=domain&orderBy=folder&fields=files%2Ckind&key={API_KEY}
#Resp: { "kind": "drive#fileList", "files": [  {  id  } , ... ]
	my $response = call_api('files', qw/corpus=domain orderBy=folder fields=files/);
	foreach my $file ( @{ $response->{files} } ) { 
		# focus($file) -> over( 1, ['createdTime', 'modifiedTime'], sub{ time2ut($_[0]) } );
		my @fkeys = qw/id kind name trashed mimeType owners size 
				md5Checksum createdTime modifiedTime headRevisionId/;
		my %fhash = %{ shave($file, @fkeys) };
		update_fields(\%fhash, \&time2ut, qw/createdTime modifiedTime/);

	}
}

# Fetch file properties proto
sub file_get_properties( $file_id ) {
	die "No fileId given!" unless $file_id;
	my $response = call_api("files/$file_id",
						 "fields=createdTime,description,fileExtension,".
						 "headRevisionId,id,kind,lastModifyingUser,".
						 "md5Checksum,mimeType,modifiedTime,name,".
						 "originalFilename,owners,parents,permissions,".
						 "properties,shared,sharingUser,size,trashed,".
						 "version,webContentLink");
	update_fields(\%response, \&time2ut, qw/createdTime modifiedTime/)
	# unshaved
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
sub file_revisions_get( $file_id )  {
	die "No fileId given!" unless $file_id;
	my $response = call_api("files/$file_id/revisions", 
				"fields=kind,revisions");
	foreach my $revision ( @{ $response->{revisions} } ) {
		$revision = shave($revision, qw/id kind lastModifyingUser mimeType modifiedTime/);
		update_fields(\%$revision, \&time2ut, qw/modifiedTime/);
		$revision->{lastModifyingUser} = 
			shave( $revision->{lastModifyingUser}, 
					qw/displayName kind/);
	}
	
}



# harm into each revision proto
## https://developers.google.com/drive/v3/reference/revisions/get
## https://developers.google.com/apis-explorer/#p/drive/v3/drive.revisions.get
## GET https://www.googleapis.com/drive/v3/files/ _fileId_ /revisions/ _revId_ ?
##	fields=id,keepForever,kind,lastModifyingUser,md5Checksum,mimeType,modifiedTime,originalFilename,publishAuto,
##	published,publishedOutsideDomain,size& key={API_KEY} 
### { "kind": "drive#revision", "id": revId ,
###	"lastModifyingUser": { "kind": "drive#user", "displayName": userName}}
sub file_revision_get( $file_id, $revision_id ) {
	die "No fileId or revisionId given" unless $file_id && $revision_id;
	my $response = call_api("files/$file_id/revisions/$revision_id", 
				"fields=id,kind,lastModifyingUser,md5Checksum,size,".
				"modifiedTime,originalFilename,published,mimeType");
}

# Implement collector of LMUT's (possibly, w/ originated-from-UID)



# sew & populate the userId collaboration chain from each revision




# https://developers.google.com/drive/v3/reference/changes/getStartPageToken



# fetch comments & replies, collect them in 2-by-2 hash (fileId, authorId ; time , content->lenght)
## GET https://www.googleapis.com/drive/v3/files/ fileId /comments?
##	includeDeleted=true&pageSize=100& fields=comments,kind,nextPageToken& key={YOUR_API_KEY}
### { "kind": "drive#commentList", "comments": [ 
#	  { "kind": "drive#comment", commentId, times, author, "replies": [ 
#			{"kind": "drive#reply" is_derived_from: "drive#comment" } ]



# populate the userId replies chain from each reply-to-UID and reply-after-time, revep



# for each userId, collect time-pts ary (time : act-type) & cumulative totals by each kind



# export csv with prettyprint :)



# export json/dot with vertice and edge weights
