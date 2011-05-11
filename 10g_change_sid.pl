#!/usr/bin/env perl

=head1 NAME

10g_change_sid.pl

=head1 SYNOPSIS

10g_change_sid.pl --newhostname foo.bar.com --oldsid OLDSID --newsid NEWSID [--help] [--man]

=head1 DESCRIPTION

Changes system hostname, and updates Oracle SID.

=head1 REQUISITES

=over

=item * Valid for Oracle 10g B<ONLY>.

=item * The hostname must B<NOT> have been changed, otherwise changing the CRS configuration will fail.

=item * The script should be run by root.

=item * All Oracle instances must be stopped

=back

=head1 AUTHOR

Jonathan Barber - <jonathan.barber@gmail.com>

=cut

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use File::Temp;
use File::Path qw(mkpath);
use File::Copy qw(move);

my ($oldhostname, $newhostname, $oldsid, $newsid, $noroot, $force, $help, $man);
GetOptions( 
	"newhostname=s" => \$newhostname,
	"oldsid=s"      => \$oldsid,
	"newsid=s"      => \$newsid,
	"help"          => \$help,
	"man"           => \$man,
	"noroot"        => \$noroot,
	"force"         => \$force,
) or pod2usage(-verbose => 0);

$help        && pod2usage { -verbose => 0 };
$man         && pod2usage { -verbose => 2 };
$newhostname || pod2usage "Missing --newhostname option";
$oldsid      || pod2usage "Missing --oldsid option";
$newsid      || pod2usage "Missing --newsid option";
$noroot      || am_i_root();
$oldhostname = $ENV{HOSTNAME};

# Change with local when required
my $orahome = $ENV{ORACLE_HOME} = get_orahome($oldsid);

sub run {
	my ($cmd) = @_;
	warn "Running: $cmd\n";
	return qx($cmd 2>&1);
}

sub failed { $? ? 1 : 0 }

sub sudo {
	my ($user, $cmd) = @_;
	run qq(sudo -u $user $cmd);
}

sub am_i_root {
	$ENV{USER} eq 'root' or die "$0 should be run as root\n";
}

sub giveup {
	my ($mesg, @more) = @_;
	die "$mesg:\n", @more;
}

sub sqlplus {
	my ($user, $fn) = @_;
	sudo $user => "sqlplus -S -L '/ as sysdba' \@$fn"
}

sub make_script {
	my ($script) = @_;
	my ($fh) = File::Temp->new(SUFFIX => ".sql");
	print $fh $script;
	$fh->close;
 	return $fh;
}

sub get_uid_gid {
	my ($user) = @_;
	return (getpwnam($user))[2,3];
}

sub get_orahome {
	my ($sid) = @_;
	my $fn = "/etc/oratab";
	open my $fh, $fn or die "Can't open $fn: $!\n";
	my @db = grep { /^$sid:/ } <$fh>;
	@db == 1 or die "More than one DB found in $fn with SID $sid\n";
	my (undef, $orahome, undef) = split /:/, $db[0], 3;
	return $orahome;
}

# Check new hostname is different to current hostname
{
	my ($out) = run "hostname";
	if (
		lc $newhostname eq lc $ENV{HOSTNAME} ||
		lc $newhostname eq lc $out
	) {
		die "--newhostname is equal to current hostname\n";
	}
}

# Check Oracle is stopped
{
	# pgrep returns 1 if it finds 
	my @out = run "pgrep -f pmon";
	$? >> 8 == 1 or giveup "Oracle processes appear to be running, stop them before re-running this script", @out;
}

# Check runlevel
{
	my (@out) = run "runlevel";
	failed and giveup "Couldn't discover runlevel", @out;
	$out[0] !~ /^N [2-5]/ and giveup "Not in runlevel 2-5, this script probably won't work\n";
}

# Remove CRS config
{
	my @out = run "localconfig delete";
	failed and giveup "localconfig delete failed", @out;
}

# Change hostname
{
	my @out = run "sed -i 's/HOSTNAME=.*/HOSTNAME=$newhostname/' /etc/sysconfig/network";
	failed and giveup "Couldn't update hostname", @out;

	@out = run "hostname $newhostname";
	failed and giveup "Couldn't set hostname", @out;

	@out = run qq(sed -i "s/\<$oldhostname\>/$newhostname/g" /etc/hosts);
	failed and giveup "Couldn't change hostname in /etc/hosts", @out;
}

# Add CRS config for new hostname and fix inittab runlevel
{
	my @out = run "localconfig add";
	failed and giveup "localconfig add failed", @out;

	@out = run 'echo -e "/^h1:.*cssd/ m /^l2/\nwq" | ed /etc/inittab';
	failed and giveup "modification of inittab failed", @out;
}

# Start ASM
{
	my $fh = make_script "alter database startup; exit;\n";

	local $ENV{ORACLE_HOME} = get_orahome("+ASM");
	local $ENV{ORACLE_SID} = "+ASM";
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start ASM", @out;

	# FIXME: I don't think the DB needs to be running to create the pfile
	# and check log locations
#	local $ENV{ORACLE_SID} = $oldsid;
#	my @out = sqlplus "oracle" => $fh->filename;
#	failed and giveup "Couldn't start DB (ORACLE_SID=$oldsid)", @out;
}

# Create the pfile for the new SID
{
	my $fh = make_script <<EOF;
set serveroutput on
DECLARE
  spfile v\$parameter.value%type;
BEGIN
  select value into spfile from v\$parameter where name = 'spfile' and value is not null;
  if spfile is not null then
    execute immediate 'create pfile=''init$newsid.ora'' from spfile';
  else 
    dbms_output.put_line('No spfile');
  end if;
END;
/
exit;
EOF

	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't create pfile", @out;

	# Handle pfile
	if (grep { /No spfile/ } @out) {
		# Do this with sudo so the ownership is correct
		my @out = sudo "oracle" => "cp $orahome/dbs/init$oldsid.ora $orahome/dbs/init$newsid.ora";
		failed and giveup "Couldn't copy pfile", @out;
	}
}

# Update the pfile with the new paths
{
	my $pfile = "$orahome/dbs/init$newsid.ora";
	-e $pfile or die "No pfile found at $pfile for new SID\n";

	my @out = run <<EOF;
sed -i \
    -e "s/db_name=.$oldsid./db_name='$newsid'/" \
    -e "/\(audit_file\|\(background\|core\|user\)_dump\)_dest=/ { s/$oldsid/$newsid/ }"
    $pfile
EOF
	failed and giveup "Couldn't modify the pfile with the new db_name or logging destinations", @out;

	# Create the log directories
	open my $fh, "<$pfile" or die "Can't open $pfile: $!\n";
	while (my $line = <$fh>) {
		next unless $line =~ /((background|core|user|)_dump|audit_file)_dest=/;
		my (undef, $path) = split /=/, $line;
		$path =~ s/^["']//;
		$path =~ s/["']$//;

		my @created = mkpath($path, 1, 0755) or die "Couldn't create directory $path: $!\n";
		chown (get_uid_gid "oracle"), @created or die "Couldn't chown directory: $!\n";
	}
}

# Make sure all of the database dump destinations are created, if not then this
# can cause nid to fail
{
	my $fh = make_script <<'EOF';
set head off
set pagesize 0
set line 1000
column value format a1024
select value from v$parameter where name in ('background_dump_dest', 'user_dump_dest', 'core_dump_dest', 'audit_file_dest');
exit;
EOF

	local $ENV{ORACLE_HOME} = get_orahome($oldsid);
	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't find the log destinations", @out;
	chomp @out;
	my @dirs = grep { defined and not -d $_ or not -l $_ } @out;
	my @created = mkpath(@dirs, 1, 0755);
	chown (get_uid_gid "oracle"), @created;
}

# Change the DBID
{
	my $fh = make_script <<'EOF';
startup mount;
exit;
EOF

	local $ENV{ORACLE_HOME} = get_orahome($oldsid);
	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database", @out;

	# FIXME: This prompts and blocks... might be able to fix with HEREDOC or shell redirection.
	@out = sudo "oracle" => "sh -c 'echo Y | nid target=/ setname=yes dbname=$newsid'";
	failed and giveup "Couldn't change DBID with nid", @out;
}

# Start the DB with the new SID and create an spfile
{
	my $fh = make_script <<'EOF';
startup immediate;
create spfile from pfile;
EOF

	local $ENV{ORACLE_SID} = $newsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database and create spfile", @out;
}

# Move the old password file
{
	my $orig = "$orahome/dbs/orapw$oldsid";
	my $dest = "$orahome/dbs/orapw$newsid";
	if (-e $orig) {
		move $orig, $dest or die "Can't move $orig to $dest: $!\n";
	}
	else {
		my @out = sudo "oracle" => "orapwd file=$orahome/dbs/orapw$newsid password=manager entries=10";
		failed and giveup "Couldn't create a new Oracle password file", @out;
	}
}

# Update /etc/oratab
{
	my @out = run qq(sed -i "s/^$oldsid:/$newsid:/" /etc/oratab);
	failed and giveup "Couldn't alter /etc/oratab", @out;
}

# Complete
{
	warn <<EOF;
Hostname/DBID change completed. You need to:
  1. Check /etc/profile.d/* and user profile files for ORACLE_SID definitions
  2. Check the DB restarts correctly when the machine is rebooted
  3. Update TNS names entries
  4. Check if other entries in /etc/hosts need to be changed
  5. Remove old pfiles, spfiles and old log directories
EOF
}
