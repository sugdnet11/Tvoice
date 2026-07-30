#!/bin/sh
set -u

/usr/sbin/asterisk -rx 'pjsip show aor 77770'
echo TVOICE_AOR_DATABASE
mysql -NBe "SELECT keyword, data FROM asterisk.sip WHERE id = '77770' AND (keyword LIKE 'qualify%' OR keyword IN ('max_contacts', 'remove_existing', 'rewrite_contact', 'rtp_symmetric', 'force_rport', 'expiration')) ORDER BY keyword"
echo TVOICE_RECENT_77770_LOG
grep '77770' /var/log/asterisk/full 2>/dev/null | tail -n 60 || true
