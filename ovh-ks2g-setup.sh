
_NORMAL=$(echo -e "\e[0m")
_RED=$(echo -e "\e[0;31m")
_CYAN=$(echo -e "\e[0;36m")

_c() {
  _cmd="$@"
  printf "${_RED}"
  printf "%s [%s] %-40s\n" "$(date '+%b %d %T')" $name "CMD: $_cmd"
  printf "${_CYAN}"
  eval "$_cmd" | sed -e 's/^/     | /'
  _err=$?
  printf "${_RED}     "
  [ $_err -eq 0 ] && printf "[OK]\n" || printf "[ERROR]\n"
  printf "${_NORMAL}"
  return $_err 
}

update_system() {
	(freebsd-update fetch && freebsd-update install) | cat 
}

update_fstab() {
	cp /etc/fstab /etc/fstab.ovh
	cat > /etc/fstab <<-EOM
		# Device                Mountpoint      FStype  Options         Dump    Pass#
		/dev/ada0s1a            /               ufs             rw      1       1
		/dev/ada0s1b.eli        none            swap            sw      0       0
		tmpfs                   /tmp            tmpfs           rw,noexec,mode=777,size=1073741824 0 0
		proc                    /proc           procfs          rw      0       0
		#/dev/ada0s1d            /tank           ufs             rw      2       2
	EOM
}

update_sysctl_conf() {
	cp /etc/sysctl.conf /etc/sysctl.conf.ovh
	ex -s /etc/sysctl.conf <<-EOM
		/net.inet6.ip6.accept_rtadv/d
		a
		net.inet6.ip6.accept_rtadv=1
		.
		wq
	EOM
}

update_resolv_conf() {
	cp /etc/resolv.conf /etc/resolv.conf.ovh
	cat > /etc/resolv.conf <<-EOM
		nameserver 8.8.8.8
		nameserver 8.8.4.4
		nameserver 2001:4860:4860::8888
		nameserver 2001:4860:4860::8844
	EOM

}

update_rcconf_conf() {
	_HOSTNAME=$1
	cp /etc/rc.conf /etc/rc.conf.ovh
	ex -s /etc/rc.conf <<-EOM
		/^ntpdate_enable/d
		/^ntpdate_hosts/d
		/^ipv6_enable/d
		/^ipv6_network_interfaces/d
		/^ipv6_static_routes/d
		/^ipv6_route_ovhgw/d
		/^ifconfig_em0_ipv6/s/prefixlen 128/prefixlen 64 accept_rtadv/
		$
		a

		# Local setup

		ntpd_enable="YES"
		syslogd_flags="-s -b 127.0.0.1"
		gateway_enable="YES"
		pf_enable="YES"
		pflog_enable="YES"
		ezjail_enable="YES"
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
		ListenAddress $_IP
		ListenAddress 127.0.0.1
		ListenAddress $_IPV6
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
	while read -p 'SSH Public Key (root access): ' k
	do
		[ ${#k} -eq 0 ] && break
		echo $k >> /root/.ssh/authorized_keys
	done
}

remove_ovh_setup() {
	rm -f /root/.ssh/authorized_keys2
	rmuser -vy ovh
	rm -rf /usr/local/rtm/
	pkg_delete -f \*
	ex -s /etc/crontab <<-EOM
		/rtm/d
		wq
	EOM
}

setup_ezjail() {
	pkg_add -r ezjail
}

# Main

_EXT_IF=$(route -n get default | awk '/interface:/ { print $2 }')
_IP=$(ifconfig $_EXT_IF | awk '/inet[^6]/ { print $2; exit }')
_IPV6=$(ifconfig $_EXT_IF | awk '/inet6/ { if ( substr($2,0,4) != "fe80" ) { print $2; exit } }')

cat <<-EOM

    Updating System: $(hostname)

    External Interface:  $_EXT_IF
    IP Address:          $_IP
    IPV6 Address:        $_IPV6
	
EOM

read -p "Continue [y/n]: " yn

case "$yn" in
	[yY])
		_c update_system
		_c update_fstab
		_c update_resolv_conf
		_c update_sysctl_conf
		_c update_rcconf_conf $_HOSTNAME
		_c update_sshd_config $_IP $_IPV6
		_c remove_ovh_setup
		_c add_ssh_keys
		_c setup_ezjail
	;;
esac

