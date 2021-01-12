#!/bin/bash

#set -x

# Parse command line arguments
if [ $# -ge 3 ]; then
    BACKUP_BUCKET=$1
    BACKUP_PREFIX=$2
    SKYSQL_BACKUP_KEY=$3
else
    echo $0 BACKUP_BUCKET BACKUP_PREFIX SKYSQL_BACKUP_KEY
    exit 1
fi

# Check that we are using S3 storage
if [ ${USE_S3_STORAGE} -eq 1 ]; then
    # Set up the correct service account for gsutil
    gcloud auth activate-service-account --key-file /mnt/backup-secrets/backup_admin_account.json
else
    echo "ERROR: This restore program currently only supports S3 bucket backend storage, not local disk storage."
    exit 2
fi

echo "Using backup bucket: $BACKUP_BUCKET"
gsutil ls -L -b $BACKUP_BUCKET
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access backup bucket"
    exit 3
fi

# Check that the backups to restore exist in the backup bucket
echo "Checking for object $SKYSQL_BACKUP_KEY in backup bucket."
gsutil stat $BACKUP_BUCKET/$SKYSQL_BACKUP_KEY
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access backed up innodb data."
    exit 4
fi

echo "Checking for folder $BACKUP_PREFIX in backup bucket."
gsutil ls $BACKUP_BUCKET/$BACKUP_PREFIX
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access backed up columnstore data."
    exit 5
fi

# Get source bucket, metadata directory, cache directory, and journal directory information
SOURCE_BUCKET=$(awk '/^bucket =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^bucket = /gs:\/\//")
if [ -z $SOURCE_BUCKET ]; then
    echo "ERROR: Couldn't extract source bucket from /etc/columnstore/storagemanager.cnf"
    exit 6
fi
echo "Using source bucket: $SOURCE_BUCKET"
gsutil ls -L -b $SOURCE_BUCKET
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access source bucket"
    exit 6
fi

METADATA_PATH=$(awk '/^metadata_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^metadata_path = //")
if [ ! -z $METADATA_PATH ] && [ ! -d $METADATA_PATH ]; then
    echo "ERROR: ColumnStore's metadata directory $METADATA_PATH couldn't be found."
    exit 7
fi

JOURNAL_PATH=$(awk '/^journal_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^journal_path = //")
if [ ! -z $JOURNAL_PATH ] && [ ! -d $JOURNAL_PATH ]; then
    echo "ERROR: ColumnStore's journal directory $JOURNAL_PATH couldn't be found."
    exit 8
fi

CACHE_PATH=$(sed -n -e '/\[Cache\]/,/path =/ p' /etc/columnstore/storagemanager.cnf | awk '/^path =/' | sed -e "s/^path = //")
if [ ! -z $CACHE_PATH ] && [ ! -d $CACHE_PATH ]; then
    echo "ERROR: ColumnStore's cache directory $CACHE_PATH couldn't be found."
    exit 9
fi

# Get the cmapi key
if [ -z ${CMAPI_KEY} ]; then
    CMAPI_KEY=$(cat /etc/columnstore/cmapi_server.conf | grep 'x-api-key' | grep -oP "(?<=').*?(?=')")
    if [ $? -ne 0 ] || [ -z ${CMAPI_KEY} ]; then
        echo "ERROR: Wasn't able to extract the cmapi key"
        exit 10
    fi
fi

curl -s https://${HOSTNAME}:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" -k | jq . > /tmp/columnstore-status.json
NODE_DNS="\"$(cat /tmp/columnstore-status.json | grep -o -e $HOSTNAME.*..local)\""
NODE_DBRM_MODE_PATH=".$NODE_DNS.dbrm_mode"
NODE_CLUSTER_MODE_PATH=".$NODE_DNS.cluster_mode"
NODE_DBRM_MODE=$(cat /tmp/columnstore-status.json | jq  $NODE_DBRM_MODE_PATH)
NODE_CLUSTER_MODE=$(cat /tmp/columnstore-status.json | jq  $NODE_CLUSTER_MODE_PATH)
if [[ -z $NODE_DBRM_MODE || -z $NODE_CLUSTER_MODE ]]; then
    echo "Error: Can not determine dbrm_mode or cluster_mode"
    exit 11
fi
if [[ $NODE_DBRM_MODE == "\"master\"" && $NODE_CLUSTER_MODE  == "\"readwrite\"" ]]
then
    echo "This is the master node in readwrite mode, execution continues"
else
    echo "This is slave node in readonly mode, execution stopped"
    rm -f /tmp/columnstore-status.json
    exit 12
fi
rm -f /tmp/columnstore-status.json

# Get the MariaDB version information of the current system
if [ -z ${MARIADB_VERSION} ]; then
    echo 'ERROR: Was not able to determine the MariaDB version of the current system from the ${MARIADB_VERSION} variable'
    exit 13
fi
# Get the MariaDB Version information of the backup
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/MARIADB_VERSION /tmp/BACKUP_MARIADB_VERSION 1>/dev/null 2>/dev/null
BACKUP_MARIADB_VERSION=$(cat /tmp/BACKUP_MARIADB_VERSION)
if [ $? -ne 0 ] || [ -z ${BACKUP_MARIADB_VERSION} ]; then
    echo "Warning: Wasn't able to get the MariaDB version of the backup."
    echo "Will assume version 10.4"
    BACKUP_MARIADB_VERSION="10.4"
fi

# Compare the MariaDB versions and determine if a MariaDB upgrade should be attempted
ATTEMPT_MARIADB_UPGRADE=0
if [[ ! "${BACKUP_MARIADB_VERSION}" == "${MARIADB_VERSION}" ]]; then
  echo "Warning: MariaDB versions of the current system and the backup don't match"
  if (( $(echo "${BACKUP_MARIADB_VERSION} > ${MARIADB_VERSION}" |bc -l) )); then
    echo "Error: The MariaDB version of the backup (${BACKUP_MARIADB_VERSION}) is greater than the version of the current system (${MARIADB_VERSION})"
    exit 14
  else
    echo "The MariaDB version of the backup (${BACKUP_MARIADB_VERSION}) is lower than the version of the current system (${MARIADB_VERSION})."
    echo "A MariaDB upgrade will be attempted"
	ATTEMPT_MARIADB_UPGRADE=1
  fi
fi

echo "$(date) restore started"

# Record the current skysql_admin user's credentials
SKYSQL_ADMIN_USER_HASH=$(mysql -NBe "select password from mysql.user where user='skysql_admin' and host='localhost';");
SKYSQL_ADMIN_USER_HASH=${SKYSQL_ADMIN_USER_HASH:0:41}
SKYSQL_MAXSCALE_USER_HASH=$(mariadb -NBe "select password from mysql.user where user='skysql_maxscale' and host='10.%';");
SKYSQL_MAXSCALE_USER_HASH=${SKYSQL_MAXSCALE_USER_HASH:0:41}
SKYSQL_REPLICATION_USER_HASH=$(mariadb -NBe "select password from mysql.user where user='skysql_replication' and host='10.%';");
SKYSQL_REPLICATION_USER_HASH=${SKYSQL_REPLICATION_USER_HASH:0:41}

# Stop the ColumnStore daemon to start the restore process
monit unmonitor all
curl -s -X PUT https://${HOSTNAME}:8640/cmapi/0.4.0/cluster/shutdown --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" --data '{"timeout":60}' -k | jq .
sleep 30
cmapi-stop
sleep 15

# Purge the source S3 bucket so that the backup data can be restored into it
gsutil -m rm $SOURCE_BUCKET/*

# Restore the backed up S3 objects to the source bucket
gsutil -m cp $BACKUP_BUCKET/$BACKUP_PREFIX/s3data/* $SOURCE_BUCKET

# Purge the local journal, cache and metadata directories
rm -rf $JOURNAL_PATH/data1/*
rm -rf $CACHE_PATH/data1/*
rm -rf $METADATA_PATH/*

# Restore the backed up S3 metadata from the backup bucket
gsutil -m cp -r $BACKUP_BUCKET/$BACKUP_PREFIX/metadata/* $METADATA_PATH/

# Purge innodb's data dir
find /var/lib/mysql -mindepth 1 -delete

# Run the restore sub-command with the new bucket and key name against innodb's empty data dir
skysql-backup restore --datadir=/var/lib/mysql/ --bucket=$BACKUP_BUCKET --key=$SKYSQL_BACKUP_KEY

# Prepare the backup as you would a traditional backup
if [ $ATTEMPT_MARIADB_UPGRADE -eq 1 ]; then
    echo "INFO: Preparing the MariaDB backup using the 10.4 version of Maria-Backup"
    mariabackup-10.4 --prepare --target-dir=/var/lib/mysql
else
    mariabackup --prepare --target-dir=/var/lib/mysql
fi

# Set the correct permissions to the data dir
chown -R mysql:mysql /var/lib/mysql

# Restore the correct credentials for the cross engine join user in Columnstore.xml
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/etc/Columnstore.xml /tmp/Columnstore.xml
mcsSetConfig CrossEngineSupport Password "$(mcsGetConfig -c /tmp/Columnstore.xml CrossEngineSupport Password)"

# Restore the correct S3 object_size in storagemanager.cnf
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/etc/storagemanager.cnf /tmp/storagemanager.cnf
# Make a check if it`s 10.4 or 10.5, because the spacing is different
if [ $ATTEMPT_MARIADB_UPGRADE -eq 1 ]; then
  BACKUP_OBJECT_SIZE=$(awk '/^object_size=/' /tmp/storagemanager.cnf | sed -r 's/^(object_size)(=)(.*)$/\1 \2 \3/')
else
  BACKUP_OBJECT_SIZE=$(awk '/^object_size = /' /tmp/storagemanager.cnf)
fi
CURRENT_OBJECT_SIZE=$(awk '/^object_size = /' /etc/columnstore/storagemanager.cnf)
sed -i "s@$CURRENT_OBJECT_SIZE@$BACKUP_OBJECT_SIZE@g" /etc/columnstore/storagemanager.cnf

# Start ColumnStore
export SKYSQL_INITIALIZATION=0
cmapi-start
sleep 10
curl -s -X PUT https://localhost:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" --data '{"timeout":60}' -k | jq .
curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" -k | jq .
columnstoreDBWrite -c resume
export SKYSQL_INITIALIZATION=1

# Attempt a MariaDB upgrade if needed
if [ $ATTEMPT_MARIADB_UPGRADE -eq 1 ]; then
    mariadb-upgrade
    if [ $? -ne 0 ]; then
        echo "ERROR: mariadb-upgrade exited with exit code unequal 0"
        exit 15
    fi
fi

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

# Reactivate monit
monit monitor all

# Show all processes
ps -aux

# Restore completed
echo "$(date) restore completed"
echo "Please restart the container"
exit 0
