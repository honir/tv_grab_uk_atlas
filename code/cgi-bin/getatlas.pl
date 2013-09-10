#!/usr/bin/perl -w
#
# params are 'offset' and 'hours'
#				or  'offset' and 'days'    in which case the offset is 'days' also (otherwise it's 'hours')
#				or  'date'			- fetch just this day
#
# optional params:
#			channel		- Atlas channel id to fetch  (if not specified then grabber .conf file is used as normal)
#
#

# You may need to set $HOME if not same as command profile
#$ENV{'HOME'} = '?????';

use strict;
use warnings;
use Data::Dumper;
use CGI; 
use CGI::Carp qw(fatalsToBrowser);

my $query = CGI->new;

# Fetch the query string params
my $offset 	= $query->param('offset');
my $hours 	= $query->param('hours');
my $days 		= $query->param('days');
my $channel = $query->param('channel');
my $date 		= $query->param('date');				# YYYYMMDD


# Validate the params
if ( ($hours && $days) ||
		 ($date && ($offset || $hours || $days)) ) {
	
		if (0) {	
			print <<END_OF_HTML;
Status: 500 Invalid Parameters
Content-type: text/html

<HTML>
<HEAD><TITLE>500 Invalid Parameters</TITLE></HEAD>
<BODY>
  <H1>Error</H1>
  <P>Invalid Parameters</P>
</BODY>
</HTML>
END_OF_HTML
		}

		if (1) {	
			print <<END_OF_XML;
Status: 500 Invalid Parameters
Content-type: text/xml

<?xml version="1.0" encoding="UTF-8"?>
END_OF_XML
		}
		
		exit;
}


# Adjust the parameters
if ($hours) {
	$offset = 0 if !$offset;
	$hours += $offset;
}	
	
$channel = "--channel $channel" if $channel;

my $action = '';
if ($hours) {
	$action = "--hours $hours " . ($offset ? "--offset $offset" : '');
} elsif ($days) {
	$action = "--days $days " . ($offset ? "--offset $offset" : '');
} elsif ($date) {
	$action = "--date $date";
} else {
	$action = "--days 1";
}



# Must send HTTP Content-Type header
#print CGI->header('text/xml');
# ^^ caused errors:     Use of uninitialized value in string ne at (eval 3) line 29.
#
print "Content-type: text/xml"."\n\n";


# debug
#print "Params: <br /> $offset <br /> $hours <br /> $action <br />";exit(0);


# run the grabber (outputs to STDOUT (i.e. browser)
system("perl $ENV{'HOME'}/tv_grab_uk_atlas.pl --quiet $action $channel 2>/tmp/program.stderr ");


# if stderr not "" then e-mail it to me (TODO)


exit(0);

__END__
