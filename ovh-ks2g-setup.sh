
_NORMAL=$(echo -e "\e[0m")
_RED=$(echo -e "\e[0;31m")
_CYAN=$(echo -e "\e[0;36m")

trap 'rm -f /tmp/err.* /tmp/out.*' EXIT

_c() {
	_cmd="$@"
	printf "%s [%s] %-40s\n" "$(date '+%b %d %T')" $name "CMD: $_cmd"
	eval "$_cmd" 2>&1 | sed -e 's/^/     | /'
	_status=$?
	printf "     "
	[ $_status -eq 0 ] && printf "[OK]\n" || printf "[ERROR]\n"
	return $_status
}

_cc() {
	_cmd="$@"
	_out=$(mktemp -t out)
	_err=$(mktemp -t err)
	printf "${_RED}"
	printf "%s [%s] %-40s\n" "$(date '+%b %d %T')" $name "CMD: $_cmd"
	printf "${_NORMAL}"
	eval "$_cmd" >${_out} 2>${_err}
	_status=$?
	printf "${_CYAN}"
	sed -e 's/^/     | /' <${_out}
	printf "${_YELLOW}"
	sed -e 's/^/     ! /' <${_err}
	printf "${_RED}     "
	[ $_status -eq 0 ] && printf "[OK]\n" || printf "[ERROR]\n"
	printf "${_NORMAL}"
	rm -f ${_out} ${_err}
	return $_status
}

update_system() {
	(freebsd-update fetch && freebsd-update install) | cat 
}

update_fstab() {
	cp /etc/fstab /etc/fstab.ovh
	cat > /etc/fstab <<-'EOM'
		# Device                Mountpoint      FStype  Options         Dump    Pass#
		/dev/ada0s1a            /               ufs             rw      1       1
		/dev/ada0s1b.eli        none            swap            sw      0       0
		tmpfs                   /tmp            tmpfs           rw,noexec,mode=777,size=1073741824 0 0
		proc                    /proc           procfs          rw      0       0
		#/dev/ada0s1d           /pool           ufs             rw      2       2
	EOM
}

update_sysctl_conf() {
	cp /etc/sysctl.conf /etc/sysctl.conf.ovh
	ex -s /etc/sysctl.conf <<-'EOM'
		/net.inet6.ip6.accept_rtadv/d
		a
		net.inet6.ip6.accept_rtadv=1
		.
		wq
	EOM
}

update_resolv_conf() {
	cp /etc/resolv.conf /etc/resolv.conf.ovh
	cat > /etc/resolv.conf <<-'EOM'
		nameserver 8.8.8.8
		nameserver 8.8.4.4
		nameserver 2001:4860:4860::8888
		nameserver 2001:4860:4860::8844
	EOM
}

update_rc_conf() {
	cp /etc/rc.conf /etc/rc.conf.ovh
	# Yank network parameters from old rc.conf & generate new conf
	ex -s /etc/rc.conf.ovh <<-'EOM'
		/^ifconfig_em0/y a
		/^defaultrouter/y b
		/^ifconfig_em0_ipv6/y c
		/^ipv6_defaultrouter/y d
		/^hostname/y e
		ex /etc/rc.conf
		1,$d
		a
		# System
		fsck_y_enable="YES"
		dumpdev="AUTO"
		cloned_interfaces="lo1"

		# IPv4
		.
		put a
		put b
		a

		# IPv6
		.
		put c
		/^ifconfig_em0_ipv6/s/prefixlen 128/prefixlen 64 accept_rtadv/
		put d
		put e
		a
		# Services
		ntpdate_enable="YES"
		ntpdate_hosts="213.186.33.99"
		syslogd_flags="-s -b 127.0.0.1"
		sshd_enable="YES"
		gateway_enable="YES"
		pf_enable="YES"
		pflog_enable="YES"
		ezjail_enable="YES"
		.
		wq
	EOM
	# Create start script to assign lo1 network aliases
	cat > /etc/start_if.lo1 <<-'EOM'
		#!/bin/sh
		for i in $(jot -w 10.0.1. 24)
		do
			ifconfig lo1 inet $i/32 alias
		done
	EOM
	chmod 755 /etc/start_if.lo1
	# Create PF ruleset
	#  Enable NAT on lo1 (for jails) and block all other services except ssh
	#  Include anchors to dynamically load rdr/filter rules
	cat > /etc/pf.conf <<-'EOM'

		ext_if = "{ em0 }"
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
}

update_crontab() {
	cp /etc/crontab /etc/crontab.ovh
	ex -s /etc/crontab <<-'EOM'
		$
		a
		# Run ntpd -q hourly (rather than as daemon)
		0	*	*	*	*	root	/usr/sbin/ntpd -gq >/dev/null
		.
		wq
	EOM
}

update_sshd_config() {
	_IP=$1
	_IPV6=$2
	cp /etc/ssh/sshd_config /etc/ssh/sshd_config.ovh
	cat > /etc/ssh/sshd_config <<-EOM
		Port 22
		ListenAddress ${_IP}
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
}

add_ssh_keys() {
	cat > /root/.ssh/authorized_keys <<-EOM
		ssh-dss AAAAB3NzaC1kc3MAAACBAMfem4jte5ZNQQSey7D4X79Qkdiez+Y5vDHGsViqax8qAzMzPsDKGAAPkHhGsxjVpkNFU7XW+34GuXdNGnMUBfWfsx0nyF5t/sJagwpfOLRWPeqgblPnkRNKoeodVfrYZpo2o/4QVwGElZa9FE8XIPp7djMD2JrcBqYsSjjwJPNfAAAAFQCB49PxkuhSa5vickeUNdpNtVPpNQAAAIA7URcvIH0FlGSTqcQd9SjPIYFySHh4GcgSRbrmA8xhDoT/NAcBJN6EQuvsSPSxCJ++r2qd0qB1usVgzYurEraGaJXtLjd48ygYBit3x0qz7NULf+XjXb16He2ZrLBuiRgXcfumC+tA02sKosQV2PnOPLZ8tjgeqeHyiy3XnmgKrgAAAIBPBQuWS9S8xnS0fIX+CJmQGnekPU10bOsyyT1CO0xY1lyf7TmXTI0PpU0oF4v4JT/m+FAx0/+6sc78Rlv17SyFDm/xI5Rj6vFOCTRriNI0g+ZLjjqIf0KksTTEo4F0NPO7sOvHABvTXp/9L8qb7kCy6qVGRWDImA1H2upqhWJ+4A== paulc@Ians-iMac.local
	EOM
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

setup_ezjail() {
	pkg_add -r ezjail
}

##### Main

_EXT_IF=$(route -n get default | awk '/interface:/ { print $2 }')
_IP=$(ifconfig $_EXT_IF | awk '/inet[^6]/ { print $2; exit }')
_IPV6=$(ifconfig $_EXT_IF | awk '/inet6/ { if ( substr($2,0,4) != "fe80" ) { print $2; exit } }')

cat <<-EOM

    Updating System: $(hostname)

    External Interface:  $_EXT_IF
    IP Address:          $_IP
    IPV6 Address:        $_IPV6
	
EOM

if [ -t 1 ]
then
	_c update_system
	_cc update_fstab
	_cc update_resolv_conf
	_cc update_sysctl_conf
	_cc update_crontab
	_cc update_rc_conf
	_cc update_sshd_config $_IP $_IPV6
	_cc remove_ovh_setup
	_cc add_ssh_keys
	_cc setup_ezjail
else
	_c update_system
	_c update_fstab
	_c update_resolv_conf
	_c update_sysctl_conf
	_c update_crontab
	_c update_rc_conf
	_c update_sshd_config $_IP $_IPV6
	_c remove_ovh_setup
	_c add_ssh_keys
	_c setup_ezjail
fi
