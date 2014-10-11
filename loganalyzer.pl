#!/usr/bin/perl

use warnings;
use strict;

use Excel::Writer::XLSX;

##------CONFIGURATION---------------------------------------------------

my $date = _yyyymm();
## our output file name
my $output = "EZproxy_use_$date.xlsx";
## the stat codes we're interested in ...
my $wanted = 'CLS ACD PRS VIC VIR VIA VIO HDG PDP HON UND NAA BCA BCS SCA SCS Y12 PIR SAR ALE admin anon';
# these stat codes are always associated with one of the above
my $ignored = 'CAS DLP MR NOS RAI WAI';

my @wanted = split ' ', $wanted;

##------INIT------------------------------------------------------------

my $codes = Codes->init;

my %statcodes = ();
my %deptcodes = ();
my %progcodes = ();
my $domains = {};
my $users = {};
my %nostat = ();

my $start = time;
my $lines = 0;
my $first = '';
my $last  = '';
my $prevday  = '';
my $thisday  = '';

##------PROCESS LOGS----------------------------------------------------

while (<>) {

	$lines++;

        my ($ip, $login, $time1, $time2, $method, $url, $status, $bytes)
	    = ( /(\S+) - (\S+) \[(\S+) (.+?)\] "(\S+) (.*?)" (\d+) (\d+)/ );

	$first = $time1 unless $first;
	$last = $time1;
	$thisday = substr $last, 0, 11;
	unless ( $thisday eq $prevday ) { print STDERR "$thisday\n"; $prevday = $thisday; } # progress report

	$url =~ s/ .*//; # remove HTTP version

	## ... ignoring irrelevant hits
	next if $login eq '-';				# not logged in
	next unless $bytes;				# zero bytes
        next if $url =~ /\.(js|css|gif|jpg|png)$/;	# component files
	## ... and EZproxy login attempts
        next if $url =~ m{proxy.library.adelaide.edu.au:\d*/(login|connect)};

	my $domain = $codes->getDomain($url);
	
	$login = lc $login if $login =~ /^A(\d{7})$/;
	$login = uc $login if $login =~ /^\d{10}\w$/;
	$login = "a$login" if $login =~ /^\d{7}$/;
	$login =~ s/^bc(\d{10}\w)$/$1/;
	my $userid = $codes->getUserid( $login );

	## replace user ids with the mapped stats code
	my ($stat, $dept, $prog);
	$stat = $dept = $prog = '';
	if ($login eq '-' or $login eq 'auto') { $stat = 'anon'; }
	else {
	    $stat = $codes->getCode( $login, 'userStats' );
	    $dept = $codes->getCode( $login, 'userDepts' );
	    $prog = $codes->getProgCode( $login, 'userProgs' );
	}
	## everyone should have a stat code, so record any that don't
	unless ( $stat ) 
	{
	    $nostat{$login}++;
	    $stat = $login;
	}
	unless ( $wanted =~ /\Q$stat\E/ ) { print STDERR "$login $stat $_"; }

	## ... while keeping count of pages per domain per stats code
	$domains->{$domain}->{$stat}->{'pages'}++;
	$domains->{$domain}->{$stat}->{'bytes'} += $bytes;
	$users->{$stat}->{$userid}++;
	$statcodes{$stat}++; ## collect list of stat codes used

	if ( $dept ) {
	    $domains->{$domain}->{$dept}->{'pages'}++;
	    $users->{$dept}->{$userid}++;
	    $deptcodes{$dept}++; ## collect list of department codes used
	}

	if ( $prog ) {
	    $domains->{$domain}->{$prog}->{'pages'}++;
	    $users->{$prog}->{$userid}++;
	    $progcodes{$prog}++; ## collect list of program codes used
	}
}

##------CREATE EXCEL----------------------------------------------------

my $wb = Excel::Writer::XLSX->new($output);
my $headfmt = $wb->add_format( bold => 1 );
my $numbfmt = $wb->add_format();
my $totlfmt = $wb->add_format();
$numbfmt->set_num_format( '#,##0' );
$totlfmt->set_num_format( '#,##0' );
$totlfmt->set_bold();

my @stats = @wanted;
foreach my $code ( sort keys %statcodes ) {
	push @stats, $code unless $wanted =~ /\Q$code\E/;
}

writeSheet( 'pages', 'stat', @stats );
writeSheet( 'bytes', 'stat', @stats );

my @depts = sort keys %deptcodes;
writeSheet( 'pages', 'dept', @depts );

my @progs = sort keys %progcodes;
writeSheet( 'pages', 'program', @progs );

$wb->close();

print "EZproxy use stats for period $first to $last\n";
print "Processed $lines lines in ", time - $start, " seconds\n";
print "No stat code found for these identifiers:\n";
$, = "\n";
print sort keys %nostat;
print "\n";

##----------------------------------------------------------------------

sub writeSheet {
	my ($type, $group, @keys) = @_;
	my $lastcol = acol(1 + @keys); ## the final column
	my $ws = $wb->add_worksheet("$type by $group");
	my $row = 0;
	my $col = 0;

	## Headings
	$ws->write($row, $col++, "RESOURCE", $headfmt);
	$ws->write($row, $col++, "TOTAL", $headfmt);
	foreach my $s (@keys)
	{
		$ws->write($row, $col, $s, $headfmt);
		my $label = $codes->getLabel( $group, $s );
		$ws->write_comment($row, $col, $label);
		$col++;
	}
	$row++;
	$col = 0;

	## Body
	foreach my $d (sort keys %{$domains})
	{
		$ws->write($row, $col++, $d); # resource name
		my $arow = $row + 1;
		$ws->write_formula($row, $col++, "=SUM(C${arow}:${lastcol}${arow})", $totlfmt );
		foreach my $s (@keys) {
			my $v = $domains->{$d}->{$s}->{$type};
			$ws->write($row, $col, $v, $numbfmt) if $v;
			$col++;
		}
		$row++;
		$col = 0;
	}

	## column totals
	$ws->write($row, $col++, "TOTAL", $headfmt);
	my $lastrow = $row; # A1 notation, rows start at 1
	while ( $col < (2 + @keys) ) {
		my $thiscol = acol($col);
		$ws->write_formula($row, $col++, "=SUM(${thiscol}2:${thiscol}${lastrow})", $totlfmt );
	}

	$row++;
	$ws->write($row, 0, "ACTIVE USERS", $headfmt);
	$col = 2;
	foreach my $s (@keys)
	{
		my $v = (keys %{$users->{$s}});
		$ws->write($row, $col, $v, $numbfmt) if $v;
		$col++;
	}

	$row++;
	$ws->write($row, 0, "AVE/USER", $headfmt);
	$col = 2;
	{
	    my $t = $row - 1;
	    my $c = $row;
	    while ( $col < (2 + @keys) ) {
		my $thiscol = acol($col);
		$ws->write_formula($row, $col++, "=(${thiscol}${t}/${thiscol}${c})", $totlfmt );
	    }
	}

	$ws->freeze_panes(1, 0);
}

sub acol { # returns the A1 notation column for a numeric column
	my $col = shift;
	my $x = "A";
	if ($col > 25)
	{ $x = chr(64+int($col/26)) . chr(65+$col%26); }
	else
	{ $x = chr(65+$col%26); }
	return $x;
}

##----------------------------------------------------------------------

sub _yyyymm {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	return sprintf "%04d%02d", $year+1900, $mon+1;
}

##------INITIALISE CODE TABLES------------------------------------------

package Codes;

sub init {
	my $class = shift;
	my $self = {};
	$self->{userLogins} = userLoginMap("/home/uals/stats/user-login.map");
	$self->{userStats} = userStatMap($self, "/home/uals/stats/user-stat.map");
	$self->{userDepts} = userDeptMap("/home/uals/stats/user-dept.map");
	$self->{userProgs} = userProgMap("/home/uals/stats/user-program.map");
	$self->{labels}->{'stat'} = loadLabels("/home/uals/stats/Categories.dat");
	$self->{labels}->{'dept'} = loadLabels("/home/uals/stats/Departments.dat");
	$self->{labels}->{'program'} = loadLabels("/home/uals/stats/Programs.dat");
	$self->{labels}->{'domain'} = loadLabels("/home/uals/data/ezproxy/configured-hosts.txt");
	bless $self, $class;
	return $self;
}

sub getDomain {
	my $self = shift;
	my $url = shift;
	my ($domain) = ($url =~ m{https*://(.*?)[:/]});
	my $try = $domain;
	# look for this domain or sub-domain in our list of hosts
	while ( $try =~ /[^.]+\.[^.]+$/ ) {
	    if ( $self->{labels}->{'domain'}->{$try} )
	    {
		$domain = $self->{labels}->{'domain'}->{$try};
		last;
	    }
	    else
	    {
		$try =~ s/^.*?\.//;
	    }
	}

	# return either the domain description, or the domain if not found
	return $domain;
}

sub getUserid {
	my $self = shift;
	my $login = shift;
	my $userid = $self->{userLogins}->{$login};
	$userid = '' unless $userid;
	return $userid;
}

sub getCode {
	my $self = shift;
	my $login = shift;
	my $type = shift;
	my $code = '';
	if ( $self->{userLogins}->{$login} )
	{
            $code = $self->{$type}->{ $self->{userLogins}->{$login} };
        }
	unless ( $code )
	{
	    $code = '';
	}
	return $code;
}

sub indexof {
	my $value = shift;
	my @list = @_;
	my $i = 0;
	foreach ( @list ) { last if /$value/; $i++; }
	return $i;
}

sub userStatMap {
	my $self = shift;
	my $file = shift;
	my $stats = {};

	open my $fh, "<:utf8", $file or die "Cannot open $file, $!";

	while (<$fh>)
	{
		chomp;
		my ($user, $stat) = split /\t/;
		next if $ignored =~ /$stat/;
		if ( $stats->{$user} ) { # check precedence if multiple stats
		    my $j = indexof( $stats->{$user}, @wanted);
		    my $k = indexof( $stat, @wanted);
		    $stats->{$user} = $stat if $k < $j;
		} else {
		    $stats->{$user} = $stat;
		}
		## make sure the UniID is included in the logins map
		$self->{userLogins}->{"a$user"} = $user;
	}

	close $fh;

	return $stats;
}

sub userLoginMap {
	my $file = shift;
	my $logins = {};

	open my $fh, "<:utf8", $file or die "Cannot open $file, $!";

	while (<$fh>)
	{
		chomp;
		my ($user, $ident, undef) = split /\t/;
		$logins->{$ident} = $user;
		$logins->{"a$user"} = $user;
	}

	close $fh;

	return $logins;
}

sub userDeptMap {
	my $file = shift;
	my $depts = {};

	open my $fh, "<:utf8", $file or die "Cannot open $file, $!";

	while (<$fh>)
	{
		chomp;
		my ($user, $dept, undef) = split /\t/;
		$depts->{$user} = $dept;
	}

	close $fh;

	return $depts;
}

sub userProgMap {
	my $file = shift;
	my $programs = {};

	open my $fh, "<:utf8", $file or die "Cannot open $file, $!";

	while (<$fh>)
	{
		chomp;
		my ($user, $program, undef) = split /\t/;
		$programs->{$user} = $program;
	}

	close $fh;

	return $programs;
}

sub getLabel {
	my $self = shift;
	my $group = shift;
	my $code = shift;
	my $label = $self->{labels}->{$group}->{$code};
	$label = '' unless $label;
	return $label;
}

sub loadLabels {
	my $file = shift;
	my $labels = {};

	open my $fh, "<:utf8", $file or die "Cannot open $file, $!";

	while (<$fh>)
	{
		chomp;
		my ($code, $label, undef) = split /\t/;
		if ( $labels->{$code} ) # exists
		{
		    unless ( $labels->{$code} eq $label ) # different label
		    {
			print STDERR "DUPLICATE CODE: $_\n";
		    }
		}
		$labels->{$code} = $label;
	}

	close $fh;

	return $labels;
}

__END__

=head1 NAME

loganalyzer : analyse EZproxy log file

=head1 SYNOPSIS

    cat somelogfiles | loganalyzer.pl 

=head1 DESCRIPTION

Takes as input log file(s) from EZproxy, and produces an Excel file, with separate worksheets giving a summary of  
user page requests by statistical category, department (staff), and course (students) respectively.

The login is the user name used to log in to EZproxy. A user may have more than one identifier for login.

The user id is the internal Alma id of the user.

As each log file line is processed, the user login is mapped
to the associated statistical category/dept/program code for that user,
and then a count taken of page requests for the given domain and code.
The byte count for requests is also accumulated for each stat code.

At the end of processing, an Excel file is output consisting of

    domain page requests by statistical category
    domain bytes by statistical category
    domain page requests by staff department code
    domain page requests by student program (course) code

Processing ignores input lines for image, javascript, and css files, and also lines with zero bytes, so the page count
is a more accurate reflection of actual "pages" read. Although this is not absolutely accurate.

=head1 FILES

=over

=item * user-login.map
maps the user login to their (Alma) primary identifier

=item * user-stat.map
maps each user to a statistical category code

=item * user-dept.map
maps each user to their department code (staff)

=item * user-program.map
maps each user to their program or course code (students)

=item * Categories.dat
provides a descriptive label for each stat code

=item * Departments.dat
provides a descriptive label for each department code

=item * Programs.dat
provides a descriptive label for each program code

=item * configured-hosts.txt
lists all the EZproxy configured hosts, with the Title for each. This makes
the list of resources more meaningful.

=back

=head1 VERSION

Version 2014.10.11

=head1 AUTHOR

Steve Thomas <stephen.thomas@adelaide.edu.au>

=head1 LICENCE

Copyright 2014  Steve Thomas

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

