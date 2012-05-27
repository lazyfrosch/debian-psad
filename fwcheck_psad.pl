#!/usr/bin/perl -w
#
###############################################################################
#
# File: fwcheck_psad.pl (/usr/sbin/fwcheck_psad)
#
# Purpose: To parse the iptables ruleset on the underlying system to see if
#          iptables has been configured to log and block unwanted packets by
#          default.  This program is called by psad, but can also be executed
#          manually from the command line.
#
# Author: Michael Rash (mbr@cipherdyne.org)
#
# Credits: (see the CREDITS file bundled with the psad sources.)
#
# Copyright (C) 1999-2012 Michael Rash (mbr@cipherdyne.org)
#
# License (GNU Public License):
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
#    USA
#
###############################################################################
#

use Getopt::Long 'GetOptions';
use strict;

### default psad config file.
my $config_file  = '/etc/psad/psad.conf';

### config hash
my %config = ();
my $override_config_str = '';

### commands hash
my %cmds = ();

### fw search string array
my @fw_search = ();

my $help = 0;
my $test_mode = 0;
my $fw_analyze = 0;
my $fw_file    = '';
my $fw_search_all = 1;
my $no_fw_search_all = 0;
my $log_and_drop_table = 'filter';
my $enable_ipv6 = 0;
my $psad_lib_dir = '';

&usage(1) unless (GetOptions(
    'config=s'    => \$config_file, # Specify path to configuration file.
    'fw-file=s'   => \$fw_file,     # Analyze ruleset contained within
                                    # $fw_file instead of a running
                                    # policy.
    'fw-analyze'  => \$fw_analyze,  # Analyze the local iptables ruleset
                                    # and exit.
    'no-fw-search-all' => \$no_fw_search_all, # looking for specific log
                                              # prefixes
    'Lib-dir=s'   => \$psad_lib_dir,# Specify path to psad lib directory.
    'Override-config=s' => \$override_config_str,
    'test-mode'   => \$test_mode,   # Used by the test suite.
    'help'        => \$help,        # Display help.
));
&usage(0) if $help;

$fw_search_all = 0 if $no_fw_search_all;

### Everthing after this point must be executed as root.
$< == 0 and $> == 0 or
    die '[*] fwcheck_psad.pl: You must be root (or equivalent ',
        "UID 0 account) to execute fwcheck_psad.pl!  Exiting.\n";

if ($fw_file) {
    die "[*] iptables dump file: $fw_file does not exist."
        unless -e $fw_file;
}

### import any override config files first
&import_override_configs() if $override_config_str;

### import psad.conf
&import_config($config_file);

$enable_ipv6 = 1 if $config{'ENABLE_IPV6_DETECTION'} eq 'Y';

### import FW_MSG_SEARCH strings
&import_fw_search($config_file);

### expand any embedded vars within config values
&expand_vars();

### check to make sure the commands specified in the config section
### are in the right place, and attempt to correct automatically if not.
&check_commands({});

### import psad perl modules
&import_psad_perl_modules();

open FWCHECK, "> $config{'FW_CHECK_FILE'}" or die "[*] Could not ",
    "open $config{'FW_CHECK_FILE'}: $!";

unless ($fw_search_all) {
    print FWCHECK "[+] Available search strings in $config_file:\n\n";
    print FWCHECK "        $_\n" for @fw_search;
    print FWCHECK
"\n[+] Additional search strings can be added be specifying more\n",
    "    FW_MSG_SEARCH lines in $config_file\n\n";
}

### check the iptables policy
my $rv = &fw_check();

close FWCHECK;

exit $rv;

#========================== end main =========================

sub fw_check() {

    ### only send a firewall config alert if we really need to.
    my $send_alert = 0;

    my $forward_chain_rv = 1;
    my $input_chain_rv = &ipt_chk_chain('INPUT', $cmds{'iptables'});
    unless ($input_chain_rv) {
        &print_fw_help('INPUT', $cmds{'iptables'});
        $send_alert = 1;
    }

    if ($enable_ipv6) {
        my $tmp_rv = &ipt_chk_chain('INPUT', $cmds{'ip6tables'});
        unless ($tmp_rv) {
            &print_fw_help('INPUT', $cmds{'ip6tables'});
            $send_alert = 1;
            $input_chain_rv = 0;
        }
    }

    ### we don't always have more than one interface or forwarding
    ### turned on, so we only check the FORWARD iptables chain if we
    ### do and we have multiple interfaces on the box.
    if (&check_forwarding()) {
        $forward_chain_rv = &ipt_chk_chain('FORWARD', $cmds{'iptables'});
        unless ($forward_chain_rv) {
            &print_fw_help('FORWARD', $cmds{'iptables'});
            $send_alert = 1;
        }
    }

    if ($send_alert) {
        unless ($fw_search_all) {
            print FWCHECK
"\n[+] NOTE: IPTables::Parse does not yet parse user defined chains and so\n",
"    it is possible your firewall config is compatible with psad anyway.\n";
        }

        unless ($config{'ALERTING_METHODS'} =~ /no.?e?mail/i or $test_mode) {
            &send_mail("[psad-status] firewall setup warning on " .
                "$config{'HOSTNAME'}!", $config{'FW_CHECK_FILE'},
                $config{'EMAIL_ADDRESSES'},
                $cmds{'mail'}
            );
        }
        if ($fw_analyze and not $test_mode) {
            print "[-] Errors found in firewall config.\n";
            print "    emailed to ",
                "$config{'EMAIL_ADDRESSES'}\n";
        }
    } else {
        print FWCHECK
"[+] The iptables ruleset on $config{'HOSTNAME'} will log and block unwanted\n",
"    packets in both the INPUT and FORWARD chains.  Firewall config success!\n";

        if ($fw_analyze) {
            print "[+] Firewall config looks good.\n",
                "[+] Completed check of firewall ruleset.\n";
        }
    }
    if ($fw_analyze) {
        print "[+] Results in $config{'FW_CHECK_FILE'}\n",
            "[+] Exiting.\n";
    }
    return $forward_chain_rv and $input_chain_rv;
}

sub print_fw_help() {
    my ($chain, $ipt_bin) = @_;
    print FWCHECK
"[-] You may just need to add a default logging rule to the $ipt_bin\n",
"    '$log_and_drop_table' '$chain' chain on $config{'HOSTNAME'}.  For more information,\n",
"    see the file \"FW_HELP\" in the psad sources directory or visit:\n\n",
"    http://www.cipherdyne.org/psad/docs/fwconfig.html\n\n";
    return;
}

sub check_forwarding() {
    ### check to see if there are multiple interfaces on the
    ### machine and return false if not since the machine will
    ### not be able to forward packets anyway (e.g. desktop
    ### machines).  Also return false if forwarding is turned
    ### off (we have to trust the machine config is as the
    ### admin wants it).
    my $forwarding;
    if (-e $config{'PROC_FORWARD_FILE'}) {
        open F, "< $config{'PROC_FORWARD_FILE'}"
            or die "[*] Could not open $config{'PROC_FORWARD_FILE'}: $!";
        $forwarding = <F>;
        close F;
        chomp $forwarding;
        return 0 if $forwarding == 0;
    } else {
        die "[*] Make sure the path to the IP forwarding file correct.\n",
            "    The PROC_FORWARD_FILE in $config_file points to\n",
            "    $config{'PROC_FORWARD_FILE'}";
    }
    if ($config{'IFCFGTYPE'} =~ /iproute2/i) {
        open IFC, "$cmds{'ip'} addr |" or die "[*] Could not ",
            "execute: $cmds{'ip'} addr: $!";
        my @if_out = <IFC>;
        close IFC;
        my $intf_name = '';
        my $intf_inet_count = 0;
        my $num_intf = 0;
        for my $line (@if_out) {
            if ($line =~ /^\d+:\s+(\S+)\:\s</) {
                $intf_name = $1;
                if ($intf_inet_count > 0) {
                    $num_intf++;
                }
                $intf_inet_count = 0;
                next;
            }
            next if $intf_name eq 'lo';
            next if $intf_name =~ /dummy/i;
            if ($line =~ /inet\s+/i) {
                $intf_inet_count++;
            }
        }
        if ($intf_inet_count > 0) {
            $num_intf++;
        }
        if ($num_intf < 2) {
            return 0;
        }
    } else {
        open IFC, "$cmds{'ifconfig'} -a |" or die "[*] Could not ",
            "execute: $cmds{'ifconfig'} -a: $!";
        my @if_out = <IFC>;
        close IFC;
        my $num_intf = 0;
        for my $line (@if_out) {
            if ($line =~ /inet\s+/i and $line !~ /127\.0\.0\.1/) {
                $num_intf++;
            }
        }
        if ($num_intf < 2) {
            return 0;
        }
    }
    return 1;
}

sub ipt_chk_chain() {
    my ($chain, $ipt_bin) = @_;
    my $rv = 1;

    my $ipt = new IPTables::Parse 'iptables' => $ipt_bin
        or die "[*] Could not acquire IPTables::Parse object: $!";

    if ($fw_analyze) {
        print "[+] Parsing $ipt_bin $chain chain rules.\n";
    }

    if ($fw_search_all) {
        ### we are not looking for specific log
        ### prefixes, but we need _some_ logging rule
        my ($ipt_log, $ipt_rv) = $ipt->default_log($log_and_drop_table, $chain, $fw_file);
        return 0 unless $ipt_rv;
        if (defined $ipt_log->{'all'}) {
            ### found real default logging rule (assuming it is above a default
            ### drop rule, which we are not actually checking here).
            return 1;
        } else {
            my $log_protos    = '';
            my $no_log_protos = '';
            for my $proto (qw(tcp udp icmp)) {
                if (defined $ipt_log->{$proto}) {
                    $log_protos .= "$proto/";
                } else {
                    $no_log_protos .= "$proto/";
                }
            }
            $log_protos =~ s|/$||;
            $no_log_protos =~ s|/$||;

            if ($log_protos) {
                print FWCHECK
"[-] Your firewall config on $config{'HOSTNAME'} includes logging rules for\n",
"    $log_protos but not for $no_log_protos in the $chain chain.\n\n";
                return 0;
            } else {
                print FWCHECK
"[-] Could not determine whether the $ipt_bin $chain chain is configured with\n",
"    a default logging rule on $config{'HOSTNAME'}.\n\n";
                return 0;
            }
        }
    } else {
        ### we are looking for specific log prefixes.
        ### for now we are only looking at the filter table, so if
        ### the iptables ruleset includes the log and drop rules in
        ### a user defined chain then psad will not see this.
        my ($ld_hr, $ipt_rv) = $ipt->default_drop($log_and_drop_table,
                $chain, $fw_file);

        return 0 unless $ipt_rv;

        my $num_keys = 0;
        if (defined $ld_hr and keys %$ld_hr) {
            $num_keys++;
            my @protos;
            if (defined $ld_hr->{'all'}) {
                @protos = (qw(all));
            } else {
                @protos = (qw(tcp udp icmp));
            }
            for my $proto (@protos) {
                my $str1;
                my $str2;
                if (! defined $ld_hr->{$proto}->{'LOG'}) {
                    if ($proto eq 'all') {
                        $str1 = 'for all protocols';
                        $str2 = 'scans';
                    } else {
                        $str1 = "for the $proto protocol";
                        $str2 = "$proto scans";
                    }
                    print FWCHECK
"[-] The $chain chain in the $ipt_bin ruleset on $config{'HOSTNAME'} does not\n",
"    appear to include a default LOG rule $str1.  psad will not be able to\n",
"    detect $str2 without such a rule.\n\n";

                    $rv = 0;
                }
                if (defined $ld_hr->{$proto}->{'LOG'}->{'prefix'}) {
                    my $found = 0;
                    for my $fwstr (@fw_search) {
                        $found = 1
                            if $ld_hr->{$proto}->{'LOG'}->{'prefix'} =~ /$fwstr/;
                    }
                    unless ($found) {
                        if ($proto eq 'all') {
                            $str1 = "[-] The $chain chain in the $ipt_bin ruleset " .
                            "on $config{'HOSTNAME'} includes a default\n    LOG rule for " .
                            "all protocols,";
                            $str2 = 'scans';
                        } else {
                            $str1 = "[-] The $chain chain in the $ipt_bin ruleset " .
                            "on $config{'HOSTNAME'} inclues a default\n    LOG rule for " .
                            "the $proto protocol,";
                            $str2 = "$proto scans";
                        }
                        print FWCHECK
"$str1\n",
"    but the rule does not include one of the log prefixes mentioned above.\n",
"    It appears as though the log prefix is set to \"$ld_hr->{$proto}->{'LOG'}->{'prefix'}\"\n",
"    psad will not be able to detect $str2 without adding one of the above\n",
"    logging prefixes to the rule.\n\n";
                        $rv = 0;
                    }
                }
                if (! defined $ld_hr->{$proto}->{'DROP'}) {
                    if ($proto eq 'all') {
                        $str1 = "for all protocols";
                    } else {
                        $str1 = "for the $proto protocol";
                    }
                    print FWCHECK
"[-] The $chain chain in the $ipt_bin ruleset on $config{'HOSTNAME'} does not\n",
"    appear to include a default DROP rule $str1.\n\n";
                    $rv = 0;
                }
            }
        }
        ### make sure there was _something_ returned from the IPTables::Parse
        ### module.
        return 0 unless $num_keys > 0;
    }
    return $rv;
}

sub import_psad_perl_modules() {

    my $mod_paths_ar = &get_psad_mod_paths();

    if ($#$mod_paths_ar > -1) {  ### /usr/lib/psad/ exists
        push @$mod_paths_ar, @INC;
        splice @INC, 0, $#$mod_paths_ar+1, @$mod_paths_ar;
    }

    require IPTables::Parse;

    return;
}

sub get_psad_mod_paths() {

    my @paths = ();

    $config{'PSAD_LIBS_DIR'} = $psad_lib_dir if $psad_lib_dir;

    unless (-d $config{'PSAD_LIBS_DIR'}) {
        my $dir_tmp = $config{'PSAD_LIBS_DIR'};
        $dir_tmp =~ s|lib/|lib64/|;
        if (-d $dir_tmp) {
            $config{'PSAD_LIBS_DIR'} = $dir_tmp;
        } else {
            return [];
        }
    }

    opendir D, $config{'PSAD_LIBS_DIR'}
        or die "[*] Could not open $config{'PSAD_LIBS_DIR'}: $!";
    my @dirs = readdir D;
    closedir D;

    push @paths, $config{'PSAD_LIBS_DIR'};

    for my $dir (@dirs) {
        ### get directories like "/usr/lib/psad/x86_64-linux"
        next unless -d "$config{'PSAD_LIBS_DIR'}/$dir";
        push @paths, "$config{'PSAD_LIBS_DIR'}/$dir"
            if $dir =~ m|linux| or $dir =~ m|thread|
                or (-d "$config{'PSAD_LIBS_DIR'}/$dir/auto");
    }
    return \@paths;
}

sub import_fw_search() {
    my $config_file = shift;

    open F, "< $config_file" or die "[*] Could not open fw search ",
        "string file $config_file: $!";
    my @lines = <F>;
    close F;
    for my $line (@lines) {
        next unless $line =~ /\S/;
        next if $line =~ /^\s*#/;
        if ($line =~ /^\s*FW_MSG_SEARCH\s+(.*?);/) {
            push @fw_search, $1;
        }
    }
    return;
}

### send mail message to all addresses contained in the
### EMAIL_ADDRESSES variable within psad.conf ($addr_str).
### TODO:  Would it be better to use Net::SMTP here?
sub send_mail() {
    my ($subject, $body_file, $addr_str, $mailCmd) = @_;
    open MAIL, "| $mailCmd -s \"$subject\" $addr_str > /dev/null" or die
        "[*] Could not send mail: $mailCmd -s \"$subject\" $addr_str: $!";
    if ($body_file) {
        open F, "< $body_file" or die "[*] Could not open mail file: ",
            "$body_file: $!";
        my @lines = <F>;
        close F;
        print MAIL for @lines;
    }
    close MAIL;
    return;
}

sub import_override_configs() {
    my @override_configs = split /,/, $override_config_str;
    for my $file (@override_configs) {
        die "[*] Override config file $file does not exist"
            unless -e $file;
        &import_config($file);
    }
    return;
}

sub import_config() {
    my $conf_file = shift;

    open C, "< $conf_file" or die "[*] Could not open " .
        "config file $conf_file: $!";
    my @lines = <C>;
    close C;
    for my $line (@lines) {
        chomp $line;
        next if ($line =~ /^\s*#/);
        if ($line =~ /^\s*(\S+)\s+(.*?)\;/) {
            my $varname = $1;
            my $val     = $2;
            if ($val =~ m|/.+| and $varname =~ /^\s*(\S+)Cmd$/) {
                ### found a command
                $cmds{$1} = $val unless defined $cmds{$1};
            } else {
                $config{$varname} = $val unless defined $config{$varname};
            }
        }
    }

    return;
}

sub expand_vars() {

    my $has_sub_var = 1;
    my $resolve_ctr = 0;

    while ($has_sub_var) {
        $resolve_ctr++;
        $has_sub_var = 0;
        if ($resolve_ctr >= 20) {
            die "[*] Exceeded maximum variable resolution counter.";
        }
        for my $hr (\%config, \%cmds) {
            for my $var (keys %$hr) {
                my $val = $hr->{$var};
                if ($val =~ m|\$(\w+)|) {
                    my $sub_var = $1;
                    die "[*] sub-ver $sub_var not allowed within same ",
                        "variable $var" if $sub_var eq $var;
                    if (defined $config{$sub_var}) {
                        if ($sub_var eq 'INSTALL_ROOT'
                                and $config{$sub_var} eq '/') {
                            $val =~ s|\$$sub_var||;
                        } else {
                            $val =~ s|\$$sub_var|$config{$sub_var}|;
                        }
                        $hr->{$var} = $val;
                    } else {
                        die "[*] sub-var \"$sub_var\" not defined in ",
                            "config for var: $var."
                    }
                    $has_sub_var = 1;
                }
            }
        }
    }
    return;
}

### check paths to commands and attempt to correct if any are wrong.
sub check_commands() {
    my $exceptions_hr = shift;
    my $caller = $0;
    my @path = (qw(
        /bin
        /sbin
        /usr/bin
        /usr/sbin
        /usr/local/bin
        /usr/local/sbin
    ));
    CMD: for my $cmd (keys %cmds) {
        ### both mail and sendmail are special cases, mail is not required
        ### if "nomail" is set in REPORT_METHOD, and sendmail is only
        ### required if DShield alerting is enabled and a DShield user
        ### email is set.
        if ($cmd eq 'mail') {
            next CMD if $config{'ALERTING_METHODS'} =~ /no.?e?mail/i;
        } elsif ($cmd eq 'sendmail') {
            next CMD unless ($config{'ENABLE_DSHIELD_ALERTS'} eq 'Y'
                and $config{'DSHIELD_ALERT_EMAIL'} ne 'NONE');
        }

        next if $cmd eq 'wget';  ### only used in --sig-update mode
        unless (-x $cmds{$cmd}) {
            my $found = 0;
            PATH: for my $dir (@path) {
                if (-x "${dir}/${cmd}") {
                    $cmds{$cmd} = "${dir}/${cmd}";
                    $found = 1;
                    last PATH;
                }
            }
            unless ($found) {
                unless (defined $exceptions_hr->{$cmd}) {
                    die "[*] ($caller): Could not find $cmd ",
                        "anywhere!!!\n    Please edit the config section ",
                         "to include the path to $cmd.";
                }
            }
        }
        unless (-x $cmds{$cmd}) {
            unless (defined $exceptions_hr->{$cmd}) {
                die "[*] ($caller): $cmd is located at ",
                    "$cmds{$cmd}, but is not executable\n",
                    "    by uid: $<";
            }
        }
    }
    return;
}

sub usage() {
    my $exitcode = shift;
    print <<_HELP_;

Options:
    --config <config_file>            - Specify path to configuration
                                        file.
    --fw-file    <fw_file>            - Analyze ruleset contained within
                                        fw_file instead of a running
                                        policy.
    --fw-analyze                      - Analyze the local iptables
                                        ruleset and exit.
    --no-fw-search-all                - looking for specific log
                                        prefixes.
    --Lib-dir <dir>                   - Path to the psad lib directory.
    --test-mode                       - Enable test mode (used by the
                                        test suite).
    --help                            - Display help.

_HELP_
    exit $exitcode;
}
