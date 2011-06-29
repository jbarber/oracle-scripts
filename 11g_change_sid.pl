#!/usr/bin/env perl

=head1 NAME

11g_change_sid.pl

=head1 SYNOPSIS

11g_change_sid.pl --newhostname foo.bar.com --oldsid OLDSID --newsid NEWSID --orahome /u01/path/to/db/home --gridhome /u01/path/to/grid/home [--help] [--man] [--list] [--skip SECTION]

=head1 DESCRIPTION

Changes system hostname and updates Oracle database SID for 11g.

=head1 OPTIONS

=over

=item --newhostname foo.bar.com

The new host name of the host,

=item --oldsid OLDSID

The current SID of the database that you want to change.

=item --newsid NEWSID

The target SID of the OLDSID database.

=item --orahome $ORACLE_HOME

The path to the Oracle home of the database whose SID you are changing.

=item --gridhome $GRID_HOME

The path to the Oracle Grid home (where Grid was installed).

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

You can also list all of the sections in the program by using the L</"--list"> argument.

=item [--list]

Show all of the sections in the program.

=back

=head1 REQUISITES

=over

=item * Valid for Oracle 11g B<ONLY>.

=item * The hostname must B<NOT> have been changed, otherwise changing the CRS configuration will fail.

=item * The script should be run by root.

=item * CRS must be running

=back

=head1 RHEL RECOMMEND USAGE

=over

=item 1. Boot the machine into single user mode

=item 2. Prevent future kudzu interuptions because of NIC MAC addresses "service kudzu start"

=item 3. Configure network interfaces under /etc/sysconfig/network-scripts/ifcfg-eth*

=item 4. Update /etc/hosts

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

############################################################
# Utility functions
sub run {
	my ($cmd) = @_;
	warn "Running: $cmd\n";
	return qx($cmd 2>&1);
}

sub failed { $? ? 1 : 0 }

sub sudo {
	my ($user, $cmd) = @_;
	run qq(sudo -u $user -E $cmd);
}

sub am_i_root {
	$ENV{USER} eq 'root' or die "$0 should be run as root\n";
}

sub giveup {
	my ($mesg, @more) = @_;
	die "$mesg:\n", @more;
}

sub sqlplus {
	my ($user, $fn, $priv) = @_;
	$priv ||= "/ as sysdba";
	sudo $user => "sqlplus -S -L '$priv' \@$fn"
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

sub warn_section {
	my ($mesg) = @_;
	warn "### $mesg\n";
}

############################################################
# Functions that change configuration
sub check_hostname {
	my ($out) = run "hostname";
	chomp $out;
	if (lc $ENV{HOSTNAME} ne lc $out) {
		die "HOSTNAME environment variable ($ENV{HOSTNAME}) and output of hostname ($out) don't match. Fix it\n";
	}
}

sub check_runlevel {
	my (@out) = run "runlevel";
	failed and giveup "Couldn't discover runlevel", @out;
	$out[0] !~ /^N [2-5]/ and giveup "Not in runlevel 2-5, this script probably won't work\n";
}

sub check_db_exists {
	my ($oldsid, $orahome) = @_;
	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl status database -d $oldsid";
	failed and giveup "No database known with name $oldsid", @out;
}

sub stop_db {
	my ($oldsid, $orahome) = @_;
	local $ENV{ORACLE_HOME} = $orahome;
	my @out = sudo "oracle" => "srvctl stop database -d $oldsid";
	# exit code 2 == DB stopped already
	$? >> 8 == 2 && return;
	failed and giveup "Couldn't stop DB $oldsid", @out;
}

sub stop_asm {
	my ($orahome) = @_;
	local $ENV{ORACLE_HOME} = $orahome;

	# -f to force ASM to stop without relocating the diskgroups
	my @out = sudo "oracle" => "srvctl stop asm -f";
	# exit code 2 == ASM stopped already
	$? >> 8 == 2 && return;
	failed and giveup "Couldn't stop ASM", @out;
}

sub stop_has {
	my @out = sudo "grid" => "crsctl stop has";
	# exit code 2 == ASM stopped already
	$? >> 8 == 2 && return;
	failed and giveup "Couldn't stop HAS", @out;
}

sub deconfig_has {
	my ($gridhome) = @_;
	# FIXME: Is force required?
	my @out = run "$gridhome/crs/install/roothas.pl -deconfig -force";
	failed and giveup "Couldn't deconfigure HAS", @out;
}

sub change_hostname {
	my ($oldhostname, $newhostname) = @_;
	my @out = run "sed -i 's/HOSTNAME=.*/HOSTNAME=$newhostname/' /etc/sysconfig/network";
	failed and giveup "Couldn't update hostname", @out;

	@out = run "hostname $newhostname";
	failed and giveup "Couldn't set hostname", @out;

	@out = run qq(sed -i "s/\\<$oldhostname\\>/$newhostname/g" /etc/hosts);
	failed and giveup "Couldn't change hostname in /etc/hosts", @out;
}

sub config_has {
	my ($gridhome) = @_;
	my @out = run "$gridhome/crs/install/roothas.pl";
	failed and giveup "Couldn't configure HAS", @out;
}

sub config_resources {
	my ($gridhome) = @_;
	local $ENV{ORACLE_HOME} = $gridhome;
	my @out = sudo "grid" => 'crsctl modify resource ora.cssd -attr AUTO_START=1';
	failed and giveup "Couldn't configure ora.cssd", @out;

	@out = sudo "grid" => 'crsctl modify resource ora.diskmon -attr AUTO_START=1';
	failed and giveup "Couldn't configure ora.diskmon", @out;

	@out = sudo "grid" => 'srvctl add asm';
	failed and giveup "Couldn't add ora.asm", @out;

	@out = sudo 'grid' => 'crsctl modify resource ora.asm -attr AUTO_START=1';
	failed and giveup "Couldn't configure ora.asm", @out;
}

sub start_asm {
	my ($gridhome) = @_;
	local $ENV{ORACLE_HOME} = $gridhome;
	
	my @out = sudo "oracle" => 'srvctl start asm';
	failed and giveup "Couldn't start asm", @out;
}

sub online_diskgroups {
	my ($gridhome) = @_;
	my $fh = make_script <<'EOF';
begin
  for dg in (select name from v$asm_diskgroup) loop
    execute immediate 'alter diskgroup ' || dg.name || ' mount';
  end loop;
end;
/
exit;
EOF
	local $ENV{ORACLE_SID} = "+ASM";
	local $ENV{ORACLE_HOME} = $gridhome;
	my @out = sqlplus "grid" => $fh->filename, "/ as sysasm";
	failed and giveup "Couldn't bring diskgroups online", @out;

	# Autostart all of the diskgroups
	@out = sudo "grid" => "crsctl status resource -w 'TYPE = ora.diskgroup.type' | sed -n '/NAME/ { s/NAME=//; p }'";
	failed and giveup "Couldn't configure diskgroups to AUTO_START", @out;
	chomp @out;

	for my $diskgroup (@out) {
		my @auto = sudo "grid" => "crsctl modify resource $diskgroup -attr AUTO_START=1";
		failed and giveup "Couldn't configure diskgroup $diskgroup to AUTO_START", @auto;
	}
}

sub create_pfile {
	my ($oldsid, $newsid, $orahome) = @_;

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
	local $ENV{ORACLE_HOME} = $orahome;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't create pfile", @out;

	# Handle pfile
	if (grep { /No spfile/ } @out) {
		# Do this with sudo so the ownership is correct
		my @out = sudo "oracle" => "cp $orahome/dbs/init$oldsid.ora $orahome/dbs/init$newsid.ora";
		failed and giveup "Couldn't copy pfile", @out;
	}
}

sub modify_pfile {
	my ($oldsid, $newsid, $orahome) = @_;
	my $newpfile = "$orahome/dbs/init$newsid.ora";
	-e $newpfile or die "No pfile found at $newpfile for new SID\n";
	my @ids = get_uid_gid("oracle");

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

sub change_dbid {
	my ($oldsid, $newsid, $orahome) = @_;
	my $fh = make_script <<'EOF';
alter database open;
alter system switch logfile;
shutdown immediate;
startup mount;
exit;
EOF

	local $ENV{ORACLE_HOME} = $orahome;
	local $ENV{ORACLE_SID} = $oldsid;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database", @out;

	@out = sudo "oracle" => "sh -c 'echo Y | nid target=/ setname=yes dbname=$newsid'";
	failed and giveup "Couldn't change DBID with nid", @out;
}

sub add_db {
	my ($sid, $orahome) = @_;

	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl add database -d $sid -o $orahome";
	failed and giveup "Couldn't add DB to HAS", @out;

	@out = sudo "oracle" => "crsctl modify resource ora.$sid.db -attr AUTO_START=1";
	failed and giveup "Couldn't configure ora.$sid.db", @out;
}

sub remove_db {
	my ($sid, $orahome) = @_;

	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl remove database -d $sid -y";
	failed and giveup "Couldn't remove DB $sid from HAS", @out;
}

sub move_orapwd {
	my ($oldsid, $newsid, $orahome) = @_;
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

sub start_db {
	my ($sid, $orahome) = @_;

	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl start database -d $sid";
	failed and giveup "Couldn't start DB", @out;
}

sub create_spfile {
	my ($sid, $orahome) = @_;
	my $fh = make_script <<'EOF';
create spfile from pfile;
exit;
EOF

	local $ENV{ORACLE_SID} = $sid;
	local $ENV{ORACLE_HOME} = $orahome;
	my @out = sqlplus "oracle" => $fh->filename;
	failed and giveup "Couldn't start the database and create spfile", @out;
}

sub add_listener {
	my ($orahome) = @_;
	local $ENV{ORACLE_HOME} = $orahome;
	my @out = sudo "grid" => "srvctl add listener";
	failed and giveup "Couldn't add listener", @out;

	@out = sudo "grid" => "srvctl start listener";
	failed and giveup "Couldn't start listener", @out;

	# FIXME: Assume listener name is fixed...
	my $lsnr = "ora.LISTENER.lsnr";
	@out = sudo "grid" => "crsctl modify resource $lsnr -attr AUTO_START=1";
	failed and giveup "Couldn't AUTO_START $lsnr", @out;
}

############################################################
# Parse command line
my ($oldhostname, $newhostname, $oldsid, $newsid, $noroot, $help, $man, $skip, $list, $orahome, $gridhome);
GetOptions( 
	"newhostname=s" => \$newhostname,
	"oldsid=s"      => \$oldsid,
	"newsid=s"      => \$newsid,
	"help"          => \$help,
	"man"           => \$man,
	"noroot"        => \$noroot,
	"skip=s"        => \$skip,
	"list"		=> \$list,
	"orahome=s"     => \$orahome,
	"gridhome=s"    => \$gridhome,
) or pod2usage(-verbose => 0);

$help        && pod2usage { -verbose => 0 };
$man         && pod2usage { -verbose => 2 };
$newhostname || pod2usage "Missing --newhostname option";
$oldsid      || pod2usage "Missing --oldsid option";
$newsid      || pod2usage "Missing --newsid option";
$noroot      || am_i_root();
$oldhostname = $ENV{HOSTNAME};
$oldsid eq $newsid && die "--oldsid is the same as --newsid, nothing to do\n";
$orahome     || pod2usage "Missing --orahome option";
$gridhome    || pod2usage "Missing --gridhome option";

$ENV{PATH} .= ":$orahome/bin:$gridhome/bin";

my @parts = (
	[ \&check_hostname, "CHECK_HOSTNAME" ],
	[ \&check_runlevel, "CHECK_RUNLEVEL" ],
	[ \&check_db_exists, "CHECK_DB_EXISTS", $oldsid, $orahome ],
	[ \&stop_db, "STOP_DB", $oldsid, $orahome ],
	[ \&stop_asm, "STOP_ASM", $orahome ],
	[ \&stop_has, "STOP_HAS" ],
	[ \&deconfig_has, "DECONFIG_HAS", $gridhome ],
	[ \&change_hostname, "CHANGE_HOSTNAME", $oldhostname, $newhostname ],
	[ \&config_has, "CONFIG_HAS", $gridhome ],
	[ \&config_resources, "CONFIG_RESOURCES", $gridhome ],
	[ \&start_asm, "START_ASM", $orahome ],
	[ \&online_diskgroups, "ONLINE_DISKGROUPS", $gridhome ],
	[ \&add_db, "ADD_OLD_SID_TO_HAS", $oldsid, $orahome ],
	[ \&start_db, "START_OLD_SID_DB", $oldsid, $orahome ],
	[ \&create_pfile, "CREATE_PFILE", $oldsid, $newsid, $orahome ],
	[ \&modify_pfile, "MODIFY_PFILE", $oldsid, $newsid, $orahome ],
	[ \&change_dbid, "CHANGE_DBID", $oldsid, $newsid, $orahome ],
	[ \&move_orapwd, "MOVE_ORAPWD", $oldsid, $newsid, $orahome ],
	[ \&create_spfile, "CREATE_SPFILE", $newsid, $orahome ],
	[ \&remove_db, "REMOVE_OLD_DB_FROM_HAS", $oldsid, $orahome ],
	[ \&add_db, "ADD_NEW_SID_TO_HAS", $newsid, $orahome ],
	[ \&start_db, "START_NEW_SID_DB", $newsid, $orahome ],
	[ \&add_listener, "CONFIG_LSNR", $gridhome ],
);

if ($list) {
	print "Sections:\n";
	for my $part (@parts) {
		print "  ", $part->[1], "\n";
	}
	exit;
}

my $seen;
for my $part (@parts) {
	my ($sub, $label, @args) = @{$part};
	if ($skip and ! $seen) {
		warn "## Skipping $label\n";
		if ($skip eq $label) {
			$seen = 1;
		}
		next;
	}

	warn_section $label;
	$sub->( @args );
}
