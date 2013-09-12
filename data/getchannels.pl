#!/usr/bin/perl -w
#
# Get all the platforms and regions and channels and their mapping from Atlas and create 'map' files.
# (Also try to auto-map against the RT grabber's channel_ids file)
#
#
# Copyright G. Westcott - September 2013
#
# This code is distributed under the GNU General Public License v2 (GPLv2) .
#
# 

use strict;
use warnings;
use constant { true => 1, false => 0 };
use Data::Dumper;

use File::Path;
use POSIX qw(strftime);
use DateTime;
use Date::Parse;
use Encode;
use URI::Escape;

use JSON::PP;
use HTTP::Cookies;
use LWP::UserAgent;
my $lwp = initialise_ua();

my $debug = '1';

# ------------------------------------------------------------------------------------------------------------------------------------- #
# Let's play nice and use a short-term cache to reduce load on Atlas site
#
use HTTP::Cache::Transparent;
HTTP::Cache::Transparent::init( { 
    BasePath => '/tmp/cache/',
    NoUpdate => 60*60,			# cache time in seconds
		MaxAge => 4,						# flush time in hours
    Verbose => $debug,
} );


# ------------------------------------------------------------------------------------------------------------------------------------- #
# Get the channels from Atlas
my $ROOT_URL = 'http://atlas.metabroadcast.com/3.0/';
my $platforms = ();
my $channels = ();

get_channels();


# ------------------------------------------------------------------------------------------------------------------------------------- #
exit(0);


# #############################################################################
# # THE MEAT #####################################################################
# ------------------------------------------------------------------------------------------------------------------------------------- #

sub get_channels {

		fetch_platforms();
		#print Dumper($platforms);
		print_platforms();
		fetch_channels();
		#print Dumper($channels);exit;
		print_channels();
		print_channels_RT();
		
		return;
}



sub fetch_platforms {
		# Fetch Atlas' channel_groups
		
		#		http://atlas.metabroadcast.com/3.0/channel_groups.json?type=platform
		my $url = $ROOT_URL.'channel_groups.json?type=platform';
		#print $url ."\n";

		# Fetch the page
		my $res = $lwp->get( $url );
		
		if ($res->is_success) {
				#print $res->content;
				
				# Extract the available platforms
				my $data = JSON::PP->new()->utf8(0)->decode($res->content);
				$res = undef;

				my $channel_group = $data->{'channel_groups'};
				foreach (@$channel_group) {
						my %group = %$_;
						next unless ($group{'type'} eq 'platform');
				
						my %platform = ();
				
						$platform{'id'} 				= $group{'id'};
						$platform{'title'} 			= $group{'title'};
						$platform{'uri'} 				= $group{'uri'};
						#$platform{'available_countries'} 	= $group{'available_countries'};
						$platform{'countries'} = '';
						foreach my $country (@{$group{'available_countries'}}) {
							$platform{'countries'} .= $country . ($platform{'countries'} ne '' ? ' ' : '');
						}
						
						$platform{'regions'} = ();
						foreach my $region (@{$group{'regions'}}) {
							push @{$platform{'regions'}},  { 'id' => $region->{'id'}, 'title' =>  $region->{'title'} };
						}
						
						push @{$platforms}, \%platform;
				}
				
		} else {
				print $res->status_line . "\n";
		}
	
		return;
}

sub print_platforms {
		# Write a file of all the Atlas platforms with  id==title  ("platforms.txt")
		# Write a file of all the Atlas regions for each platform with  id==title   ("regions_xxxx.txt")
		#
		my $f = 'platforms.txt';
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# PLATFORMS'."\n";
		
		foreach (@{$platforms}) {
				my %p = %$_;
				
				#printf '%s  %s '."\n", $p{'id'}, $p{'title'} ;
				printf OUT '%s==%s '."\n", $p{'id'}, $p{'title'} ;
				
				#my $f2 = 'regions_'. $p{'id'} .'.txt';
				( my $x = $p{'title'} ) =~ s/\s/_/;
				my $f2 = 'regions_'. $x .'.txt';			
				open OUT2, "> $f2"  or die "Failed to open $f2 for writing";
				printf OUT2 '# REGIONS for '.$p{'title'}."\n";
		
				foreach (@{$p{'regions'}}) {
						my %r = %$_;
						
						#printf '%s  %s '."\n", $r{'id'}, $r{'title'} ;
						printf OUT2 '%s==%s '."\n", $r{'id'}, $r{'title'} ;
				}
				
				close OUT2;
				
		}
		
		close OUT;
}


sub fetch_channels {
		# Fetch Atlas' channels for each region
		
		foreach (@$platforms) {
				my %p = %$_;
				
				foreach (@{$p{'regions'}}) {
						my %r = %$_;
						
						my $regioncode = $r{'id'};
						
						#		http://atlas.metabroadcast.com/3.0/channel_groups/cbhN.json?annotations=channels 
						#
						my $url = $ROOT_URL.'channel_groups/'.$regioncode.'.json?annotations=channels';
						#print $url ."\n" ;

						my %regionchannels = ();

						# Fetch the page
						my $res = $lwp->get( $url );
						
						if ($res->is_success) {
								#print $res->content;
								
								# Extract the available channels
								my $data = JSON::PP->new()->utf8(0)->decode($res->content);
								$res = undef;

								my $chans = $data->{'channel_groups'}[0]->{'channels'};
								foreach (@$chans) {
										my %chan = %$_;
										next unless ($chan{'channel'}->{'type'} eq 'channel');
								
										my %channel = ();
								
										$channel{'num'} 				= $chan{'channel_number'};
										$channel{'id'} 					= $chan{'channel'}->{'id'};
										$channel{'title'} 			= $chan{'channel'}->{'title'};
										$channel{'image'} 			= $chan{'channel'}->{'image'};
										$channel{'media_type'} 	= $chan{'channel'}->{'media_type'};		# 'video' 'audio'
										
										foreach (@{$chan{'channel'}->{'aliases'}}) {
												my $alias = $_;							
												#     'aliases' => [
												#                   'http://pressassociation.com/channels/1459',
												#                   'http://xmltv.radiotimes.com/channels/2569',
												#                   'supercasino',
												#                   'http://atlas.metabroadcast.com/4.0/channels/hmcb'
												#                 ],
												if ( $alias =~ m%http://xmltv.radiotimes.com/channels/(\d*)% ) {
													$channel{'rt_chan'} = $1;
													next;
												}
												if ( $alias =~ m%http://pressassociation.com/channels/(\d*)% ) {
													$channel{'pa_chan'} = $1;
													next;
												}
										}
												 
										push @{$regionchannels{$regioncode}}, \%channel;
								}
								
						} else {
								print $res->status_line . "\n";
						}
						
						push @{$channels}, \%regionchannels;					
				}
		}
	
		return;
}


sub print_channels {
		# Write a map file of all the Atlas channels for each region with  map==id==num   ("map_xxxx.txt")
		#
		foreach (@{$channels}) {
				my %r = %$_;
							
				foreach my $key (keys %r) {
						my $regioncode = $key;
						
						my $f = 'map_'. $regioncode .'.txt';			
						open OUT, "> $f"  or die "Failed to open $f for writing";
						printf OUT '# CHANNELS for '.$regioncode."\n";

						foreach (@{$r{$key}}) {
							my %c = %$_;
							# print Dumper(\%c);exit;
							
							printf OUT 'map==%s==%s '."\n", $c{'id'}, $c{'num'};
						}
							
						close OUT;
			}
				
		}
}


sub print_channels_RT {
		# Write a map file of all the Atlas channels for each region with  map==id==RT_id   ("map_xxxx_RT.txt")
		#
		# 'RT_id' is the channel_id (RFC2838 compliant) as defined in the channel_ids file from the tv_grab_uk_rt grabber
		#
		
		# Load the RT channel_ids
		my %rt_ids = ();
		#		
		my $fn = 'rt/channel_ids';
		my $fhok = open my $fh, '<', $fn or die("Cannot open file $fn");
		if ($fhok) {
			while (my $line = <$fh>) { 
				chomp $line;
				chop($line) if ($line =~ m/\r$/);
				next if $line =~ /^#/;
				my ($channel_id, $rt_id, $name, $icon, $offset, $txhours, $res) = split(/\|/, $line);
				#print "$channel_id, $rt_id, $name, $icon, $offset, $txhours, $res";
				
				$rt_ids{$rt_id} = $channel_id;
			}
			close $fh;
		}
		#print Dumper (\%rt_ids);
		
		
		foreach (@{$channels}) {
				my %r = %$_;
							
				foreach my $key (keys %r) {
						my $regioncode = $key;
						
						my $f = 'map_'. $regioncode .'_RT.txt';			
						open OUT, "> $f"  or die "Failed to open $f for writing";
						printf OUT '# CHANNELS for '.$regioncode."\n";
						printf OUT '# This is an attempt to auto-match the Atlas data against the '."\n";
						printf OUT '# RT grabber\'s channel_ids file'."\n";
						printf OUT '# '."\n";

						foreach (@{$r{$key}}) {
							my %c = %$_;
							#print Dumper(\%c);exit;
							
							my $rt_id = '';
							$rt_id = $rt_ids{$c{'rt_chan'}} if defined $c{'rt_chan'};
							if (!defined $rt_id) {
								print $c{'num'} . ' has no RT channel'."\n";
								$rt_id = '';
							}
							printf OUT "map==%s==%s   \t\t\t\t# %s (%s) - %s"."\n", $c{'id'}, $rt_id, $c{'num'}, (defined $c{'rt_chan'}?$c{'rt_chan'}:''), $c{'title'};
						}
							
						close OUT;
			}
				
		}
}


# #############################################################################
# # THE VEG ######################################################################
# ------------------------------------------------------------------------------------------------------------------------------------- #

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


# #############################################################################

__END__
