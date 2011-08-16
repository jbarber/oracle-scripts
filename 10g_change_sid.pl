#!/usr/bin/env perl

=head1 NAME

10g_change_sid.pl

=head1 SYNOPSIS

10g_change_sid.pl --newhostname foo.bar.com --oldsid OLDSID --newsid NEWSID [--help] [--man] [--skip]

=head1 DESCRIPTION

Changes system hostname, and updates Oracle SID.

=head1 OPTIONS

=over

=item --newhostname foo.bar.com

The new host name of the host,

=item --oldsid OLDSID

The current SID of the database that you want to change.

=item --newsid NEWSID

The target SID of the OLDSID database.

=item [--help]

Report command line help.

=item [--man]

Show the manpage.

=item [--skip]

Go to a particular section of the program. Doing this may not work as some
sections depend on previous sections having completed (e.g. the database being
started). Sections are reported in the program output on standard error with
the prefix "###", e.g.
   ### CREATE_DEST

=back

=head1 REQUISITES

=over

=item * Valid for Oracle 10g B<ONLY>.

=item * The hostname must B<NOT> have been changed, otherwise changing the CRS configuration will fail.

=item * The script should be run by root.

=item * All Oracle instances must be stopped

=back

=head1 RHEL RECOMMEND USAGE

=over

=item 1. Boot the machine into single user mode

=item 2. Prevent future kudzu interuptions because of NIC MAC addresses "service kudzu start"

=item 3. Configure network interfaces under /etc/sysconfig/network-scripts/ifcfg-eth*

=item 4. Disable oracle from starting: "chkconfig dbora off"

=item 5. Change to your normal runlevel: "telinit 3"

=item 6. Run this script

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

my ($oldhostname, $newhostname, $oldsid, $newsid, $noroot, $force, $help, $man, $skip);
GetOptions( 
	"newhostname=s" => \$newhostname,
	"oldsid=s"      => \$oldsid,
	"newsid=s"      => \$newsid,
	"help"          => \$help,
	"man"           => \$man,
	"noroot"        => \$noroot,
	"force"         => \$force,
	"skip=s"        => \$skip,
) or pod2usage(-verbose => 0);

$help        && pod2usage { -verbose => 0 };
$man         && pod2usage { -verbose => 2 };
$newhostname || pod2usage "Missing --newhostname option";
$oldsid      || pod2usage "Missing --oldsid option";
$newsid      || pod2usage "Missing --newsid option";
$noroot      || am_i_root();
$oldhostname = $ENV{HOSTNAME};
$oldsid eq $newsid && die "--oldsid is the same as --newsid, nothing to do\n";

# Change with local when required
my $orahome = $ENV{ORACLE_HOME} = get_orahome($oldsid);
# UID/GID for chown'ing oracle
my @ids      = get_uid_gid("oracle");
my $oldpfile = "$orahome/dbs/init$oldsid.ora";
my $newpfile = "$orahome/dbs/init$newsid.ora";

# This really has to be run, otherwise sudo might be called with the wrong
# arguments
check_sudo();

defined $skip && goto $skip;

sub run {
	my ($cmd) = @_;
	warn "Running: $cmd\n";
	return qx($cmd 2>&1);
}

sub failed { $? ? 1 : 0 }

sub sudo {
	my ($user, $cmd) = @_;
	run qq(sudo -u $user $::SUDO_HAS_E $cmd);
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
	chmod 0644, $fh->filename;
 	return $fh;
}

sub get_uid_gid {
	my ($user) = @_;
	return (getpwnam($user))[2,3];
}

sub get_orahome {
	my ($sid) = @_;
	$sid || die "No sid passed to get_orahome()\n";
	my $fn = "/etc/oratab";
	open my $fh, $fn or die "Can't open $fn: $!\n";
	my @db = grep { /^\Q$sid\E:/ } <$fh>;
	@db == 0 and die "No DB with SID $sid found in $fn\n";
	@db == 1 or die "More than one DB found in $fn with SID $sid\n";
	my (undef, $orahome, undef) = split /:/, $db[0], 3;
	return $orahome;
}

sub warn_section {
	my ($mesg) = @_;
	warn "### $mesg\n";
}

sub check_sudo {
	my ($out) = run "sudo -E true";
	if (failed) {
		warn "sudo doesn't support -E argument, not using it\n";
		$::SUDO_HAS_E = "";
	}
	else {
		warn "sudo supports -E argument\n";
		$::SUDO_HAS_E = "-E";
	}
}

# Check new hostname is different to current hostname
warn_section "CHECK_HOSTNAME";
{
	my ($out) = run "hostname";
	chomp $out;
	if (lc $ENV{HOSTNAME} ne lc $out) {
		die "HOSTNAME environment variable ($ENV{HOSTNAME}) and output of hostname ($out) don't match. Fix it\n";
	}

	if (
		lc $newhostname eq lc $ENV{HOSTNAME} ||
		lc $newhostname eq lc $out
	) {
		die "--newhostname is equal to current hostname\n";
	}
}
CHECK_HOSTNAME:

# Check Oracle is stopped
warn_section "CHECK_ORACLE_STOPPED";
{
	# pgrep returns 1 if it finds 
	my @out = run "pgrep -f pmon";
	$? >> 8 == 1 or giveup "Oracle processes appear to be running, stop them before re-running this script", @out;
}
CHECK_ORACLE_STOPPED:

# Check runlevel
warn_section "CHECK_RUNLEVEL";
{
	my (@out) = run "runlevel";
	failed and giveup "Couldn't discover runlevel", @out;
	$out[0] !~ /^N [2-5]/ and giveup "Not in runlevel 2-5, this script probably won't work\n";
}
CHECK_RUNLEVEL:

# Remove CRS config
warn_section "LOCALCONFIG_DELETE";
{
	my @out = run "localconfig delete";
	failed and giveup "localconfig delete failed", @out;
}
LOCALCONFIG_DELETE:

# Change hostname
warn_section "CHANGE_HOSTNAME";
{
	my @out = run "sed -i 's/HOSTNAME=.*/HOSTNAME=$newhostname/' /etc/sysconfig/network";
	failed and giveup "Couldn't update hostname", @out;

	@out = run "hostname $newhostname";
	failed and giveup "Couldn't set hostname", @out;

	@out = run qq(sed -i "s/\\<$oldhostname\\>/$newhostname/g" /etc/hosts);
	failed and giveup "Couldn't change hostname in /etc/hosts", @out;
}
CHANGE_HOSTNAME:

# Add CRS config for new hostname and fix inittab runlevel
warn_section "LOCALCONFIG_ADD";
{
	my @out = run "localconfig add";
	failed and giveup "localconfig add failed", @out;

	@out = run 'echo -e "/^h1:.*cssd/ m /^l2/\nwq" | ed /etc/inittab';
	failed and giveup "modification of inittab failed", @out;
}
LOCALCONFIG_ADD:

# Start ASM
warn_section "START_ASM";
{
	my $fh = make_script <<EOF;
startup;
exit;
EOF

	local $ENV{ORACLE_HOME} = get_orahome("+ASM");
	local $ENV{ORACLE_SID} = "+ASM";
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start ASM", @out;
}
START_ASM:

# Start the DB
warn_section "START_DB";
{
	my $fh = make_script <<EOF;
startup mount;
exit;
EOF

	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start DB (ORACLE_SID=$oldsid)", @out;
}
START_DB:

# Create the pfile for the new SID
warn_section "CREATE_PFILE";
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
CREATE_PFILE:

# create directory for standby_archive_dest to stop it breaking nid
# Might not be required
warn_section "STANDBY_ARCHIVE_DEST";
{
	my $fh = make_script <<EOF;
set serveroutput on;
archive log list;
exit;
EOF

	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't create pfile", @out;

	my ($dest) =  grep { /Archive destination/ } @out;
	chomp $dest;
	$dest = (split /\s+/, $dest, 3)[-1];
	unless (-d $dest) {
		my @out = sudo oracle => "mkdir $dest";
		failed and giveup "Couldn't create standby_archive_dest directory $dest", @out;
	}
}
STANDBY_ARCHIVE_DEST:

# Update the pfile with the new paths
warn_section "MODIFY_PFILE";
{
	-e $newpfile or die "No pfile found at $newpfile for new SID\n";

	my @out = run <<EOF;
sed -i \\
    -e "s/db_name=.$oldsid./db_name='$newsid'/" \\
    -e "s/^$oldsid\./$newsid./" \\
    -e "/dispatchers=/ { s/SERVICE=$oldsid/SERVICE=$newsid/ }" \\
    -e "/\\(audit_file\\|\\(background\\|core\\|user\\)_dump\\)_dest=/ { s/$oldsid/$newsid/ }" \\
    $newpfile
EOF
	failed and giveup "Couldn't modify the pfile with the new db_name or logging destinations", @out;

	# Create the log directories
	open my $fh, "<$newpfile" or die "Can't open $newpfile: $!\n";
	while (my $line = <$fh>) {
		next unless $line =~ /((background|core|user|)_dump|audit_file)_dest=/;
		my (undef, $path) = split /=/, $line;
		chomp $path;
		$path =~ s/^["']//;
		$path =~ s/["']$//;

		if (-e $path)  { # Already exists
			if (not -d $path) { # Not a directory
				die "$path exists but is not a directory!\n";
			}
			else {
				chown @ids, $path or die "Couldn't chown directory: $!\n";
			}
		}
		else {
			my @created = mkpath($path, 1, 0755) or die "Couldn't create directory $path: $!\n";
			chown @ids, @created or die "Couldn't chown directory: $!\n";
		}
	}
}
MODIFY_PFILE:

# Make sure all of the database dump destinations are created, if not then this
# can cause nid to fail
warn_section "CREATE_DEST";
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
	chown @ids, @created;
}
CREATE_DEST:

# Change the DBID
# first do "alter database open" / "alter system switch logfile" to make sure
# NID can run, otherwise sometimes it reports that an instance is still
# running...
warn_section "CHANGE_DBID";
{
	my $fh = make_script <<'EOF';
alter database open;
alter system switch logfile;
shutdown immediate;
startup mount;
exit;
EOF

	local $ENV{ORACLE_HOME} = get_orahome($oldsid);
	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database", @out;

	@out = sudo "oracle" => "sh -c 'echo Y | nid target=/ setname=yes dbname=$newsid'";
	failed and giveup "Couldn't change DBID with nid", @out;
}
CHANGE_DBID:

# Start the DB with the new SID and create an spfile
warn_section "START_NEWDBID";
{
	my $fh = make_script <<'EOF';
startup;
create spfile from pfile;
exit;
EOF

	local $ENV{ORACLE_SID} = $newsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database and create spfile", @out;
}
START_NEWDBID:

# Move the old password file
warn_section "MOVE_ORAPWD";
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
MOVE_ORAPW:

# Update /etc/oratab
warn_section "UPDATE_ORATAB";
{
	my @out = run qq(sed -i "s/^$oldsid:/$newsid:/" /etc/oratab);
	failed and giveup "Couldn't alter /etc/oratab", @out;
}
UPDATE_ORATAB:

warn_section "CHKCONFIG_DBORA_ON";
{
	my @out = run qq(chkconfig dbora on);
	failed and giveup "Couldn't chkconfig dbora on", @out;
}
CHKCONFIG_DBORA_ON:

# Complete
{
	warn <<EOF;
Hostname/DBID change completed. You need to:
  1. Check the DB restarts correctly when the machine is rebooted
  2. Check /etc/profile.d/* and user profile files for ORACLE_SID definitions
  3. Update TNS names entries
  4. Check if other entries in /etc/hosts need to be changed
  5. Remove old pfiles, spfiles and old log directories
EOF
}
