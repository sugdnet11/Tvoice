#!/bin/sh
set -eu

ensure_nat_rule() {
    if ! iptables -t nat -C "$@" 2>/dev/null; then
        iptables -t nat -A "$@"
    fi
}

ensure_forward_rule() {
    if ! iptables -C "$@" 2>/dev/null; then
        iptables -A "$@"
    fi
}

sysctl -q -w net.ipv4.ip_forward=1

# FreePBX web administration on a dedicated TLS port. SIP 5060 and the RTP
# range are managed separately by the existing PBX rules.
ensure_nat_rule PREROUTING -i vmbr0 -p tcp --dport 8445 -j DNAT --to-destination 10.10.10.2:443
ensure_forward_rule FORWARD -i vmbr0 -o vmbr1 -d 10.10.10.2 -p tcp --dport 443 -j ACCEPT

# Administrative SSH access to the chat and current LiveKit VMs.
ensure_nat_rule PREROUTING -i vmbr0 -p tcp --dport 2226 -j DNAT --to-destination 10.10.10.6:22
ensure_nat_rule PREROUTING -i vmbr0 -p tcp --dport 2228 -j DNAT --to-destination 10.10.10.8:22

# LiveKit WebRTC media goes directly to the current LiveKit VM. Relaying ICE
# through the chat VM breaks the return path and leaves calls without media.
ensure_nat_rule PREROUTING -i vmbr0 -p tcp --dport 8091 -j DNAT --to-destination 10.10.10.8:8091
ensure_nat_rule PREROUTING -i vmbr0 -p udp --dport 443 -j DNAT --to-destination 10.10.10.8:443

ensure_forward_rule FORWARD -i vmbr0 -o vmbr1 -d 10.10.10.6 -p tcp -m multiport --dports 22,80,443 -j ACCEPT
ensure_forward_rule FORWARD -i vmbr0 -o vmbr1 -d 10.10.10.8 -p tcp -m multiport --dports 22,7880,8091 -j ACCEPT
ensure_forward_rule FORWARD -i vmbr0 -o vmbr1 -d 10.10.10.8 -p udp --dport 443 -j ACCEPT
ensure_forward_rule FORWARD -i vmbr1 -o vmbr0 -s 10.10.10.6 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure_forward_rule FORWARD -i vmbr1 -o vmbr0 -s 10.10.10.8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
