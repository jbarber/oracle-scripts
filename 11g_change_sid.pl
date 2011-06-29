#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use File::Temp;

#$ENV{ORACLE_BASE} = "/u01/app";
#$ENV{GRID_HOME} = $ENV{ORACLE_BASE}."/11.2.0/grid";
#$ENV{ORACLE_HOME} = $ENV{ORACLE_BASE}."/oracle/product/11.2.0/db_1";

my ($oldhostname, $newhostname, $oldsid, $newsid, $noroot, $force, $help, $man, $skip, $list, $orahome, $gridhome);
GetOptions( 
	"newhostname=s" => \$newhostname,
	"oldsid=s"      => \$oldsid,
	"newsid=s"      => \$newsid,
	"help"          => \$help,
	"man"           => \$man,
	"noroot"        => \$noroot,
	"force"         => \$force,
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
	# Create PFILE for new DBID while system is online?
	# [ "CREATE_PFILE" ],
	# [ "MODIFY_PFILE" ],
	# [ "CREATE_DEST" ],
	# [ \&change_dbid, "CHANGE_DBID" ],
	# [ , "START_NEWDBID" ],
	# [ , "MOVE_ORAPWD" ],
	# [ , "CONFIG_LSNR" ],
	[ \&add_db, "ADD_DB", $oldsid, $orahome ], # FIXME: Change $oldsid to $newsid
	[ \&start_db, "START_DB", $oldsid, $orahome ], # FIXME: Change $oldsid to $newsid

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
		warn "### Skipping $label\n";
		if ($skip eq $label) {
			$seen = 1;
		}
		next;
	}

	warn_section $label;
	$sub->( @args );
}

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
	my ($orahome) = @_;
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
	# FIXME: Is force required?
	my @out = run "$gridhome/crs/install/roothas.pl";
	failed and giveup "Couldn't configure HAS", @out;

	@out = run 'echo -e "/^h1:.*ohasd/ m /^l2/\nwq" | ed /etc/inittab';
	failed and giveup "modification of inittab failed", @out;
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
	sleep 60;

	# Autostart all of the diskgroups
	my @out = sudo "grid" => "crsctl status resource -w 'TYPE = ora.diskgroup.type' | sed -n '/NAME/ { s/NAME=//; p }'";
	failed and giveup "Couldn't configure diskgroups to AUTO_START", @out;
	chomp @out;

	for my $diskgroup (@out) {
		my @auto = sudo "grid" => "crsctl modify resource $diskgroup -attr AUTO_START=1";
		failed and giveup "Couldn't configure diskgroup $diskgroup to AUTO_START", @auto;
	}
}

# TODO: Change NID...

sub add_db {
	my ($sid, $orahome) = @_;

	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl add database -d $sid -o $orahome";
	failed and giveup "Couldn't add DB to HAS", @out;

	@out = sudo "oracle" => "crsctl modify resource ora.$sid.db -attr AUTO_START=1";
	failed and giveup "Couldn't configure ora.$sid.db", @out;
}

sub start_db {
	my ($sid, $orahome) = @_;

	local $ENV{ORACLE_HOME} = $orahome;

	my @out = sudo "oracle" => "srvctl start database -d $sid";
	failed and giveup "Couldn't start DB", @out;
}
