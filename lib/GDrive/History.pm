package GDrive::History;

our @events = ();
our %collab = ();
sub collect_history {
#proto would look like
  foreach my $file (@{ $history->{files} }) {
  	# Conjoin enity of author of the current file to collab DAG
  	push @{ $collab{authors}{list} }, {
  		name => $file->{author}->{name},
  		mail => $file->{author}->{email},
  	};
  	push @events, {
  		type	=> 'create document',
  		doc_id	=>
  		actor	=> $file->{author},
  		'time'	=> $file->{createdDate},
  		};
	
  	# Check how much this document is important
  	my $document_weight = 1; # default
  	if (defined $file->{description}) { # search through the description 
  		$file->{description} =~ /imporance[:=]\s?(\d+)/i; # case insensitive
  		$document_weight = $1;
  	}
	
  	# Append document entity
  	push @{$collab{files}{list}}, { # anonimous hash
  		name	=> $file->{name},
  		id		=> $file->{id},
  		# get importance of the current document
  		weight	=> $document_weight,
  	};
  	
  	foreach my $comment (@{ $file->{comments} }) {
  		if ($comment->{deleted}) {
  			print "del";
  		}
  		# too loooong accessor
  		$collab{authors}{ $comment->{author} }{files} 
  			{ $file->{id} }{comments}{count}++;
  		
  		print " [", $comment->{'time'} ,"] ", 
  			$comment->{author}, ": ", 
  			$comment->{content}, "\n";
  		if (@{ $comment->{replies} }) {
  			foreach $reply (@{ $comment->{replies} }) {
  				
  				$collab{authors}{ $comment->{author} }
  					{ $file->{id} }{replies}{count}++;
  					
  				$collab{authors}{ $comment->{author} }
  					{ $file->{id} }{replies}{to}{ 
  						$reply->{author} 
  					}++;
  					
  				$time_diff = $reply->{'ti,e'} - $reply{'last'}{'time'};
  				
  				push @{$collab{authors}{ $comment->{author} }{}}
  				
  				print "\t[", $reply->{'time'}, "] ", 
  					$reply->{author}, ": ",
  					$reply->{content}, "\n";
  				if ($reply->{action} eq 'resolve') { 
  					print "RESOLVED by <", 
  						$reply->{author}, ">\n";
  				}
  			}
  		}
  	}
  	foreach my $rev (@{ $file->{revisions} }) {
  		$collab{ $rev->{author} }{edits}{count}++;
  		# TODO: - implement the revisions
  		#$collab{ $rev->{author} }{edits}{ $rev->{id} };
  	}
  }
  return $collab;
}


1;
