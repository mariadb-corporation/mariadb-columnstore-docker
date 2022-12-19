#!/bin/bash

function exitColumnStore {
    monit unmonitor all
    mariadb-admin shutdown
    mcs-stop
    monit quit
}

# Clean Remnants
rm -f /var/run/syslogd.pid
rm -f /var/run/monit.pid
rm -f /var/lib/mysql/*.pid

# Start rsyslog
rsyslogd

trap exitColumnStore SIGTERM

exec "$@" &

wait
