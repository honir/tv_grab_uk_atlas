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
    NoUpdate => 60*60*48,			# cache time in seconds
		MaxAge => 72,							# flush time in hours
    Verbose => $debug,
} );


# ------------------------------------------------------------------------------------------------------------------------------------- #
# Get the channels from Atlas
my $ROOT_URL = 'http://atlas.metabroadcast.com/3.0/';
my $platforms = ();
my $regions = ();
my $platformchannels = ();
my $regionchannels = ();
my $allchannels = ();
my $alluniquechannels = ();
my $channelids = ();
my $rtchannelids = ();
my $pachannelids = ();

get_channels();


# ------------------------------------------------------------------------------------------------------------------------------------- #
exit(0);


# #############################################################################
# # THE MEAT #####################################################################
# ------------------------------------------------------------------------------------------------------------------------------------- #

sub get_channels {

		fetch_platforms();
		#		print Dumper($platforms);
		#		print Dumper($regions);
		print_platforms();
		print_regions();
		fetch_channels();
		#		print Dumper($regionchannels);
		#		print Dumper($allchannels);
		#		print Dumper($alluniquechannels);
		#		print Dumper($rtchannelids);
		#		print Dumper($pachannelids);
		print_channels();
		print_channels_all();
		print_channels_RT();
		print_channels_RT_ATLAS();
		
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
							$platform{'countries'} .= ($platform{'countries'} ne '' ? ' ' : '') . $country;
						}
						
						$platform{'regions'} = ();
						foreach my $region (@{$group{'regions'}}) {
							push @{$platform{'regions'}},  { 'id' => $region->{'id'}, 'title' =>  $region->{'title'} };

							$regions->{$region->{'id'}} = { 'title' => $region->{'title'}, 'platformid' => $platform{'id'}, 'platform' => $platform{'title'} };
							#~ last;
						}
						
						push @{$platforms}, \%platform;
						#~ last;
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
		printf OUT '# platform id == platform title'."\n";
		printf OUT '# '."\n";
		
		foreach (@{$platforms}) {
				my %p = %$_;
				
				#printf '%s  %s '."\n", $p{'id'}, $p{'title'} ;
				printf OUT '%s==%s '."\n", $p{'id'}, $p{'title'} ;
				
				#my $f2 = 'regions_'. $p{'id'} .'.txt';
				( my $x = $p{'title'} ) =~ s/\s/_/;
				my $f2 = 'regions_'. $x .'.txt';			
				open OUT2, "> $f2"  or die "Failed to open $f2 for writing";
				printf OUT2 '# REGIONS for '.$p{'title'}."\n";
				printf OUT2 '# region id == region title'."\n";
				printf OUT2 '# '."\n";
		
				foreach (@{$p{'regions'}}) {
						my %r = %$_;
						
						#printf '%s  %s '."\n", $r{'id'}, $r{'title'} ;
						printf OUT2 '%s==%s '."\n", $r{'id'}, $r{'title'} ;
				}
				
				close OUT2;
				
		}
		
		close OUT;
}


sub print_regions {
		# Write a file of all the Atlas regions with  id==title==platformid==platformname  ("regions.txt")
		#
		my $f = 'regions.txt';
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# REGIONS for all platforms'."\n";
		printf OUT '# region id == region name == platform id == platform name'."\n";
		printf OUT '# '."\n";
		
		foreach my $key (sort keys %{$regions}) {
				my $regionid = $key;
				
				#printf '%s  %s '."\n", $p{'id'}, $p{'title'} ;
				printf OUT '%s==%s==%s==%s '."\n", $regionid, $regions->{$regionid}{'title'}, $regions->{$regionid}{'platformid'}, $regions->{$regionid}{'platform'} ;
		}
		
		close OUT;
}


sub fetch_channels {
		# Fetch Atlas' channels for each platform and each region
		foreach (@$platforms) {
				my %p = %$_;
				
				fetch_channels_for_code( 'platform', $p{'id'} );
				
				foreach (@{$p{'regions'}}) {
						my %r = %$_;
						
						fetch_channels_for_code( 'region', $r{'id'} );
				}
		}
	
		return;
}
	
	
sub fetch_channels_for_code {
		# Fetch Atlas' channels for a platform code or region code
		
		my ($type, $code) = @_;
		
		#		http://atlas.metabroadcast.com/3.0/channel_groups/cbhN.json?annotations=channels 
		#
		my $url = $ROOT_URL.'channel_groups/'.$code.'.json?annotations=channels';
		#print $url ."\n" ;

		# Fetch the page
		my $res = $lwp->get( $url );
		
		if ($res->is_success) {
				#print $res->content;
				
				my %channeldata = ();
				
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
						$channel{'region'} 			= $code;
						
						foreach (@{$chan{'channel'}->{'aliases'}}) {
								my $alias = $_;							
								#     'aliases' => [
								#                   'http://pressassociation.com/channels/1459',
								#                   'http://xmltv.radiotimes.com/channels/2569',
								#                   'supercasino',
								#                   'http://atlas.metabroadcast.com/4.0/channels/hmcb'
								#                 ],
								#
								# WHAT IF THERE'S MORE THAN 1 ?
								#
								if ( $alias =~ m%http://xmltv.radiotimes.com/channels/(\d*)% ) {
									$channel{'rt_chan'} = $1;
									$rtchannelids->{$1} = { 'atlasid' => $channel{'id'}, 'atlastitle' => $channel{'title'}, 'num' => $channel{'num'} };
									next;
								}
								if ( $alias =~ m%http://pressassociation.com/channels/(\d*)% ) {
									$channel{'pa_chan'} = $1;
									$pachannelids->{$1} = { 'atlasid' => $channel{'id'}, 'atlastitle' => $channel{'title'}, 'num' => $channel{'num'} };
									next;
								}
						}
						
						push @{$allchannels}, { %channel };
						$alluniquechannels->{$channel{'id'}} = \%channel;
								 
						push @{$channeldata{$code}}, \%channel;
				}
				
				push @{$platformchannels}, \%channeldata if $type eq 'platform' && %channeldata;
				push @{$regionchannels}, \%channeldata if $type eq 'region' && %channeldata;
				
		} else {
				print $res->status_line . "\n";
		}

}


sub print_channels {
		# Write a map file of all the Atlas channels for each platform/region with  map==id==num   ("map_xxxx.txt")
		#

		foreach (@{$platformchannels}) {
				my %r = %$_;
							
				foreach my $key (keys %r) {
						my $platformid = $key;
						my $platformtitle = '';
						foreach (@{$platforms}) {
							next unless $_->{'id'} eq $platformid;
							$platformtitle = $_->{'title'};
						}
							
						my $f = 'map_'. $platformid .'.txt';			
						open OUT, "> $f"  or die "Failed to open $f for writing";
						printf OUT '# CHANNELS for platform '.$platformid.' - '.$platformtitle."\n";
						printf OUT '# \'map\' == channel id == channel number'."\n";
						printf OUT '# '."\n";

						foreach (@{$r{$key}}) {
							my %c = %$_;
							# print Dumper(\%c);exit;
							
							printf OUT 'map==%s==%s '."\n", $c{'id'}, $c{'num'};
						}
							
						close OUT;
				}
				
		}
		
		foreach (@{$regionchannels}) {
				my %r = %$_;
							
				foreach my $key (keys %r) {
						my $regionid = $key;
						
						my $f = 'map_'. $regionid .'.txt';			
						open OUT, "> $f"  or die "Failed to open $f for writing";
						printf OUT '# CHANNELS for region '.$regionid.' - '.$regions->{$regionid}{'title'}."\n";
						printf OUT '# \'map\' == channel id == channel number'."\n";
						printf OUT '# '."\n";

						foreach (@{$r{$key}}) {
							my %c = %$_;
							# print Dumper(\%c);exit;
							
							printf OUT 'map==%s==%s '."\n", $c{'id'}, $c{'num'};
						}
							
						close OUT;
				}
				
		}
}


sub print_channels_all {
		# Write a map file of all the Atlas channels for all regions with  map==id==num   ("map_all.txt")
		#	
		my $f = 'map_all.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# ALL CHANNELS for ALL REGIONS'."\n";
		printf OUT '# \'map\' == channel id == channel number  # (region id) -- channel title '."\n";
		printf OUT '# '."\n";
				
		foreach (@{$allchannels}) {
				my %c = %$_;
				
				printf OUT "map==%s==%s \t\t# (%s) -- %s "."\n", $c{'id'}, $c{'num'}, $c{'region'}, $c{'title'};
		}
				
		close OUT;
		
		# sort by id
		$f = 'map_all.sort_id.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# ALL CHANNELS for ALL REGIONS'."\n";
		printf OUT '# \'map\' == channel id == channel number  # (region id) -- channel title '."\n";
		printf OUT '# '."\n";
		printf OUT '# Sorted by Atlas id'."\n";
		printf OUT '# '."\n";
		foreach (sort {$$a{'id'} cmp $$b{'id'}} @{$allchannels}) {
				my %c = %$_;
				printf OUT "map==%s==%s \t\t# (%s) -- %s "."\n", $c{'id'}, $c{'num'}, $c{'region'}, $c{'title'};
		}
		close OUT;
		
		# sort by num
		$f = 'map_all.sort_num.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# ALL CHANNELS for ALL REGIONS'."\n";
		printf OUT '# \'map\' == channel id == channel number  # (region id) -- channel title '."\n";
		printf OUT '# '."\n";
		printf OUT '# Sorted by channel number'."\n";
		printf OUT '# '."\n";
		foreach (sort {$$a{'num'} cmp $$b{'num'} or $$a{'id'} cmp $$b{'id'}} @{$allchannels}) {
				my %c = %$_;
				printf OUT "map==%s==%s \t\t# (%s) -- %s "."\n", $c{'id'}, $c{'num'}, $c{'region'}, $c{'title'};
		}
		close OUT;
		
		# sort by title
		$f = 'map_all.sort_title.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# ALL CHANNELS for ALL REGIONS'."\n";
		printf OUT '# \'map\' == channel id == channel number  # (region id) -- channel title '."\n";
		printf OUT '# '."\n";
		printf OUT '# Sorted by Atlas channel title'."\n";
		printf OUT '# '."\n";
		foreach (sort {$$a{'title'} cmp $$b{'title'} or $$a{'id'} cmp $$b{'id'}} @{$allchannels}) {
				my %c = %$_;
				printf OUT "map==%s==%s \t\t# (%s) -- %s "."\n", $c{'id'}, $c{'num'}, $c{'region'}, $c{'title'};
		}
		close OUT;
		
		
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
		
		
		foreach (@{$regionchannels}) {
				my %r = %$_;
							
				foreach my $key (keys %r) {
						my $regioncode = $key;
						
						my $f = 'rt/map_'. $regioncode .'_RT.txt';			
						open OUT, "> $f"  or die "Failed to open $f for writing";
						printf OUT '# CHANNELS for '.$regioncode."\n";
						printf OUT '# This is an attempt to auto-match the Atlas data against the '."\n";
						printf OUT '# RT grabber\'s channel_ids file'."\n";
						printf OUT '# \'map\' == channel id == rt_id   # channel-num (rt_channel_as_defined_by_atlas) channel_name'."\n";
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

		
sub print_channels_RT_ATLAS {
		# Write a map file of the Atlas channel for each RT channel_id with map==RT_id==atlas_id  ("map__RT.txt")
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
		# print Dumper (\%rt_ids);
		
		my $f = 'rt/map__RT.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# CHANNELS for RT grabber ids'."\n";
		printf OUT '# Match the channel_ids in the RT grabber\'s channel_ids file against Atlas data'."\n";
		printf OUT '# rt_channel id == rt_channel name == channel_id'."\n";
		printf OUT '# '."\n";
						
		foreach my $key (keys %rt_ids) {
				my $rt_id = $key;
				
				printf OUT '%s==%s==%s'."\n", $rt_id, $rt_ids{$rt_id}, (defined $rtchannelids->{$rt_id}{'atlasid'} ? $rtchannelids->{$rt_id}{'atlasid'} : '????');
		}
		
		close OUT;
		
		# sort numerically
		$f = 'rt/map__RT.sort_id.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# CHANNELS for RT grabber ids'."\n";
		printf OUT '# Match the channel_ids in the RT grabber\'s channel_ids file against Atlas data'."\n";
		printf OUT '# rt_channel id == rt_channel name == channel_id'."\n";
		printf OUT '# Sorted by rt_channel id'."\n";
		printf OUT '# '."\n";
		foreach my $key ( sort {$a<=>$b} keys %rt_ids ) {
				my $rt_id = $key;
				printf OUT '%s==%s==%s'."\n", $rt_id, $rt_ids{$rt_id}, (defined $rtchannelids->{$rt_id}{'atlasid'} ? $rtchannelids->{$rt_id}{'atlasid'} : '????');
		}
		close OUT;
		
		# sort by value
		$f = 'rt/map__RT.sort_name.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# CHANNELS for RT grabber ids'."\n";
		printf OUT '# Match the channel_ids in the RT grabber\'s channel_ids file against Atlas data'."\n";
		printf OUT '# rt_channel name == rt_channel id == channel_id'."\n";
		printf OUT '# Sorted by rt_channel name'."\n";
		printf OUT '# '."\n";
		foreach my $key ( sort {$rt_ids{$a} cmp $rt_ids{$b} } keys %rt_ids ) {
				my $rt_id = $key;
				printf OUT '%s==%s==%s'."\n", $rt_ids{$rt_id}, $rt_id, (defined $rtchannelids->{$rt_id}{'atlasid'} ? $rtchannelids->{$rt_id}{'atlasid'} : '????');
		}
		close OUT;
		
		
		
		
		# Write a map file of all the Atlas channels for all platforms/regions with  map==id==RT_id ;# RT_channel   ("map_ALL.txt")
		#  where 'RT_id' is the channel_id (RFC2838 compliant) as defined in the channel_ids file from the tv_grab_uk_rt grabber
		#  and RT_channel' is the RadioTimes channel number (i.e.  "xxx.dat" file)
		$f = 'rt/map_ALL.txt';			
		open OUT, "> $f"  or die "Failed to open $f for writing";
		printf OUT '# CHANNELS for all Atlas channels mapped to an RFC2838 compliant channel id'."\n";
		printf OUT '# Cross-references the RadioTimes channel id (where one exists)'."\n";
		printf OUT '# \'map\' == atlas_channel_id == rt_channel name # rt_channel id -- channel title '."\n";
		printf OUT '# '."\n";	
				
		foreach ( sort {$a cmp $b} keys %$alluniquechannels ) {
				my %c = %{ $alluniquechannels->{$_} };
				if (defined $c{'rt_chan'}) {
					printf OUT "map==%s==%s %s# (%s) -- %s "."\n", $c{'id'}, $rt_ids{$c{'rt_chan'}}, " " x (50-length( $c{'id'} . $rt_ids{$c{'rt_chan'}} )), $c{'rt_chan'}, $c{'title'};
				} else {
					printf OUT "map==%s==%s %s# (%s) -- %s "."\n", $c{'id'}, $c{'num'}.'.atlas', " " x (50-length( $c{'id'} . $c{'num'}.'.atlas' )), '????', $c{'title'};
				}
		}
				
		close OUT;
		
		
		
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



# EXAMPLE DATA STRUCTURES ----------------------------------------------------------------------------------- #
# ----------------------------------------------------------------------------------------------------------- #
print Dumper($platforms);
$VAR1 = [
          {
            'regions' => [
                           {
                             'title' => 'Republic of Ireland',
                             'id' => 'cbfM'
                           },
                           {
                             'title' => 'Northern Ireland',
                             'id' => 'cbfN'
                           },
                         ],
            'title' => 'Sky HD',
            'id' => 'cbfK',
            'countries' => 'GB IE',
            'uri' => 'http://ref.atlasapi.org/platforms/pressassociation.com/1'
          },
													 
													 

# ----------------------------------------------------------------------------------------------------------- #
print Dumper($regions);
$VAR1 = {
          'cbj2' => {
                      'platformid' => 'cbjR',
                      'platform' => 'YouView',
                      'title' => 'West Midlands'
                    },
          'cbgy' => {
                      'platformid' => 'cbgp',
                      'platform' => 'Sky SD',
                      'title' => 'Meridian (East)'
                    },
        };
				

# ----------------------------------------------------------------------------------------------------------- #
print Dumper($regionchannels);
$VAR1 = [
          {
            'cbfM' => [
                        {
                          'rt_chan' => '231',
                          'num' => '101',
                          'media_type' => 'video',
                          'title' => "RT\x{c3}\x{89} One",
                          'id' => 'cbfk',
                          'pa_chan' => '81',
                          'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p139876.png'
                        },
                        {
                          'rt_chan' => '1870',
                          'num' => '102',
                          'media_type' => 'video',
                          'title' => "RT\x{c3}\x{89} Two",
                          'id' => 'cbfm',
                          'pa_chan' => '82',
                          'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p139878.png'
                        },
                      ]
          },
          {
            'cbfN' => [
                        {
                          'rt_chan' => '112',
                          'num' => '102',
                          'media_type' => 'video',
                          'title' => 'BBC Two Northern Ireland',
                          'id' => 'cbbH',
                          'pa_chan' => '19',
                          'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p131750.png'
                        },
                      ]
          }
        ];
				
				
# ----------------------------------------------------------------------------------------------------------- #
print Dumper($allchannels);			
$VAR1 = [
          {
            'rt_chan' => '231',
						'num' => '101',
            'media_type' => 'video',
            'region' => 'cbfM',
            'id' => 'cbfk',
            'title' => "RT\x{c3}\x{89} One",
            'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p139876.png'
          },
          {
            'rt_chan' => '1870',
						'num' => '102',
            'media_type' => 'video',
            'region' => 'cbfM',
            'id' => 'cbfm',
            'title' => "RT\x{c3}\x{89} Two",
            'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p139878.png'
          }
        ];
				
				
# ----------------------------------------------------------------------------------------------------------- #	
print Dumper($alluniquechannels);	
$VAR1 = {
          'cbj4' => {
                    'rt_chan' => '2145',
                    'num' => '520',
                    'region' => 'cbfM',
                    'pa_chan' => '1233',
                    'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p131501.png',
                    'media_type' => 'video',
                    'id' => 'cbj4',
                    'title' => 'Discovery Channel HD'
                  },
          'cbkX' => {
                    'rt_chan' => '2528',
                    'num' => '652',
                    'region' => 'cbfM',
                    'pa_chan' => '1365',
                    'image' => 'http://images.atlas.metabroadcast.com/pressassociation.com/channels/p141482.png',
                    'media_type' => 'video',
                    'id' => 'cbkX',
                    'title' => 'Gems TV'
                  }
        };

# ----------------------------------------------------------------------------------------------------------- #				
print Dumper($rtchannelids);
$VAR1 = {
          '2678' => {
                    'num' => '131',
                    'atlastitle' => 'ITV Central+1',
                    'atlasid' => 'cbdQ'
                  },
          '32' => {
                  'num' => '103',
                  'atlastitle' => 'ITV Yorkshire',
                  'atlasid' => 'cbd7'
                },
        };
							

# ----------------------------------------------------------------------------------------------------------- #												
print Dumper($pachannelids);
$VAR1 = {
          '90' => {
                  'num' => '743',
                  'atlastitle' => 'Sky Box Office',
                  'atlasid' => 'cbfW'
                },
          '71' => {
                  'num' => '788',
                  'atlastitle' => 'Zee TV',
                  'atlasid' => 'cbfP'
                },		
        };
				
				
# ----------------------------------------------------------------------------------------------------------- #												
print Dumper (\%rt_ids);
$VAR1 = {				
	        '1855' => 'plus-1.sat.travelchannel.co.uk',
          '2506' => 'hd.2.boxoffice.sky.com',
          '1201' => 'extra.comedycentral.com',
				}
			
		
		