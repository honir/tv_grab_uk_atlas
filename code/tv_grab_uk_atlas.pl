#!/usr/bin/perl -w
#
# Copyright G. Westcott - September 2013
#
# This code is distributed under the GNU General Public License v2 (GPLv2) .
#
# 

eval 'exec /usr/bin/perl -w -S $0 ${1+"$@"}'
    if 0; # not running under some shell

use strict;
use warnings;
use constant { true => 1, false => 0 };
use Data::Dumper;

use XMLTV::ProgressBar;
use XMLTV::Options qw/ParseOptions/;
use XMLTV::Configure::Writer;

use File::Path;
use POSIX qw(strftime);
use DateTime;
use Date::Parse;
use Encode;
use URI::Escape;

# Atlas can provide data in JSON and XML formsts - we use the JSON format (it's much faster than using xmltree)
use JSON::PP;

use HTTP::Cookies;
use LWP::UserAgent;
my $lwp = initialise_ua();

use subs qw(t warning);
my $warnings = 0;


# ------------------------------------------------------------------------------------------------------------------------------------- #
# Grabber details
my $VERSION 								= '$Id: tv_grab_uk_atlas,v 1.002 2013/09/11 06:25:00 honir Exp $';
my $GRABBER_NAME 						= 'tv_grab_uk_atlas';
my $GRABBER_DESC 						= 'UK - Atlas (atlas.metabroadcast.com)';
my $ROOT_URL                = 'http://atlas.metabroadcast.com/3.0/';
#
my $generator_info_name 		= $GRABBER_NAME;
my $generator_info_url 			= $ROOT_URL;



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Use XMLTV::Options::ParseOptions to parse the options and take care of the basic capabilities that a tv_grabber should
my ($opt, $conf) = ParseOptions({ 
			grabber_name 			=> $GRABBER_NAME,
			capabilities 			=> [qw/baseline manualconfig apiconfig cache/],
			stage_sub 				=> \&config_stage,
			listchannels_sub 	=> \&fetch_channels,
			version 					=> $VERSION,
			description 			=> $GRABBER_DESC,
			extra_options			=> [qw/hours=i date=s channel=s info/],
			defaults					=> {'hours'=>0, 'channel'=>''}
});
#print Dumper($conf, $opt); exit;

# options.pm hi-jacks the --help arg and creates its own POD synopsis!  This means we can't tell people about our added
#  parameters.  I would posit that' a bug.  Let's allow '--info' to replace it.
if ($opt->{'info'}) {
	use Pod::Usage;
  pod2usage(-verbose => 2);
	exit 1;
}
	
# any overrides?
if (defined( $conf->{'generator-info-name'} )) { $generator_info_name = $conf->{'generator-info-name'}->[0]; }
if (defined( $conf->{'generator-info-url'} ))  { $generator_info_url  = $conf->{'generator-info-url'}->[0]; }



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Let's play nice and use a short-term cache to reduce load on Atlas site
# Initialise the web page cache
use HTTP::Cache::Transparent;
init_cachedir( $conf->{cachedir}->[0] );
HTTP::Cache::Transparent::init( { 
    BasePath => $conf->{cachedir}->[0],
    NoUpdate => 60*60,			# cache time in seconds
		MaxAge => 4,						# flush time in hours
    Verbose => $opt->{debug},
} );


# ------------------------------------------------------------------------------------------------------------------------------------- #
# Used by the configure sub
my @platforms;
my $selected_region;
my $platform_title; my $region_title;


# ------------------------------------------------------------------------------------------------------------------------------------- #
# Check we have all our required conf params
config_check();

# Load the conf file containing mapped channels and categories information
my %mapchannelhash;
my %mapcategoryhash;
loadmapconf();

# Load the category (genre) mappings for Press Association data
my %mapgenrehash;
loadmapgenre();



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Progress Bar :)
my $bar = new XMLTV::ProgressBar({
  name => "Fetching listings",
  count => ( $opt->{'channel'} ne '' ? 1 : (scalar @{$conf->{channel}}) )
}) unless ($opt->{quiet} || $opt->{debug});



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Data store before being written as XML
my $programmes = ();
my $channels = ();

# Get the schedule(s) from Atlas
fetch_listings();

#print Dumper($programmes);

# Progress Bar
$bar->finish() && undef $bar if defined $bar;



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Generate the XML
my $encoding = 'UTF-8';
my $credits = { 'generator-info-name' => $generator_info_name,
								'generator-info-url' => $generator_info_url };
$credits->{'source-info-name'} = $conf->{'source-info-name'}->[0] 	if (defined( $conf->{'source-info-name'} ));
$credits->{'source-info-url'} = $conf->{'source-info-url'}->[0]			if (defined( $conf->{'source-info-url'} ));
	
XMLTV::write_data([ $encoding, $credits, $channels, $programmes ]);
# Finished!



# ------------------------------------------------------------------------------------------------------------------------------------- #
# Signal that something went wrong if there were warnings.
exit(1) if $warnings;

# All data fetched ok.
t "Exiting without warnings.";
exit(0);


# #############################################################################
# # THE MEAT #####################################################################
# ------------------------------------------------------------------------------------------------------------------------------------- #
sub fetch_listings {
		# Fetch listings per channel
		
		# Specific channel requested on commandline?  Else use normal conf file.
		if ($opt->{'channel'} ne '') {
				undef @{$conf->{channel}};
				push @{$conf->{channel}}, $opt->{'channel'};
		}
		
		foreach my $channel_id (@{$conf->{channel}}) {
			# 
			# Construct the url
			# http://atlas.metabroadcast.com/3.0/schedule.json?apiKey=*****************&publisher=pressassociation.com&from=now&to=now.plus.6h&channel_id=cbbh&annotations=channel,brand_summary,series_summary,extended_description,broadcasts
			# https://atlas.metabroadcast.com/3.0/schedule.json?channel_id=cbbh&publisher=bbc.co.uk&annotations=channel,description,broadcasts,brand_summary&from=2013-09-08T00:00:00.000Z&to=2013-09-09T00:00:00.000Z
			
			# Atlas accepts from/to params of the form  "2013-09-08T00:00:00.000Z"  or like  "now.plus.6h"
			# This grabber accepts either  (i) --days and  --offset   or   (ii) --hours  and  --offset   or  (iii) --date YYYYMMDD
			#			(in (i) the --offset is in days; in (ii) it's hours)
			#
			my $from = '';
			my $to = '';		
			if ($opt->{offset} eq '') { $opt->{offset} = 0; }
			
			if ($opt->{date}) {
				$from = str2time( $opt->{date} );
				$to 	= $from + 86400;
			
			} elsif ($opt->{hours}) {				# test 'hours' first since 'days' defaults to '5'
				if ($opt->{offset} gt 0) 		{ $from = 'now.plus.'.$opt->{offset}.'h'; }
				elsif ($opt->{offset} lt 0) { $from = 'now.minus.'.abs($opt->{offset}).'h'; }
				else { $from = 'now'; }
			
				if (($opt->{hours} + $opt->{offset}) gt 0)		 { $to = 'now.plus.'. ($opt->{hours} + $opt->{offset}).'h'; }
				elsif (($opt->{hours} + $opt->{offset}) lt 0)  { $to = 'now.minus.'.abs($opt->{hours} + $opt->{offset}).'h'; }
				else { $to = 'now'; }
			
			} elsif ($opt->{days}) {
				$from = DateTime->today->add( days => $opt->{offset} )->set_time_zone('Europe/London')->epoch();
				$to 	= DateTime->today->add( days => ($opt->{offset} + $opt->{days}) )->set_time_zone('Europe/London')->epoch();
	
			} else {											# unlikely to get here since 'days' defaults to '5'
				# default to today only
				#		(Atlas accepts epoch times)
				#		$from = DateTime->today->set_time_zone('Europe/London')->strftime('%Y-%m-%dT00:00:00.000Z');
				#		$to 	= DateTime->today->add ( days => 1 )->set_time_zone('Europe/London')->strftime('%Y-%m-%dT00:00:00.000Z');
				$from = DateTime->today->set_time_zone('Europe/London')->epoch();
				$to 	= DateTime->today->add ( days => 1 )->set_time_zone('Europe/London')->epoch();
			}
			
			
			my $baseurl = $ROOT_URL.'schedule.json';
			my $apiKey = readpipe("cat ".$conf->{'api-key'}->[0]);
			chomp($apiKey); chop($apiKey) if ($apiKey =~ m/\r$/);
			my $publisher = 'pressassociation.com';
			my $annotations = 'extended_description,broadcasts,series_summary,brand_summary,people';

			my $url = $baseurl.'?'."channel_id=$channel_id&from=$from&to=$to&annotations=$annotations&publisher=$publisher&apiKey=$apiKey";
			print $url ."\n" 	if ($opt->{debug});exit;
			#print STDERR "$url \n";
			
			if (1) {
		
				# If we need to map the fetched channel_id to a different value
				my $xmlchannel_id = $channel_id;
				if (defined(&map_channel_id)) { $xmlchannel_id = map_channel_id($channel_id); }
				my $channelname = $xmlchannel_id;
				
				# Add to the channels hash
				$channels->{$channel_id} = { 'id'=> $xmlchannel_id , 'display-name' => [[$channelname, 'en']]  };
				
				# Fetch the page
				my $res = $lwp->get( $url );
				
				if ($res->is_success) {
						#print $res->content;
						get_schedule_from_json($xmlchannel_id, $res->content);
				} else {
						print $res->status_line . "\n";
				}
					
				$bar->update if defined $bar;
			}
		}
}

# ------------------------------------------------------------------------------------------------------------------------------------- #
sub get_schedule_from_json {
		#  Extract the schedule for this channel.
		#
		#  Credit: Gordon M.Lack (http://birdman.dynalias.org/xmltv-from-Atlas/) for some of the original data abstraction principles used here.
		#

		my( $channel_id, $input ) = @_;
		my $data = JSON::PP->new()->utf8(0)->decode($input);
		$input = undef;

		my $prog_item = $data->{'schedule'}[0]->{'items'};
		foreach my $p (@$prog_item) {
				my %prog = %$p;
		
				my %item = ();
				
				# "What is on the item is the episode title. To get the brand title (which is normally what you will want to display in a schedule) 
				#  	you need to take the title of the parent container (which you can include using the brand_summary annotation).
				#	 	Where an item is not in a container, the item title should be used.
				#  Title is: container.title or item.title if no container
				#	 Subtitle is: item.title if container, otherwise empty"  (Jonathan Tweed)
				#
				# e.g. "title": "Ford's Dagenham Dream",  (with no "brand" container)
				#		gives title = Ford's Dagenham Dream   episode = 
				# but
				#      	"title": "Fatal Attraction",
				#			"container": { "title": "The Sky at Night", ...  "type": "brand" }
				# 	gives title = The Sky at Night   episode = Fatal Attraction
				#
				$item{'title'}   			= defined($prog{'title'}) ? $prog{'title'} : '';
				$item{'episodetitle'} = '';
				
				if ( (exists $prog{'container'}) && ($prog{'container'}->{'type'} eq 'brand') ) {
						# Only fetch if it is not blank, and differs from the main title.
						my $eptitle = $prog{'container'}->{'title'};
						if ($eptitle  and ($eptitle ne $item{'title'})) {
								$item{'episodetitle'} = $item{'title'};
								$item{'title'}   = $eptitle;
						}
				}

				$item{'desc'}							= defined($prog{'description'}) ? $prog{'description'} : '';
				$item{'epno'}							= defined($prog{'episode_number'}) ? $prog{'episode_number'} : '';
				$item{'seriesno'}					= defined($prog{'series_number'}) ? $prog{'series_number'} : '';
				$item{'totaleps'} 				= '';
				if ( (exists $prog{'series_summary'}) && ($prog{'series_summary'}->{'type'} eq 'series') ) {
						$item{'totaleps'} 		= defined($prog{'series_summary'}->{'total_episodes'}) ? $prog{'series_summary'}->{'total_episodes'} : '';
				}

				$item{'image'}						= defined($prog{'image'}) ? $prog{'image'} : '';
				$item{'media'}						= defined($prog{'mediaType'}) ? $prog{'mediaType'} : '';
				$item{'year'}							= defined($prog{'year'}) ? $prog{'year'} : '';
				$item{'film'}							= (defined($prog{'type'}) && $prog{'type'} eq 'film') ? true : false;
				$item{'black_and_white'}	= (defined($prog{'black_and_white'}) && $prog{'black_and_white'} eq 'false') ? true : false;
				$item{'star_rating'}			= '';			# sadly not available in Atlas  :-(
				$item{'certificate'}			= ''; 
				$item{'certificate_code'}	= '';
				if (exists $prog{'certificates'}) {
						$item{'certificate'} 	= defined($prog{'certificates'}[0]->{'classification'}) ? $prog{'certificates'}[0]->{'classification'} : '';
						$item{'certificate_code'} = defined($prog{'certificates'}[0]->{'code'}) ? $prog{'certificates'}[0]->{'code'} : '';
				}
				
				# Store all the (unique) genres. Map them to alternative name if requested.
				#
				$item{'genres'} = {};				# use a hash so we can auto-ignore duplicate values
				foreach my $gtext (@{$prog{'genres'}}) {
						if ($gtext =~ m|^http://pressassociation.com/genres/(.*)|) {
								$item{'genres'}->{ map_category( uc_words( map_PA_category($1) ) ) } = 1; 
								# (nb: if genre not found then the code will be passed through to XML - this way we can spot any which are missing
						}
						elsif ( $gtext =~ m|^http://ref.atlasapi.org/genres/atlas/(.*)|) {
								$item{'genres'}->{ map_category( uc_words( $1 ) ) } = 1; 
						}
				}
				
				# Get the people information
				#		(note: Commentator and Presenter are defined with <role> = 'actor' 
				#			e.g.  <character>Presenter</character> <displayRole>Actor</displayRole> <name>Suzi Perry</name> <role>actor</role>
				#					<character>Commentator</character> <displayRole>Actor</displayRole> <name>David Coulthard</name> <role>actor</role>
				#
				@{$item{'actors'}}  		= ();
				@{$item{'directors'}} 	= ();
				foreach my $person (@{$prog{'people'}}) {
					SWITCH: {
							$person->{'role'} eq 'director' && do { push @{$item{'directors'}}, $person->{'name'}; last SWITCH; };
							$person->{'role'} eq 'actor' 		&& do { push @{$item{'actors'}}, $person->{'name'}; 	 last SWITCH; };
					}
				}


				# Now we process all of the broadcasts of the programme and add each one to the schedule along with its per-broadcast info.
				# Atlas allow for multiple broadcasts per programme (although this seems unused at present).
				#
				foreach my $b (@{$prog{'broadcasts'}}) {
						my %bdc = %$b;			
						my %bcast = ();
						
						$bcast{'premiere'}      = (defined($bdc{'premiere'}) && $bdc{'premiere'} eq 'true') ? true : false;
						$bcast{'repeat'}      	= (defined($bdc{'repeat'}) && $bdc{'repeat'} eq 'true') ? true : false;
						$bcast{'subtitles'}			= (defined($bdc{'subtitled'}) && $bdc{'subtitled'} eq 'true') ? true : false;
						$bcast{'new_series'}		= (defined($bdc{'new_series'}) && $bdc{'new_series'} eq 'true') ? true : false;
						$bcast{'deaf_signed'}		= (defined($bdc{'signed'}) && $bdc{'signed'} eq 'true') ? true : false;
						$bcast{'widescreen'}		= (defined($bdc{'widescreen'}) && $bdc{'widescreen'} eq 'true') ? true : false;

						$bcast{'start'} = str2time( $bdc{'transmission_time'} );
						$bcast{'stop'}  = str2time( $bdc{'transmission_end_time'} );
						
						# Convert the broadcast/programme to XMLTV format
						add_programme_to_xml($channel_id, \%item, \%bcast);
				}
		}
}

# ------------------------------------------------------------------------------------------------------------------------------------- #
sub add_programme_to_xml {
		# Add a programme to the XML hash
		#
		# <!ELEMENT programme (title+, sub-title*, desc*, credits?, date?,
		#										 category*, language?, orig-language?, length?,
		#										 icon*, url*, country*, episode-num?, video?, audio?,
		#										 previously-shown?, premiere?, last-chance?, new?,
		#										 subtitles*, rating*, star-rating? )>
		# <!ATTLIST programme start     CDATA #REQUIRED
		#										stop      CDATA #IMPLIED
		#										pdc-start CDATA #IMPLIED
		#										vps-start CDATA #IMPLIED
		#										showview  CDATA #IMPLIED
		#										videoplus CDATA #IMPLIED
		#										channel   CDATA #REQUIRED
		#										clumpidx  CDATA "0/1" >
		# <!ELEMENT credits (director*, actor*, writer*, adapter*, producer*,
		#								      presenter*, commentator*, guest* )>
		# <!ELEMENT video (present?, colour?, aspect?)>
		#
		
		my ($channel_id, $item, $bcast) = @_;
		my %item = %$item;
		my %bcast = %$bcast;
		my %xmlprog = ();		
				
		$xmlprog{'channel'} 				= $channel_id;
		$xmlprog{'start'} 					= DateTime->from_epoch( epoch => $bcast{'start'} )->strftime("%Y%m%d%H%M%S %z");
		$xmlprog{'stop'} 						= DateTime->from_epoch( epoch => $bcast{'stop'} )->strftime("%Y%m%d%H%M%S %z");

		$xmlprog{'title'} 					= [[ $item{'title'}, 'en' ]];
		$xmlprog{'sub-title'} 			= [[ $item{'episodetitle'}, 'en' ]] 						if ($item{'episodetitle'});
		$xmlprog{'desc'} 						= [[ $item{'desc'}, 'en' ]] 										if ($item{'desc'});
		
		my $showepnum = make_ns_epnum($item{'seriesno'}, $item{'epno'}, $item{'totaleps'});
		$xmlprog{'episode-num'} 		= [[ $showepnum, 'xmltv_ns' ]]									if ($showepnum && $showepnum ne '..');
				
		if (scalar @{$item{'directors'}} > 0) {
			foreach my $showdirector ( @{$item{'directors'}}) {
				push @{$xmlprog{'credits'}{'director'}}, $showdirector;
			}
		}
		if (scalar @{$item{'actors'}} > 0) {
			foreach my $showactor ( @{$item{'actors'}}) {
				push @{$xmlprog{'credits'}{'actor'}}, $showactor;
			}
		}
		
		$xmlprog{'date'} = $item{'year'} 														if $item{'year'};
		push @{$xmlprog{'icon'}}, {'src' => $item{'image'}} 				if $item{'image'};

		# add 'Film' genre if it's a film
		if ($item{'film'}) {
				$item{'genres'}->{ map_category('Film') } = 1; 
		}
		if (scalar (keys %{$item{'genres'}}) > 0) {		
			while (my ($key, $value) = each %{$item{'genres'}}) {
				push @{$xmlprog{category}}, [ $key, 'en' ];
			}
		}
			
		push @{$xmlprog{'subtitles'}}, {'type' => 'teletext'} 			if $bcast{'subtitles'};
		push @{$xmlprog{'subtitles'}}, {'type' => 'deaf-signed'} 		if $bcast{'deaf_signed'};
		$xmlprog{'premiere'} = {} 																	if $bcast{'premiere'};
		$xmlprog{'previously-shown'} = {} 													if $bcast{'repeat'};
		$xmlprog{'video'}->{'present'} = 'yes' 											if $bcast{'media'} && $bcast{'media'} eq 'video';
		$xmlprog{'video'}->{'present'} = 'no' 											if $bcast{'media'} && $bcast{'media'} eq 'audio';
		$xmlprog{'video'}->{'colour'} = 'no' 												if $bcast{'black_and_white'};
		$xmlprog{'rating'} = [[ $item{'certificate'}, $item{'certificate_code'} ]]	if $item{'certificate'};
		$xmlprog{'star-rating'} =  [ $item{'star_rating'} . '/5' ]	if $item{'star_rating'};

		#print Dumper \%xmlprog;
		push(@{$programmes}, \%xmlprog);
		
		return;
}
						
						
									
# #############################################################################
# # THE VEG ######################################################################
# ------------------------------------------------------------------------------------------------------------------------------------- #

sub make_ns_epnum {
		# Convert an episode number to its xmltv_ns compatible - i.e. reset the base to zero
		# Input = series number, episode number, total episodes,  part number, total parts,
		#  e.g. "1, 3, 6, 2, 4" >> "0.2/6.1/4",    "3, 4" >> "2.3."
		#
		my ($s, $e, $e_of, $p, $p_of) = @_;
		#print Dumper(@_);

		# "Part x of x" may contain integers or words (e.g. "Part 1 of 2", or "Part one")
		$p = text_to_num($p) if defined $p;
		$p_of = text_to_num($p_of) if defined $p_of;
		
		# re-base the series/episode/part numbers
		$s-- if (defined $s && $s ne '');
		$e-- if (defined $e && $e ne '');
		$p-- if (defined $p && $p ne '');
		
		# make the xmltv_ns compliant episode-num
		my $episode_ns = '';
		$episode_ns .= $s if (defined $s && $s ne '');
		$episode_ns .= '.';
		$episode_ns .= $e if (defined $e && $e ne '');
		$episode_ns .= '/'.$e_of if (defined $e_of && $e_of ne '');
		$episode_ns .= '.';
		$episode_ns .= $p if (defined $p && $p ne '');
		$episode_ns .= '/'.$p_of if (defined $p_of && $p_of ne '');
		
		#print "--$episode_ns--";
		return $episode_ns;
}

sub text_to_num {
		# Convert a word number to int e.g. 'one' >> '1'
		#
		my ($text) = @_;
		if ($text !~ /^[+-]?\d+$/) {	# standard test for an int
			my %nums = (one => 1, two => 2, three => 3, four => 4, five => 5, six => 6, seven => 7, eight => 8, nine => 9);
			return $nums{$text} if exists $nums{$text};
		}
		return $text
}

sub map_channel_id {
		# Map the fetched channel_id to a different value (e.g. our PVR needs specific channel ids)
		# mapped channels should be stored in a file called  tv_grab_uk_atlas.map.conf
		# containing lines of the form:  map==fromchan==tochan  e.g. 'map==5-star==5STAR'
		#
		my ($channel_id) = @_;
		if (%mapchannelhash && exists $mapchannelhash{$channel_id}) { 
			return $mapchannelhash{$channel_id} ; 
		}
		return $channel_id;
}

sub map_category {
		# Map the fetched category to a different value (e.g. our PVR needs specific genres)
		# mapped categories should be stored in a file called  tv_grab_uk_atlas.map.conf
		# containing lines of the form:  cat==fromcategory==tocategory  e.g. 'cat==General Movie==Film'
		#
		my ($category) = @_;
		if (%mapcategoryhash && exists $mapcategoryhash{$category}) { 
			return $mapcategoryhash{$category} ; 
		}
		return $category;
}

sub map_PA_category {
		# Press Association uses codes for categories
		#		e.g. '1400' means 'Comedy'
		# Map the fetched category code to its genre
		#
		my ($category) = @_;
		if (%mapgenrehash && exists $mapgenrehash{$category}) { 
			return $mapgenrehash{$category} ; 
		}
		return $category;
}

sub loadmapconf {
		# Load the conf file containing mapped channels and categories information
		# 
		# This file contains 2 record types:
		# 	lines starting with "map" are used to 'translate' the Atlas channel id to those required by your PVR
		#			e.g. 	map==cbjc==DAVE     will output "DAVE" in your XML file instead of "cbjc"
		# 	lines starting with "cat" are used to translate categories (genres) in the Atlas data to those required by your PVR
		# 		e.g.  cat==Science Fiction==Sci-fi			will output "Sci-Fi" in your XML file instead of "Science Fiction"
		#

		my $mapchannels = \%mapchannelhash;
		my $mapcategories = \%mapcategoryhash;
		#		
		my $fn = get_supplement_dir() . '/'. $GRABBER_NAME . '.map.conf';
		my $fhok = open my $fh, '<', $fn or warning("Cannot open conf file $fn");
		if ($fhok) {
			while (my $line = <$fh>) { 
				chomp $line;
				chop($line) if ($line =~ m/\r$/);
				my ($type, $mapfrom, $mapto) = $line =~ /^(.*)==(.*)==(.*)$/;
				SWITCH: {
						lc($type) eq 'map' && do { $mapchannels->{$mapfrom} = $mapto; last SWITCH; };
						lc($type) eq 'cat' && do { $mapcategories->{$mapfrom} = $mapto; last SWITCH; };
						warning("Unknown type in map file: \n $line");
				}
			}
			close $fh;
		}
		# print Dumper ($mapchannels, $mapcategories);
}

sub loadmapgenre {
		# Load the file containing mappings for Press Association categories (genres)
		#		(nb: this could be incorporated into the ".map.conf" file perhaps ?)
		# 
		# Credit: Gordon M.Lack for creating the original list (http://birdman.dynalias.org/xmltv-from-Atlas/)
		#  derived from https://github.com/atlasapi/atlas/src/main/java/org/atlasapi/remotesite/pa/PaGenreMap.java
		#  but with additions from looking at the xmltv feed
		#
		
		my $mapgenrehash = \%mapgenrehash;
		#		
		my $fn = get_supplement_dir() . '/'. $GRABBER_NAME . '.map.genre.conf';
		my $fhok = open my $fh, '<', $fn or warning("Cannot open genre file $fn");
		if ($fhok) {
			while (my $line = <$fh>) { 
				chomp $line;
				chop($line) if ($line =~ m/\r$/);
				my ($mapfrom, $mapto) = $line =~ /^(.*)==(.*)$/;
				$mapgenrehash->{$mapfrom} = $mapto;
			}
			close $fh;
		}
		# print Dumper ($mapgenrehash);
}

sub fetch_channels {
		# Fetch Atlas' channels for a Region for a Platform
		
		my ($conf, $opt) = @_;
	
		# temporary diversion...
		# Store some extra data in the conf file (just for info)
		#
		# Ideally we would do this in config_stage but that will only write data captured va 'Ask'
		# 	(i.e. we can't add our own data).  Neither does it have the $opt array with the config_file 
		#		name so we can't even write it manually!  The only place we can do that is here.
		#
		open OUT, ">> ".$opt->{'config-file'}
				or die "Failed to open $opt->{'config-file'} for writing";
		print OUT "api-key=".get_supplement_dir()."/atlasAPIkey\n";
		print OUT "platform-title=$platform_title\n";
		print OUT "region-title=$region_title\n";
		close OUT;
		#  ...now back to the normal listchannels_sub

	
		#		http://atlas.metabroadcast.com/3.0/channel_groups/cbhN.json?annotations=channels 
		#
		# Region code is $selected_region  (captured by select-region in config_stage()
		my $url = $ROOT_URL.'channel_groups/'.$selected_region.'.json?annotations=channels';
		print $url ."\n" 	if ($opt->{debug});

		my @channels = ();

		my $bar = new XMLTV::ProgressBar({
			name => "Fetching channels",
			count => 1
		});

		# Fetch the page
		my $res = $lwp->get( $url );
		
		if ($res->is_success) {
				#print $res->content;
				
				# Extract the available channels
				my $data = JSON::PP->new()->utf8(0)->decode($res->content);
				$res = undef;

				my $channels = $data->{'channel_groups'}[0]->{'channels'};
				foreach my $c (@$channels) {
						my %chan = %$c;
						next unless ($chan{'channel'}->{'type'} eq 'channel');
				
						my %channel = ();
				
						$channel{'num'} 	= $chan{'channel_number'};
						$channel{'id'} 		= $chan{'channel'}->{'id'};
						$channel{'title'} = $chan{'channel'}->{'title'};
						
						push @channels, \%channel;
				}
				
		} else {
				print $res->status_line . "\n";
		}
	
		$bar->update() && $bar->finish && undef $bar if defined $bar;
		
		#print Dumper(@channels);

		
		# We must return an xml-string (c.f. Options.pm), E.g.:
		#  	<channel id="cbbR">
    #			<display-name lang="en">BBC News Channel</display-name>
		#		</channel>
		#		<channel id="cbbT">
    #			<display-name lang="en">BBC Parliament</display-name>
		#		</channel>
		#
		# Map the list of channels to a hash XMLTV::Writer will understand
		my $channels_conf = {};
		foreach my $c (@channels) {
			my %channel = %$c;
			$channels_conf->{$channel{'num'}} = {
				id => $channel{'id'},
				'display-name' => [[ $channel{'title'}, 'en' ]],
			}
		}
		#
		# Let XMLTV::Writer format the results as xml. 
		my $result;
		my $writer = new XMLTV::Writer(OUTPUT => \$result, encoding => 'UTF-8');
		$writer->start({'generator-info-name' => $generator_info_name});
		$writer->write_channels($channels_conf);
		$writer->end();
		return $result;
}

sub fetch_platforms {
		# Fetch Atlas' channel_groups
		
		# (note: $opt & $conf have not been returned by ParseOptions() yet, since that hasn't exited yet)
		
		#		http://atlas.metabroadcast.com/3.0/channel_groups.json?type=platform
		my $url = $ROOT_URL.'channel_groups.json?type=platform';
		#print $url ."\n";

		@platforms = ();

		my $bar = new XMLTV::ProgressBar({
			name => "Fetching platforms",
			count => 1
		});

		
		# Fetch the page
		my $res = $lwp->get( $url );
		
		if ($res->is_success) {
				#print $res->content;
				
				# Extract the available platforms
				my $data = JSON::PP->new()->utf8(0)->decode($res->content);
				$res = undef;

				my $channel_group = $data->{'channel_groups'};
				foreach my $g (@$channel_group) {
						my %group = %$g;
						next unless ($group{'type'} eq 'platform');
				
						my %platform = ();
				
						$platform{'id'} = $group{'id'};
						$platform{'title'} = $group{'title'};
						
						$platform{'countries'} = '';
						foreach my $country (@{$group{'available_countries'}}) {
							$platform{'countries'} .= '(' . $country . ')';
						}
						
						$platform{'regions'} = ();
						foreach my $region (@{$group{'regions'}}) {
							push @{$platform{'regions'}},  { 'id' => $region->{'id'}, 'title' =>  $region->{'title'} };
						}
						
						push @platforms, \%platform;
				}
				
		} else {
				print $res->status_line . "\n";
		}
	
		$bar->update if defined $bar;
		$bar->finish() && undef $bar if defined $bar;
		
		return @platforms;
}

sub config_stage {
		my( $stage, $conf ) = @_;				# note that $conf is mostly empty at this stage of course

		my $result;
		my $writer = new XMLTV::Configure::Writer( OUTPUT => \$result, encoding => 'UTF-8' );
		$writer->start( { grabber => $GRABBER_NAME } );
			
		# ------------------------------------------------------------------ #
		if ( ($stage eq 'start') ||
			 ($stage eq 'select-cache') ) {
			 
        $writer->write_string( {
						id => 'cachedir', 
						title => [ [ 'Directory to store the cache', 'en' ] ],
						description => [ [ $GRABBER_NAME.' uses a cache with files that it has already downloaded. Please specify a location for this cache.', 'en' ] ],
						default => get_default_cachedir(),
        } );
				
        $writer->end('select-platform');
				
    }	
		# ------------------------------------------------------------------ #
    elsif ($stage eq 'select-platform') {

				fetch_platforms();
				
        $writer->start_selectone( {
            id => 'platform',
            title => [ [ 'Choose your viewing platform', 'en' ] ],
            description => [ [ $GRABBER_NAME.' selects channels to download based on your viewing platform.', 'en' ] ],
        } );
				
				foreach my $p (@platforms) {
						my %platform = %$p;
						next unless defined $platform{'regions'};
		
						$writer->write_option( {
								value => $platform{'id'},
								text => [ [ $platform{'title'} . ' ' . $platform{'countries'}, 'en' ] ],
						} );
				}
				
        $writer->end_selectone();
				$writer->end('select-region');
				
    }		
		# ------------------------------------------------------------------ #
    elsif ($stage eq 'select-region') {
				
        $writer->start_selectone( {
            id => 'region',
            title => [ [ 'Choose your viewing region', 'en' ] ],
            description => [ [ $GRABBER_NAME.' selects channels to download based on your TV region.', 'en' ] ],
        } );
			
				foreach my $p (@platforms) {
						my %platform = %$p;
						next unless $platform{'id'} eq $conf->{'platform'}[0];
				
						foreach my $r (@{$platform{'regions'}}) {
								my %region = %$r;
		
								$writer->write_option( {
										value => $region{'id'},
										text => [ [ $region{'title'}, 'en' ] ],
								} );
								
						}
				}
				
        $writer->end_selectone();
				$writer->end('select-done');

    }
		# ------------------------------------------------------------------ #
    elsif ($stage eq 'select-done') {
		
				# Store some extra data in the conf file (just for info)
				#
				# Can't use $conf for this since configure_stage() only writes values it collects (i.e. it doesn't write the hash itself)
				#
				
				foreach my $p (@platforms) {
						my %platform = %$p;
						next unless $platform{'id'} eq $conf->{'platform'}[0];
						
						#$conf->{'platform-title'} = [ $platform{'title'} ];
						$platform_title = $platform{'title'};
						
						foreach my $r (@{$platform{'regions'}}) {
								my %region = %$r;
								next unless $region{'id'} eq $conf->{'region'}[0];
							
								#$conf->{'region-title'} = [ $region{'title'} ];
								$region_title = $region{'title'};
								last;
						}
						
						last;
				}

				# Store the selected region for use by 'select-channels'
				$selected_region = $conf->{'region'}[0];
				$writer->end('select-channels');
				
		}
		# ------------------------------------------------------------------ #
    else {
        die "Unknown stage $stage";
    }

		# ------------------------------------------------------------------ #
		return $result;
}

sub config_check {
		if (not defined( $conf->{cachedir} )) {
				print STDERR "No cachedir defined in configfile " . 
										 $opt->{'config-file'} . "\n" .
										 "Please run the grabber with --configure.\n";
				exit 1;
		}

		if (not defined( $conf->{'channel'} )) {
				print STDERR "No channels selected in configfile " .
										 $opt->{'config-file'} . "\n" .
										 "Please run the grabber with --configure.\n";
				exit 1;
		}

		if (not defined( $conf->{'api-key'} )) {
				print STDERR "No api-key filename in configfile " .
										 $opt->{'config-file'} . "\n" .
										 "Please run the grabber with --configure.\n";
				exit 1;
		}
}

sub get_default_dir {
    my $winhome = $ENV{HOMEDRIVE} . $ENV{HOMEPATH} 
			if defined( $ENV{HOMEDRIVE} ) 
					and defined( $ENV{HOMEPATH} ); 
    
    my $home = $ENV{HOME} || $winhome || ".";
    return $home;
}

sub get_supplement_dir {
		return $ENV{XMLTV_SUPPLEMENT}  if defined( $ENV{XMLTV_SUPPLEMENT} );
    return get_default_dir() . "/.xmltv/supplement/" . $GRABBER_NAME;
}

sub get_default_cachedir {
    return get_default_dir() . "/.xmltv/cache";
}

sub init_cachedir {
    my( $path ) = @_;
    if( not -d $path ) {
        mkpath( $path ) or die "Failed to create cache-directory $path: $@";
    }
}

sub initialise_ua {
		my $cookies = HTTP::Cookies->new;
		#my $ua = LWP::UserAgent->new(keep_alive => 1);
		my $ua = LWP::UserAgent->new;
		# Cookies
		$ua->cookie_jar($cookies);
		# Define user agent type
		$ua->agent('Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.0; Trident/5.0');
		# Define timouts
		$ua->timeout(240);
		# Use proxy if set in http_proxy etc.
		$ua->env_proxy;
		
		return $ua;
}

sub uc_words {
	# Uppercase the first letter of each word
	my ($string) = @_;
	$string =~ s/\b(\w)/\U$1/g;
	return $string;
}

sub t {
    my( $message ) = @_;
    print STDERR $message . "\n" if $opt->{debug};
}

sub warning {
    my( $message ) = @_;
    print STDERR $message . "\n";
    $warnings++;
}

# #############################################################################

__END__

=pod

=head1 NAME

tv_grab_uk_atlas - Grab TV listings for UK from Atlas Metabroadcast website.

=head1 SYNOPSIS

tv_grab_uk_atlas --help
  
tv_grab_uk_atlas --version

tv_grab_uk_atlas --capabilities

tv_grab_uk_atlas --description

tv_grab_uk_atlas [--config-file FILE]
           [--days N] [--offset N]
           [--output FILE] [--quiet] [--debug]

tv_grab_uk_atlas [--config-file FILE]
           [--hours N] [--offset N]
           [--output FILE] [--quiet] [--debug]

tv_grab_uk_atlas [--config-file FILE]
           [--date DATE] 
           [--output FILE] [--quiet] [--debug]

tv_grab_uk_atlas --configure [--config-file FILE]

tv_grab_uk_atlas --configure-api [--stage NAME]
           [--config-file FILE]
           [--output FILE]

tv_grab_uk_atlas --list-channels [--config-file FILE]
           [--output FILE] [--quiet] [--debug]

=head1 DESCRIPTION

Output TV listings in XMLTV format for many channels available in UK.
The data come from http://atlas.metabroadcast.com

First you must run B<tv_grab_uk_atlas --configure> to choose which channels
you want to receive.

Then running B<tv_grab_uk_atlas> with no arguments will get a listings in XML
format for the channels you chose for available days including today.

=head1 OPTIONS

B<--configure> Prompt for which channels to download and write the
configuration file.

B<--config-file FILE> Set the name of the configuration file, the
default is B<~/.xmltv/tv_grab_uk_atlas.conf>.  This is the file written by
B<--configure> and read when grabbing.

B<--output FILE> When grabbing, write output to FILE rather than
standard output.

B<--hours N> When grabbing, grab N hours of data.

B<--days N> When grabbing, grab N days rather than all available days.

B<--offset N> Start grabbing at today/now + N days.  When B<--hours> is used
this is number of hours instead of days.  N may be negative.

B<--quiet> Suppress the progress-bar normally shown on standard error.

B<--debug> Provide more information on progress to stderr to help in
debugging.

B<--list-channels> Write output giving <channel> elements for every
channel available (ignoring the config file), but no programmes.

B<--capabilities> Show which capabilities the grabber supports. For more
information, see L<http://wiki.xmltv.org/index.php/XmltvCapabilities>

B<--version> Show the version of the grabber.

B<--help> Print a help message and exit.

=head1 ERROR HANDLING

If the grabber fails to download data for some channel on a specific day, 
it will print an errormessage to STDERR and then continue with the other
channels and days. The grabber will exit with a status code of 1 to indicate 
that the data is incomplete. 

=head1 ENVIRONMENT VARIABLES

The environment variable HOME can be set to change where configuration
files are stored. All configuration is stored in $HOME/.xmltv/. On Windows,
it might be necessary to set HOME to a path without spaces in it.

=head1 SUPPORTED CHANNELS

For information on supported channels, see ???

=head1 AUTHOR

Geoff Westcott. This documentation and parts of the code
based on various other tv_grabbers from the XMLTV-project.

=head1 COPYRIGHT

Copyright (C) 2013 Geoff Westcott.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the 
Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, 
Boston, MA  02110-1301, USA.

=head1 SEE ALSO

L<xmltv(5)>.

=cut

