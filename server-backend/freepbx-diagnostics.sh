#!/bin/sh
set -u

echo TVOICE_SECTION_VERSION
/usr/sbin/asterisk -rx 'core show version'
echo TVOICE_SECTION_ENDPOINT
/usr/sbin/asterisk -rx 'pjsip show endpoint 77770'
echo TVOICE_SECTION_CONTACTS
/usr/sbin/asterisk -rx 'pjsip show contacts'
echo TVOICE_SECTION_DIALPLAN
/usr/sbin/asterisk -rx 'dialplan show 77770@from-internal'
echo TVOICE_SECTION_SERVICES
systemctl is-active asterisk || true
command -v fwconsole || true
echo TVOICE_SECTION_DATABASES
mysql -NBe 'SHOW DATABASES' 2>&1
echo TVOICE_SECTION_EXTENSION
mysql -NBe "SELECT extension, name FROM asterisk.users WHERE extension = '77770'" 2>&1
echo TVOICE_SECTION_PJSIP_AUTH_SCHEMA
mysql -NBe 'SHOW COLUMNS FROM asterisk.ps_auths' 2>&1
echo TVOICE_SECTION_PJSIP_AUTH_RECORD
mysql -NBe "SELECT id, auth_type, username, IF(password IS NULL OR password = '', 'missing', 'present') FROM asterisk.ps_auths WHERE id = '77770' OR username = '77770'" 2>&1
echo TVOICE_SECTION_PJSIP_AOR_RECORD
mysql -NBe "SELECT id, max_contacts, remove_existing FROM asterisk.ps_aors WHERE id = '77770'" 2>&1
echo TVOICE_SECTION_PJSIP_ENDPOINT_RECORD
mysql -NBe "SELECT id, transport, aors, auth, context, disallow, allow FROM asterisk.ps_endpoints WHERE id = '77770'" 2>&1
echo TVOICE_SECTION_SIP_TABLES
mysql -NBe "SHOW TABLES FROM asterisk LIKE '%sip%'" 2>&1
echo TVOICE_SECTION_SIP_SCHEMA
mysql -NBe 'SHOW COLUMNS FROM asterisk.sip' 2>&1
echo TVOICE_SECTION_SIP_RECORD_SAFE
mysql -NBe "SELECT keyword, CASE WHEN keyword IN ('secret', 'password') THEN IF(data IS NULL OR data = '', 'missing', 'present') ELSE data END FROM asterisk.sip WHERE id = '77770' AND keyword IN ('secret', 'password', 'auth', 'aors', 'context', 'allow', 'callerid', 'transport') ORDER BY keyword" 2>&1
echo TVOICE_SECTION_ACCOUNT_COUNTS
mysql -NBe "SELECT COUNT(*) FROM asterisk.users; SELECT COUNT(DISTINCT id) FROM asterisk.sip WHERE keyword = 'secret' AND data <> ''" 2>&1
echo TVOICE_SECTION_RECENT_CALLS
mysql -NBe "SELECT calldate, src, dst, disposition, duration, billsec, lastapp FROM asteriskcdrdb.cdr WHERE dst = '77770' ORDER BY calldate DESC LIMIT 10" 2>&1
echo TVOICE_SECTION_WEB
command -v php || true
php -v 2>/dev/null | head -n 2 || true
php -m 2>/dev/null | grep -E 'PDO|mysqli|mysql' || true
ls -ld /var/www/html /etc/freepbx.conf 2>&1 || true
ss -ltn | head -n 30
echo TVOICE_SECTION_FWCONSOLE
ls -l /var/lib/asterisk/bin/fwconsole 2>&1 || true
