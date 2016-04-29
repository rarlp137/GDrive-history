#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper::AutoEncode;
	$Data::Dumper::AutoEncode::ENCODING = 'utf8'; # Perhaps, 4 some systems 
use FindBin qw($Bin); use lib "$Bin/lib";
use utf8;
binmode STDOUT, ":utf8";

use GDrive::API;
# Create API-instance
my $obj = GDrive::API->new(
	cache_file => 'api.cache',
);

# Init the API session
my $result = $obj->init_session( 
	secret_json => './secret.json',
	user=>'some@email.com'
);
#if ($result) {...

# Get the list of avaliabl files
my $files = $obj->file_list_get();

my $test_document = 'some document id';

# Get the file metainfo
my $file = $obj->file_get(
	file_id => $test_document
);

=for Implementation
# Get the most recently-published file contents
my $file_contents = $obj->file_contents_get(
	file_id => $test_document
);
=cut

# Get comments for some document
#! This method requires to manually share the document with the issuer
my @comments = $obj->file_comments_get(
	file_id => $test_document, 
	page_size => 100,
);

# Get revisions
my $revisions = $obj->file_revisions_get(
	file_id=> $test_document, 
);

# Dig into some revision
my $revision = $obj->file_revision_get(
	file_id=> $test_document,  
	revision_id=>4069,
);

=for Implementation
# Get the specific file contents at some revision
my $revision_contents = $obj->file_revision_contents_get(
	file_id=> $test_document,  
	revision_id=>4069,
);

# Get meta-info (partic., need 2 implement the comments) slice at some revision
my $revision_comments = $obj->file_comments_slice_at_revision_get(
	file_id=> $test_document,  
	revision_id=>4069,
);
=cut
