package GDrive::History;
use GDrive::API qw/:as_datasource/

our @events = ();
# Initialize the collaborators lattice (FCA-like) as an implicit DAG
our %collab = ();
=for Rationale:
In our particular case collaboration lattice (triple L = (G,M,I)) would be non-
trivial because it would have 2 essential context object-sets, constructed from 
typed terminals of directed acyclic graphs (as actions): 
	G = { term( {actor ∈ Actors ⊢ DAG} ) x 
		term( {document ∈ Documents ⊢ DAG} ) } .
Concept DAG's are heavily interlinked (beginning with semi-roots), therefore, 
cannot form elegant object set. From more prominent perspective of actions/
events, this simply would imply the following types:
	action ⊨ {introduce, edit, comment, reply, resolve, publish}
and as for Actions partially-ordered set, having two types/kinds of incidence 
relations (natural time and consequential), we cannot say that 
	∀ a,a' ⊢ Actions, ∃! rel: {a,a'} ⊢ PoSet
holds strictly. Counter-example would basically be the process of replying to 
comments, differing by the origin at different times -- we would get one partial
(by time) and one semi-order (by reply-chain) and associative relations between 
them obviously shall not apply.
Actor-concept then could be supplied with newly introduced set of events/acts 
on some documents (as domains):
	Actor = { {document ∈ Documents} x {action ∈ Actions} },
each document then could be represented with a collection of actions taken by 
corresp. actors:
	Document = { < action ∈ Actions, actor ∈ Actors > }.
These concepts are inseparable, therefore, result in an ambiguity in the right 
way of construction of object and attribute sets, thus, a lattice to work with 
further: 
	L = ({Actions, Actors, Documents}, {Actions}.ord ∨? Actors ∨? Documents...),
or even
	L = ({Actions},  consequence-relation, incidence),
with both alternativse resulting in excessively heavy object set (see,
L<https://en.wikipedia.org/wiki/Formal_concept_analysis> , sect.: Algorithms)
=cut

=for Discursive improvements:
Action terms are obviosly (and simultaniously) spreaded in time ( x ℝ) and 
likely to have importance order ( x ℝ), so advanced tuple sufficiently maps 
onto pairs:
		< {action ⊢ Actions}, Actor, Document > -> <time, importance> ∈ ℝ² .
Naturally, resulting attribute set relies on set-boolean 2^{term(Authors)}, as
actions	_do_ have partial-, sub- and natural (regarding the time) orders:
		  create ≻ introduce ≻ { {revisions}.ord , 
			  {comment ≻ {replies}.ord ≻ resolve}.ord }.
=cut

=for Implementation:
Neglecting the space-complexity of construction of such FCA-lattice in straight-
forward manner, we'll use the hash as a tweak to implicit DAG and populate it 
with the refined event attributes.
=cut

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
  	push @{$collab{files}{list}}, { # anonymous hash
  		name	=> $file->{name},
  		id		=> $file->{id},
  		# get importance of the current document
  		weight	=> $document_weight,
  	};
  	
  	foreach my $comment (@{ $file->{comments} }) {
  		if ($comment->{deleted}) {
  			print "del";
  		}
  		# loooong accessors are looooong
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
=for Alternatives:
Of course, one could populate action events into the sequences (generally, using
sequence mining algorithms) and study them as patterns for evaluation. This 
attempt has restrictions and brings much overhead regarding the task. 
See,: Mabroukeh, N., Ezeife, C. (2010). A taxonomy of sequential pattern mining 
algorithms". ACM Computing Surveys 43: 1–41.
=cut


1;
