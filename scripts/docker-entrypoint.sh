#!/bin/bash

function exitColumnStore {
    mariadb-admin shutdown
    mcs-stop
}

# Clean Remnants
rm -f /var/run/syslogd.pid
rm -f /var/lib/mysql/*.pid

# Start rsyslog
rsyslogd

trap exitColumnStore SIGTERM

exec "$@" &

wait
