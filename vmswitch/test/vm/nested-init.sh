#!/bin/bash
# /init of the nested lab guests (vmswitch KVM e2e): one NIC with the address from
# vsw.ip= (and vsw.gw=), pings every vsw.ping= target until it answers (60 s), and
# reports its USB devices every 2 s on the serial console. Lab only.
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs dev /dev
arg() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^vsw\.$1=//p"; }
for m in virtio_net xhci_pci usbhid; do modprobe "$m" 2> /dev/null; done
sleep 1
ip link set lo up
ip link set eth0 up
ip addr add "$(arg ip)" dev eth0
[[ -n $(arg gw) ]] && ip route add default via "$(arg gw)"
echo "VSW-READY $(arg ip)"
declare -A done
for ((t = 0; t < 30; t++)); do
    for p in $(arg ping | tr , ' '); do
        [[ -n ${done[$p]} ]] && continue
        if ping -c 1 -W 1 "$p" > /dev/null 2>&1; then echo "VSW-PING-OK $p"; done[$p]=1; fi
    done
    echo "VSW-USB $(cat /sys/bus/usb/devices/*/idVendor 2> /dev/null | paste -sd, -)/$(cat /sys/bus/usb/devices/*/idProduct 2> /dev/null | paste -sd, -)"
    sleep 2
done
echo "VSW-PINGS-DONE"
while :; do
    echo "VSW-USB $(cat /sys/bus/usb/devices/*/idVendor 2> /dev/null | paste -sd, -)/$(cat /sys/bus/usb/devices/*/idProduct 2> /dev/null | paste -sd, -)"
    sleep 2
done
