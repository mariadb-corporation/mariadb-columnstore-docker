#!/usr/bin/bash

function exitColumnStore {
  monit unmonitor all
  cmapi-stop
  monit quit
}

rm -f /var/run/syslogd.pid
rsyslogd

trap exitColumnStore SIGTERM

exec "$@" &

wait
