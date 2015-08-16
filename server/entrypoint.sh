#!/bin/sh
#
#  Copyright (C) 2015 Michael Richard <michael.richard@oriaks.com>
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#set -x

export DEBIAN_FRONTEND='noninteractive'
export TERM='linux'

_install () {
  [ -f /usr/sbin/slapd ] && return

  apt-get update -q
  apt-get install -y ca-certificates ldap-utils ldapvi pwgen schema2ldif slapd slapd-smbk5pwd ssl-cert vim-tiny

  usermod -aG ssl-cert openldap

  rm -rf /etc/ldap/slapd.d/cn=config/olcDatabase={1}mdb.ldif
  rm -rf /var/lib/ldap/*

  sed -ri -f- /etc/ldap/ldap.conf <<-EOF
	s|^[#]*(BASE[[:space:]]+).*|\1cn=config|;
	s|^[#]*(URI[[:space:]]+).*|\1ldapi:///|;
	s|^[#]*(TLS_REQCERT[[:space:]]+).*|\1never|;
EOF

  grep -q '^TLS_REQCERT' /etc/ldap/ldap.conf || cat >> /etc/ldap/ldap.conf <<- EOF
	TLS_REQCERT	never
EOF

  install -o root -g root -m 640 /dev/null /root/.ldaprc
  cat > /root/.ldaprc <<- EOF
	SASL_MECH EXTERNAL
	URI ldapi:///
EOF

  install -o root -g root -m 640 /dev/null /root/.ldapvirc
  cat > /root/.ldapvirc <<- EOF
	profile default
	host: ldapi:///
	sasl-mech: EXTERNAL
EOF

  /usr/sbin/slapd -h 'ldapi:///' -g openldap -u openldap -F /etc/ldap/slapd.d

  ldapmodify -cQ <<- EOF
	dn: cn=config
	changetype: modify
	add: olcLocalSSF
	olcLocalSSF: 128
	-
	add: olcRequires
	olcRequires: LDAPv3
	-
	add: olcSecurity
	olcSecurity: simple_bind=128 ssf=128 tls=0 update_ssf=128
	-
	add: olcTLSCertificateFile
	olcTLSCertificateFile: /etc/ssl/certs/ssl-cert-snakeoil.pem
	-
	add: olcTLSCertificateKeyFile
	olcTLSCertificateKeyFile: /etc/ssl/private/ssl-cert-snakeoil.key
	-
	add: olcTLSVerifyClient
	olcTLSVerifyClient: never
EOF

  ldapmodify -cQ <<- EOF
	dn: cn=module{0},cn=config
	changetype: modify
	add: olcModuleLoad
	olcModuleLoad: smbk5pwd

	dn: olcDatabase={-1}frontend,cn=config
	changetype: modify
	add: olcPasswordHash
	olcPasswordHash: {K5KEY}
EOF

  ldapadd -cQ -f /etc/ldap/schema/misc.ldif

  apt-get install -y heimdal-kdc
  schema2ldif /etc/ldap/schema/hdb.schema > /etc/ldap/schema/hdb.ldif
  ldapadd -cQ -f /etc/ldap/schema/hdb.ldif
  apt-get purge -y --auto-remove heimdal-kdc

  apt-get install -y samba-doc
  zcat /usr/share/doc/samba-doc/examples/LDAP/samba.schema.gz > /etc/ldap/schema/samba.schema
  sed -ri -f- /etc/ldap/schema/samba.schema <<-EOF
	/sambaSamAccount/,/^$/ {
	  s|MUST \( uid \\$ sambaSID \)|MUST ( uid )|;
	  s|cn |cn $ sambaSID |;
	}
EOF
  schema2ldif /etc/ldap/schema/samba.schema > /etc/ldap/schema/samba.ldif
  ldapadd -cQ -f /etc/ldap/schema/samba.ldif
  apt-get purge -y --auto-remove samba-doc

  apt-get install -y wget
  wget -O /etc/ldap/schema/sipidentity.schema --no-check-certificate https://openvoipmanager.googlecode.com/svn-history/r36/trunk/OpenVoipManagerService/schema/sipIdentity.schema
  schema2ldif /etc/ldap/schema/sipidentity.schema > /etc/ldap/schema/sipidentity.ldif
  ldapadd -cQ -f /etc/ldap/schema/sipidentity.ldif
  apt-get purge -y --auto-remove wget

  mv /etc/ldap/slapd.d /etc/ldap/slapd.d.orig
  ln -sf /var/lib/ldap/slapd.d /etc/ldap/slapd.d

  return 0
}

_init () {
  [ -d /var/lib/ldap ] || install -o openldap -g openldap -m 750 -d /var/lib/ldap
  [ -d /var/lib/ldap/slapd.d ] || cp -Rp /etc/ldap/slapd.d.orig /var/lib/ldap/slapd.d

  exec /usr/sbin/slapd -d0 -h 'ldapi:/// ldaps:/// ldap:///' -g openldap -u openldap -F /etc/ldap/slapd.d

  return 0
}

_manage () {
  _CMD="$1"
  [ -n "${_CMD}" ] && shift

  case "${_CMD}" in
    "db")
      _manage_db $*
      ;;
    *)
      _usage
      ;;
  esac

  return 0
}

_manage_db () {
  _CMD="$1"
  [ -n "${_CMD}" ] && shift

  case "${_CMD}" in
    "config")
      _manage_db_config $*
      ;;
    "create")
      _manage_db_create $*
      ;;
    "edit")
      _manage_db_edit $*
      ;;
    *)
      _usage
      ;;
  esac

  return 0
}

_manage_db_create () {
  _DB="$1"
  [ -z "${_DB}" ] && return 1 || shift
  echo "${_DB}" | grep -q '=' || _DB=`echo "${_DB}" | sed 's|^|dc=|;s|\.|,dc=|g;'`
  [ `ldapsearch -LLL -x -s base -b '' namingContexts | awk -F ':' '/^namingContexts: / {print $2}' | sed -r 's|[[:space:]]*||g' | grep -c "^${_DB}"` -ge 1 ] && return 1

  _USER="$1"
  [ -z "${_USER}" ] && _USER="cn=admin,${_DB}" || shift
  echo "${_USER}" | grep -q '=' || _USER="cn=${_USER},${_DB}"

  _PASSWORD="$1"
  [ -z "${_PASSWORD}" ] && _PASSWORD=`pwgen 12 1` || shift

  install -o openldap -g openldap -m 750 -d "/var/lib/ldap/${_DB}"

  ldapmodify -cQ <<- EOF
	dn: olcDatabase=mdb,cn=config
	changetype: add
	objectClass: olcDatabaseConfig
	objectClass: olcMdbConfig
	olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by dn.exact=${_DB} manage by users read by anonymous auth by * none
	olcDbCheckpoint: 512 30
	olcDatabase: mdb
	olcDbDirectory: /var/lib/ldap/${_DB}
	olcDbIndex: entryCSN,entryUUID eq
	olcDbIndex: objectClass eq
	olcDbIndex: cn,sn,mail eq,pres,sub
	olcDbIndex: uid eq
	olcDbIndex: uidNumber,gidNumber eq
	olcDbIndex: member,memberUid eq
	olcDbMaxSize: 1073741824
	olcLastMod: TRUE
	olcRootDN: ${_USER}
	olcRootPW: `slappasswd -h {SSHA} -s "${_PASSWORD}"`
	olcSuffix: ${_DB}

	dn: ${_DB}
	changetype: add
	objectClass: top
	objectClass: dcObject
	objectClass: organization
	o: ${_DB}
EOF

	_CONFIGDN=`ldapsearch -QLLL -b cn=config "(olcSuffix=${_DB})" dn | sed 's|^dn: ||'`

  ldapmodify -cQ <<- EOF
	dn: olcOverlay={0}smbk5pwd,${_CONFIGDN}
	changetype: add
	objectClass: olcOverlayConfig
	objectClass: olcSmbK5PwdConfig
	olcOverlay: {0}smbk5pwd
	olcSmbK5PwdEnable: krb5
	olcSmbK5PwdEnable: samba
	olcSmbK5PwdMustChange: 0
	olcSmbK5PwdCanChange: 0
EOF

  echo "db: ${_DB}, user: ${_USER}, password: ${_PASSWORD}"

  return 0
}

_manage_db_config () {
  _DB="$1"
  [ -z "${_DB}" ] && return 1 || shift
  [ `ldapsearch -LLL -x -s base -b '' namingContexts | awk -F ':' '/^namingContexts: / {print $2}' | sed -r 's|[[:space:]]*||g' | grep -c "^${_DB}"` -ge 1 ] || return 1

  _CONFIGDN=`ldapsearch -QLLL -b cn=config "(olcSuffix=${_DB})" dn | sed 's|^dn: ||'`

  ldapvi -b "${_CONFIGDN}"

  return 0
}

_manage_db_edit () {
  _DB="$1"
  [ -z "${_DB}" ] && return 1 || shift
  [ `ldapsearch -LLL -x -s base -b '' namingContexts | awk -F ':' '/^namingContexts: / {print $2}' | sed -r 's|[[:space:]]*||g' | grep -c "^${_DB}"` -ge 1 ] || return 1

  ldapvi -b "${_DB}"

  return 0
}

_shell () {
  exec /bin/bash

  return 0
}

_post_init () {
  sleep 15

#  mongo --quiet --ssl localhost/admin <<- EOF
  mongo --quiet localhost/admin <<- EOF
	db.addUser( { user: "root", pwd: "${MONGO_PASSWORD}", roles: [ "clusterAdmin", "dbAdminAnyDatabase", "readWriteAnyDatabase", "userAdminAnyDatabase" ] } )
EOF

  return 0
}

_usage () {
  cat <<- EOF
	Usage: $0 install
	       $0 init
	       $0 manage db create <database_name> [ <user_name> [ <password> ]]
	       $0 manage db config <database_name>
	       $0 manage db edit <database_name>
	       $0 shell
EOF

  return 0
}

_CMD="$1"
[ -n "${_CMD}" ] && shift

case "${_CMD}" in
  "install")
    _install $*
    ;;
  "init")
    _init $*
    ;;
  "manage")
    _manage $*
    ;;
  "shell")
    _shell $*
    ;;
  *)
    _usage
    ;;
esac
