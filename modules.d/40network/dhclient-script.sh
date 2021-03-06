#!/bin/sh
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

setup_interface() {
    ip=$new_ip_address
    mtu=$new_interface_mtu
    mask=$new_subnet_mask
    bcast=$new_broadcast_address
    gw=${new_routers%%,*}
    domain=$new_domain_name
    search=$(printf -- "$new_domain_search")
    namesrv=$new_domain_name_servers
    hostname=$new_host_name

    [ -f /tmp/net.$netif.override ] && . /tmp/net.$netif.override

    # Taken from debian dhclient-script:
    # The 576 MTU is only used for X.25 and dialup connections
    # where the admin wants low latency.  Such a low MTU can cause
    # problems with UDP traffic, among other things.  As such,
    # disallow MTUs from 576 and below by default, so that broken
    # MTUs are ignored, but higher stuff is allowed (1492, 1500, etc).
    if [ -n "$mtu" ] && [ $mtu -gt 576 ] ; then
        if ! ip link set $netif mtu $mtu ; then
            ip link set $netif down
            ip link set $netif mtu $mtu
            linkup $netif
        fi
    fi

    ip addr add $ip${mask:+/$mask} ${bcast:+broadcast $bcast} dev $netif

    [ -n "$gw" ] && echo ip route add default via $gw dev $netif > /tmp/net.$netif.gw

    [ -n "${search}${domain}" ] && echo "search $search $domain" > /tmp/net.$netif.resolv.conf
    if  [ -n "$namesrv" ] ; then
        for s in $namesrv; do
            echo nameserver $s
        done
    fi >> /tmp/net.$netif.resolv.conf

    # Note: hostname can be fqdn OR short hostname, so chop off any
    # trailing domain name and explicity add any domain if set.
    [ -n "$hostname" ] && echo "echo ${hostname%.$domain}${domain+.$domain} > /proc/sys/kernel/hostname" > /tmp/net.$netif.hostname
}

PATH=/usr/sbin:/usr/bin:/sbin:/bin

export PS4="dhclient.$interface.$$ + "
exec >>/run/initramfs/loginit.pipe 2>>/run/initramfs/loginit.pipe
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
type ip_to_var >/dev/null 2>&1 || . /lib/net-lib.sh

# We already need a set netif here
netif=$interface

# Huh? Interface configured?
[ -f "/tmp/net.$netif.up" ] && exit 0

case $reason in
    PREINIT)
        echo "dhcp: PREINIT $netif up"
        linkup $netif
        ;;
    BOUND)
        echo "dhcp: BOND setting $netif"
        unset layer2
        if [ -f /sys/class/net/$netif/device/layer2 ]; then
            read layer2 < /sys/class/net/$netif/device/layer2
        fi
        if [ "$layer2" != "0" ]; then
            if ! arping -q -D -c 2 -I $netif $new_ip_address ; then
                warn "Duplicate address detected for $new_ip_address while doing dhcp. retrying"
                exit 1
            fi
        fi
        unset layer2
        setup_interface
        set | while read line; do
            [ "${line#new_}" = "$line" ] && continue
            echo "$line"
        done >/tmp/dhclient.$netif.dhcpopts

        {
            echo '. /lib/net-lib.sh'
            echo "setup_net $netif"
            echo "source_hook initqueue/online $netif"
            [ -e /tmp/net.$netif.manualup ] || echo "/sbin/netroot $netif"
            echo "> /tmp/setup_net_$netif.ok"
            echo "> /tmp/setup_net_\$(cat /sys/class/net/$netif/address).ok"
            echo "rm -f -- $hookdir/initqueue/setup_net_$netif.sh"
        } > $hookdir/initqueue/setup_net_$netif.sh

        echo "[ -f /tmp/setup_net_$netif.ok ]" > $hookdir/initqueue/finished/dhclient-$netif.sh
        >/tmp/net.$netif.up
        ;;
    *) echo "dhcp: $reason";;
esac

exit 0
