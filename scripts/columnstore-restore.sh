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

echo "$(date) restore started"

# Record the current skysql_admin user's credentials
SKYSQL_ADMIN_USER_HASH=$(mysql -NBe "select password from mysql.user where user='skysql_admin' and host='localhost';");
SKYSQL_ADMIN_USER_HASH=${SKYSQL_ADMIN_USER_HASH:0:41}

# Stop the ColumnStore daemon to start the restore process
monit unmonitor all
columnstore-stop

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
mariabackup --prepare --target-dir=/var/lib/mysql

# Set the correct permissions to the data dir
chown -R mysql:mysql /var/lib/mysql

# Restore the correct credentials for the cross engine join user in Columnstore.xml
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/etc/Columnstore.xml /tmp/Columnstore.xml
mcsSetConfig CrossEngineSupport Password "$(mcsGetConfig -c /tmp/Columnstore.xml CrossEngineSupport Password)"

# Restore the correct S3 object_size in storagemanager.cnf
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/etc/storagemanager.cnf /tmp/storagemanager.cnf
BACKUP_OBJECT_SIZE=$(awk '/^object_size = /' /tmp/storagemanager.cnf)
CURRENT_OBJECT_SIZE=$(awk '/^object_size = /' /etc/columnstore/storagemanager.cnf)
sed -i "s@$CURRENT_OBJECT_SIZE@$BACKUP_OBJECT_SIZE@g" /etc/columnstore/storagemanager.cnf

# Start ColumnStore
columnstore-start
columnstoreDBWrite -c resume

# Restore the old skysql_admin user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_admin_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_ADMIN_USER_HASH>>\";") FROM mysql.user WHERE user="skysql_admin"' >> /tmp/restore_skysql_admin_credentials.sql
echo "set global strict_password_validation=1;" >> /tmp/restore_skysql_admin_credentials.sql
sed -i "s@<<SKYSQL_ADMIN_USER_HASH>>@${SKYSQL_ADMIN_USER_HASH}@g" /tmp/restore_skysql_admin_credentials.sql
mariadb < /tmp/restore_skysql_admin_credentials.sql
rm -f /tmp/restore_skysql_admin_credentials.sql

# Restore completed
echo "$(date) restore completed"
echo "Please restart the container"
