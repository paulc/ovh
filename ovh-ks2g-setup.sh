#!/bin/sh

##
# Utility Functions
##

_NORMAL=$(printf "\033[0m")
_RED=$(printf "\033[0;31m")
_CYAN=$(printf "\033[0;36m")

# Log shell command and status to stdout indenting output 
# (optionally in colour)
_log() {
	local _cmd="$*"
	printf "${_COLOUR:+${_RED}}"
	printf "%s [%s] %-40s\n" "$(date '+%b %d %T')" $name "CMD: $_cmd"
	printf "${_COLOUR:+${_CYAN}}"
	eval "$_cmd" 2>&1 | sed -e 's/^/     | /'
	local _status=$?
	printf "${_COLOUR:+${_RED}}"
	[ $_status -eq 0 ] && printf "[OK]\n" || printf "[ERROR]\n"
	printf "${_COLOUR:+${_NORMAL}}"
	return $_status
}

# Backup configuration file
_backup() {
	local _f=$1
	if [ ! -f ${_f}.ovh ]
	then
		printf "Backing up file: %s -> %s.ovh " $_f $_f
		cp ${_f} ${_f}.ovh && printf "[OK]\n"
	else
		printf "Backup file %s.ovh exists\n" $_f
	fi
}

# Get functions from script (not prefixed with _) and run interactively
_interactive() {
	_FUNCS="$(sed -ne '/^[a-zA-Z][a-zA-Z0-9_]*()/s/(.*//p' $0)"
	while :
	do
		printf "Available Commands:\n"
		for f in $_FUNCS
		do
			printf "  $f\n"
		done

		read -p "Command: " _f
		if [ ${#_f} -gt 0 ]
		then
			eval _log $_f
		else
			break
		fi
	done
}

# Get configuration variable interactively or automatically (if _AUTO=1)
# Default value is calculated from existing variable value (if set) or
# the argument provided (which would normally be a shell command inspecting
# system
_config() {
	# Echo output if -echo flag set
	[ "$1" = "-echo" ] && shift && local _echo=1
	local _var="$1"
	local _msg="$2"
	local _default="$3"
	local _r
	# Check if _var is alraedy set - if so use as default rather than arg
	if eval [ \${#$_var} -gt 0 ]
	then
		eval _default="\$${_var}"
	fi
	# If _AUTO != 1 prompt interactively
	if [ "$_AUTO" != "1" ]
	then
		if [ ${#_default} -gt 0 ]
		then
			read -p "${_msg} [${_default}]: " _r
		else
			read -p "${_msg}: " _r
		fi
	fi
	# Set variable
	eval ${_var}=\"${_r:-${_default}}\"
	[ "${_echo}" = 1 ] && eval echo \$${_var}
}

# Print file with title & line numbers
_print() {
	local _f="$1"
	printf "$_f\n"
	nl -ba "$_f"
	sha1 "$_f"
}

##
# Utilities to inspect system
##

rc_conf_get() {
	sed -ne "/^$1=/s/.*=\"*\([^\"]*\).*/\1/p"  /etc/rc.conf
}

_get_ext_if() {
	route -n get -inet default | awk '/interface:/ { print $2 }'
}

_get_ipv4() {
    ifconfig $_EXT_IF | awk '/inet[^6]/ { print $2; exit }'
}

_get_ipv4_mask() {
	ifconfig $_EXT_IF | awk '/inet[^6]/ { print $4; exit }'
}

_get_ipv4_gw() {
	route -n get -inet default | awk '/gateway:/ { print $2 }'
}

_get_ipv6() {
	ifconfig $_EXT_IF | awk '/inet6/ { if ( substr($2,0,4) != "fe80" ) { print $2; exit } }'
}

_get_ipv6_prefix() {
	ifconfig $_EXT_IF | awk '/inet6/ { if ( substr($2,0,4) != "fe80" ) { print $4; exit } }'
}

_get_ipv6_gw() {
	route -n get -inet6 default | awk '/gateway:/ { print $2 }'
}

update_system() {
	(freebsd-update fetch && freebsd-update install) | cat 
}

##
# System configuration 
##

update_fstab() {
	_backup /etc/fstab
	cat > /etc/fstab <<-'EOM'
		# Device                Mountpoint      FStype  Options         Dump    Pass#
		/dev/ada0s1a            /               ufs             rw      1       1
		/dev/ada0s1b            none            swap            sw      0       0
		tmpfs                   /tmp            tmpfs           rw,noexec,mode=777,size=1073741824 0 0
		proc                    /proc           procfs          rw      0       0
		#/dev/ada0s1d           /pool           ufs             rw      2       2
	EOM
	_print /etc/fstab
}

update_sysctl_conf() {
	_backup /etc/sysctl.conf
	cat > /etc/sysctl.conf <<-'EOM'
		net.inet6.ip6.accept_rtadv=1
		net.link.ether.inet.log_arp_movements=0
		net.inet6.ip6.auto_linklocal=0
	EOM
	_print /etc/sysctl.conf
}

update_resolv_conf() {
	_backup /etc/resolv.conf
	cat > /etc/resolv.conf <<-'EOM'
		nameserver 8.8.8.8
		nameserver 8.8.4.4
		nameserver 2001:4860:4860::8888
		nameserver 2001:4860:4860::8844
	EOM
	_print /etc/resolv.conf
}

update_rc_conf() {

	_backup /etc/rc.conf

	cat > /etc/rc.conf <<-EOM
		# System
		fsck_y_enable="YES"
		dumpdev="AUTO"

		# IPv4
		ifconfig_${_EXT_IF}="inet ${_IPV4}"
		defaultrouter="${_IPV4_GW}"
		hostname="${_HOSTNAME}"

		cloned_interfaces="lo1"
		ipv4_addrs_lo1="10.0.1.1-63/24"

		# IPv6
		ifconfig_${_EXT_IF}_ipv6="inet6 ${_IPV6} prefixlen ${_IPV6_PREFIX} accept_rtadv"
		ipv6_defaultrouter="${_IPV6_GW}"

		# Services
		ntpdate_enable="YES"
		ntpdate_hosts="213.186.33.99"
		syslogd_flags="-s -b 127.0.0.1"
		sshd_enable="YES"
		gateway_enable="YES"
		pf_enable="YES"
		pflog_enable="YES"
		ezjail_enable="YES"
		zfs_enable="YES"
	EOM

	_print /etc/rc.conf
}

create_pf_conf() {

	sed -e "s/___EXT_IF___/${_EXT_IF}/" <<-'EOM' > /etc/pf.conf

		ext_if = "{ ___EXT_IF___ }"
		nat_if = "{ lo1 }"

		tcp_services = "{ ssh }"

		nat pass on $ext_if from $nat_if to any -> $ext_if

		rdr-anchor redirect-anchor

		set skip on lo1
		antispoof for $ext_if

		block in log on $ext_if proto { udp tcp }

		pass out on $ext_if keep state
		pass in on $ext_if proto tcp to $ext_if port $tcp_services keep state

		anchor filter-anchor
	EOM

	_print /etc/pf.conf
}

set_localtime() {
	_backup /etc/localtime
	cp /usr/share/zoneinfo/UTC /etc/localtime
	date
}

update_crontab() {
	_backup /etc/crontab
	cat >> /etc/crontab <<-'EOM'
		# Run ntpd -q hourly (rather than as daemon)
		0	*	*	*	*	root	/usr/sbin/ntpd -gq >/dev/null
	EOM
	_print /etc/crontab
}

update_sshd_config() {
	_backup /etc/ssh/sshd_config
	cat > /etc/ssh/sshd_config <<-EOM
		Port 22
		ListenAddress ${_IPV4}
		ListenAddress 127.0.0.1
		ListenAddress ${_IPV6}
		ListenAddress ::1

		PermitRootLogin yes
		PubkeyAuthentication yes
		PasswordAuthentication no
		KerberosAuthentication no
		GSSAPIAuthentication no
		ChallengeResponseAuthentication no
		UsePAM no

		Subsystem     sftp     /usr/libexec/sftp-server
	EOM
	_print /etc/ssh/sshd_config
}

add_ssh_keys() {
	cat > /root/.ssh/authorized_keys <<-EOM
		ssh-dss AAAAB3NzaC1kc3MAAACBAMfem4jte5ZNQQSey7D4X79Qkdiez+Y5vDHGsViqax8qAzMzPsDKGAAPkHhGsxjVpkNFU7XW+34GuXdNGnMUBfWfsx0nyF5t/sJagwpfOLRWPeqgblPnkRNKoeodVfrYZpo2o/4QVwGElZa9FE8XIPp7djMD2JrcBqYsSjjwJPNfAAAAFQCB49PxkuhSa5vickeUNdpNtVPpNQAAAIA7URcvIH0FlGSTqcQd9SjPIYFySHh4GcgSRbrmA8xhDoT/NAcBJN6EQuvsSPSxCJ++r2qd0qB1usVgzYurEraGaJXtLjd48ygYBit3x0qz7NULf+XjXb16He2ZrLBuiRgXcfumC+tA02sKosQV2PnOPLZ8tjgeqeHyiy3XnmgKrgAAAIBPBQuWS9S8xnS0fIX+CJmQGnekPU10bOsyyT1CO0xY1lyf7TmXTI0PpU0oF4v4JT/m+FAx0/+6sc78Rlv17SyFDm/xI5Rj6vFOCTRriNI0g+ZLjjqIf0KksTTEo4F0NPO7sOvHABvTXp/9L8qb7kCy6qVGRWDImA1H2upqhWJ+4A== paulc@Ians-iMac.local
		ssh-dss AAAAB3NzaC1kc3MAAACBAJXBJs2SIP6QSw4SDs7mU+Czr+Ikr8UzbDR4/pf26B+hzrSQemnVrBx5XBniJ5aC4LwLG3plZprXe20B2sqb6PASDCMNtB8xBHtDTBR0vXNw/cb1r+1D1kS3/17Cy6KP8qVW1p045Dj3DqNVuS5Mab/CCNWHO5BtgQTPKn69YQaVAAAAFQCNXkXpImK/eHsL6JcHaUX+LRVccQAAAIANuzRtPfpekZegn5kb34fL1rWRvh0QNASEqpAqgxOhn1/G2TBXi3na5QoEGke/bzfybDaCoA0YBqly6ah2R0mczhvn7jqZUeH7UVu48y8kjNeVbfLrT9BVprreii16vb5+za+5XTVWoGv2VTh4/egVjkwb2X7ZSkBw4eAtvQCStgAAAIBLpRM3hcZL0M41PF9vkA5en28oKEkHHwie0cWAepH8pLmsdLhwKdoCx3sXTSD7eMf7CQ+8f6M5ZLbTtIGFiMNPG9nbM4IY/zntZiMOM4BNXr3BTKTVUm2eDSIicZWwL2Lefuz3nWWGtP0pSkYBQvxcA0EwS+SCfq6ABLPxbn87LQ== paulc@Dogwood-Minor.local
	EOM
	_print /root/.ssh/authorized_keys
}

remove_ovh_setup() {
	rm -f /root/.ssh/authorized_keys2
	rmuser -vy ovh
	rm -rf /usr/local/rtm/
	pkg_delete -f \*
	ex -s /etc/crontab <<-'EOM'
		/rtm/d
		wq
	EOM
}

setup_zfs() {
	mount | grep -q /dev/ada0s1d && umount -f /dev/ada0s1d
	service zfs onestart
	zpool create -f pool ada0s1d
	printf -- '--- ZPOOL\n'
	zpool list
}

setup_ezjail() {
	pkg_add -r ezjail
	cat > /usr/local/etc/ezjail.conf <<-EOM
		ezjail_use_zfs="YES"
		ezjail_use_zfs_for_jails="YES"
		ezjail_jailzfs="pool/jail"
	EOM
	mkdir /usr/jails
	/usr/local/bin/ezjail-admin install -r "9.1-RELEASE"
	/usr/local/bin/ezjail-admin update -u
}

rollback() {
	for f in $(find /etc -name \*ovh)
	do
		printf '%s -> %s\n' $f ${f%%.ovh}
		cp $f ${f%%.ovh}
	done
	exit
}

_auto() {
	_log remove_ovh_setup
	_log update_system
	_log update_fstab
	_log update_resolv_conf
	_log set_localtime
	_log update_sysctl_conf
	_log update_crontab
	_log update_rc_conf
	_log create_pf_conf
	_log update_sshd_config
	_log add_ssh_keys
	_log setup_zfs
	_log setup_ezjail
}

#### MAIN

[ -t 1 ] && _COLOUR=1

_config _HOSTNAME    "Hostname"             $(hostname)
_config _EXT_IF      "External Interface"   $(_get_ext_if)
_config _IPV4        "IPv4 Address"         $(_get_ipv4)
_config _IPV4_MASK   "IPv4 Netmask"         $(_get_ipv4_mask)
_config _IPV4_GW     "IPv4 Default Gateway" $(_get_ipv4_gw)
_config _IPV6        "IPv6 Address"         $(_get_ipv6)
_config _IPV6_PREFIX "IPv6 Prefix Length"   $(_get_ipv6_prefix)
_config _IPV6_GW     "IPv6 Default Gateway" $(_get_ipv6_gw)

cat <<EOM

Updating System: $_HOSTNAME

External Interface:  $_EXT_IF
IP Address:          $_IPV4 netmask $_IPV4_MASK 
IP Gateway:          $_IPV4_GW
IPv6 Address:        $_IPV6 prefixlen $_IPV6_PREFIX
IPv6 Gateway:        $_IPV6_GW

EOM

read -p "Continue [y/N]: " _yn

if [ "${_yn}" = "y" -o "${_yn}" = "Y" ]
then
	case "$1" in
		-i|--interactive|"") 
			_interactive
			exit
		;;
		-a|--auto)
			_auto
			exit
		;;
		*) 
			eval _log $1	
		;;
	esac
fi

