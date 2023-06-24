#!/bin/bash

function exitColumnStore {
    /etc/init.d/mariadb stop
    mcs-stop
}

# Clean Remnants
rm -f /var/run/syslogd.pid /var/lib/mysql/*.pid

# Fix Permissions If Necessary
chown -R mysql:mysql /var/lib/mysql /var/log/mariadb

# Start rsyslog
rsyslogd

trap exitColumnStore SIGTERM

exec "$@" &

wait
