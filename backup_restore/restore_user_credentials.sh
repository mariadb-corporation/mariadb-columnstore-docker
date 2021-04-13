#!/bin/bash

# Get the password hashes from NFS
SKYSQL_ADMIN_USER_HASH=$(cat /var/lib/columnstore/storagemanager/restore/SKYSQL_ADMIN_USER_HASH)
SKYSQL_REPLICATION_USER_HASH=$(cat /var/lib/columnstore/storagemanager/restore/SKYSQL_REPLICATION_USER_HASH)
SKYSQL_MAXSCALE_USER_HASH=$(cat /var/lib/columnstore/storagemanager/restore/SKYSQL_MAXSCALE_USER_HASH)

# Restore the old skysql_admin user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_admin_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_ADMIN_USER_HASH>>\";") FROM mysql.user WHERE user="skysql_admin"' >> /tmp/restore_skysql_admin_credentials.sql
echo "set global strict_password_validation=1;" >> /tmp/restore_skysql_admin_credentials.sql
sed -i "s@<<SKYSQL_ADMIN_USER_HASH>>@${SKYSQL_ADMIN_USER_HASH}@g" /tmp/restore_skysql_admin_credentials.sql
mariadb < /tmp/restore_skysql_admin_credentials.sql
rm -f /tmp/restore_skysql_admin_credentials.sql

# restore original skysql_replication user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_replication_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_REPLICATION_USER_HASH>>\";") FROM mysql.user WHERE user="skysql_replication"' >> /tmp/restore_skysql_replication_credentials.sql
echo "set global strict_password_validation=1;" >> /tmp/restore_skysql_replication_credentials.sql
sed -i "s@<<SKYSQL_REPLICATION_USER_HASH>>@${SKYSQL_REPLICATION_USER_HASH}@g" /tmp/restore_skysql_replication_credentials.sql
mariadb < /tmp/restore_skysql_replication_credentials.sql
rm -f /tmp/restore_skysql_replication_credentials.sql

# restore original skysql_maxscale user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_maxscale_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_MAXSCALE_USER_HASH>>\";") FROM mysql.user WHERE user="skysql_maxscale"' >> /tmp/restore_skysql_maxscale_credentials.sql
echo "set global strict_password_validation=1;" >> /tmp/restore_skysql_maxscale_credentials.sql
sed -i "s@<<SKYSQL_MAXSCALE_USER_HASH>>@${SKYSQL_MAXSCALE_USER_HASH}@g" /tmp/restore_skysql_maxscale_credentials.sql
mariadb < /tmp/restore_skysql_maxscale_credentials.sql
rm -f /tmp/restore_skysql_maxscale_credentials.sql