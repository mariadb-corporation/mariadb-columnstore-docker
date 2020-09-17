#!/bin/bash

#set -x
echo "WARNING: THIS IS AN EARLY VERSION OF THIS SCRIPT IT IS FOR DEVELOPMENT PURPOSES ONLY"

# Parse command line arguments
if [ $# -ge 2 ]; then
    BACKUP_BUCKET=$1
    BACKUP_PREFIX=$2_$(date +%F_%H%M%S)
    SKYSQL_BACKUP_KEY=$2
else
    echo $0 BACKUP_BUCKET BACKUP_PREFIX
    exit 1
fi

# Check that we are using S3 storage
if [ ${USE_S3_STORAGE} -eq 1 ]; then
    # Set up the correct service account for gsutil
    gcloud auth activate-service-account --key-file /mnt/backup-secrets/backup_admin_account.json
else
    echo "ERROR: This backup program currently only supports S3 bucket backend storage, not local disk storage."
    exit 2
fi

echo "Using backup bucket: $BACKUP_BUCKET"
gsutil ls -L -b $BACKUP_BUCKET
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access backup bucket"
    exit 3
fi

# Get source bucket, metadata directory and journal directory information
SOURCE_BUCKET=$(awk '/^bucket =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^bucket = /gs:\/\//")
if [ -z $SOURCE_BUCKET ]; then
    echo "ERROR: Couldn't extract source bucket from /etc/columnstore/storagemanager.cnf"
    exit 4
fi
echo "Using source bucket: $SOURCE_BUCKET"
gsutil ls -L -b $SOURCE_BUCKET
if [ $? -ne 0 ]; then
    echo "ERROR: Couldn't access source bucket"
    exit 4
fi

METADATA_PATH=$(awk '/^metadata_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^metadata_path = //")
if [ ! -z $METADATA_PATH ] && [ ! -d $METADATA_PATH ]; then
    echo "ERROR: ColumnStore's metadata directory $METADATA_PATH couldn't be found."
    exit 5
fi

JOURNAL_PATH=$(awk '/^journal_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^journal_path = //")
if [ ! -z $JOURNAL_PATH ] && [ ! -d $JOURNAL_PATH ]; then
    echo "ERROR: ColumnStore's journal directory $JOURNAL_PATH couldn't be found."
    exit 6
fi

# Get the MariaDB version information
if [ -z ${MARIADB_VERSION} ]; then
    echo 'ERROR: Was not able to determine the MariaDB Version from the ${MARIADB_VERSION} variable'
    exit 7
else
    echo ${MARIADB_VERSION} > /tmp/MARIADB_VERSION
fi

# Check that there is only one ColumnStore backup process running
if [ -f /tmp/backup-running ]; then
    echo "ERROR: There is already a backup program running."
    exit 8
fi
touch /tmp/backup-running

echo "$(date) backup started"

# Put ColumnStore into read only mode.
RESPONSE=$(columnstoreDBWrite -c suspend)
# Check if ColumnStore was able to be put in read only mode. It can't currently be put into read only mode if there are pending write queries.
# If ColumnStore can't be put into read only mode terminate the backup program and try again with the next CronJob execution. (We might be more lucky then)
if [ $? -ne 0 ] || [[ ! $(echo $RESPONSE | grep "locked:") == "" ]]; then
    echo "ERROR: ColumnStore couldn't be put into read only mode, due to active writes to the system."
    echo $RESPONSE
    rm /tmp/backup-running
    exit 9
fi
echo $RESPONSE
# Wait 30 seconds to flush the S3 cache.
sleep 30

# Verify that ColumnStore's "journal" directory is empty (all data has been flushed to S3).
if [ -z "$(ls -A $JOURNAL_PATH/data1)" ]; then
    echo "INFO: ColumnStore's journal directory is empty"
else
    echo "ERROR: ColumnStore's journal directory is not empty"
    columnstoreDBWrite -c resume
    rm /tmp/backup-running
    exit 10
fi

# Perform the ColumnStore data backup
## Copy MariaDB's version information to the S3 backup bucket
gsutil cp /tmp/MARIADB_VERSION $BACKUP_BUCKET/$BACKUP_PREFIX/MARIADB_VERSION

## Copy ColumnStore's "metadata" and "etc" directory to the S3 backup bucket.
gsutil -m cp -r $METADATA_PATH/* $BACKUP_BUCKET/$BACKUP_PREFIX/metadata/
gsutil -m cp -r /etc/columnstore/* $BACKUP_BUCKET/$BACKUP_PREFIX/etc/

## Backup all data from the source S3 bucket.
gsutil -m cp -r $SOURCE_BUCKET/* $BACKUP_BUCKET/$BACKUP_PREFIX/s3data/

## Put ColumnStore into read/write mode again
columnstoreDBWrite -c resume

# Perform the innodb data backup using skysql-backup
skysql-backup backup --bucket=$BACKUP_BUCKET --key=$SKYSQL_BACKUP_KEY

# Remove the backup lock file
rm -f /tmp/backup-running

echo "$(date) backup completed"