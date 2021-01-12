#!/bin/bash

#set -x

# Parse command line arguments
if [ $# -ge 2 ]; then
    BACKUP_BUCKET=$1
    BACKUP_PREFIX=$2_$(date +%F_%H%M%S)
    SKYSQL_BACKUP_KEY=$2
    if [ $# -ge 3 ]; then
        if [[ $3 == "--columnstore" ]]; then
            BACKUP_COLUMNSTORE_TABLES="true"
        fi
    fi
else
    echo "$0 BACKUP_BUCKET BACKUP_PREFIX [--columnstore]"
    echo "If --columnstore is set, all ColumnStore tables will be backed up as well."
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

# Get all the information to connect to the MaxScale API.
PARSED_RELEASE_VAR_NAME=$(echo $RELEASE_NAME | tr '[:lower:],\-' '[:upper:],\_')
MAXSCALE_API_HOST_VAR_NAME=$(echo ${PARSED_RELEASE_VAR_NAME}_MARIADB_MAXSCALE_SERVICE_HOST)
MAXSCALE_API_PORT_VAR_NAME=$(echo ${PARSED_RELEASE_VAR_NAME}_MARIADB_MAXSCALE_SERVICE_PORT)
MAXSCALE_API_HOST=$(printf '%s\n' "${!MAXSCALE_API_HOST_VAR_NAME}")
MAXSCALE_API_PORT=$(printf '%s\n' "${!MAXSCALE_API_PORT_VAR_NAME}")
MAXSCALE_API_USER=$(cat /mnt/skysql/columnstore-container-configuration/maxscale-api-username)
MAXSCALE_API_PASS=$(cat /mnt/skysql/columnstore-container-configuration/maxscale-api-password)
curl -X GET -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/maxscale -fail
if [ $? -ne 0 ]; then
    echo "ERROR: Wasn't able to connect to MaxScale"
    exit 4
fi

if [[ $BACKUP_COLUMNSTORE_TABLES == "true" ]]; then
    # Get source bucket, metadata directory and journal directory information
    SOURCE_BUCKET=$(awk '/^bucket =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^bucket = /gs:\/\//")
    if [ -z $SOURCE_BUCKET ]; then
        echo "ERROR: Couldn't extract source bucket from /etc/columnstore/storagemanager.cnf"
        exit 5
    fi
    echo "Using source bucket: $SOURCE_BUCKET"
    gsutil ls -L -b $SOURCE_BUCKET
    if [ $? -ne 0 ]; then
        echo "ERROR: Couldn't access source bucket"
        exit 5
    fi

    METADATA_PATH=$(awk '/^metadata_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^metadata_path = //")
    if [ ! -z $METADATA_PATH ] && [ ! -d $METADATA_PATH ]; then
        echo "ERROR: ColumnStore's metadata directory $METADATA_PATH couldn't be found."
        exit 6
    fi

    JOURNAL_PATH=$(awk '/^journal_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^journal_path = //")
    if [ ! -z $JOURNAL_PATH ] && [ ! -d $JOURNAL_PATH ]; then
        echo "ERROR: ColumnStore's journal directory $JOURNAL_PATH couldn't be found."
        exit 7
    fi
fi

# Check that there is only one HTAP backup process running
if [ -d /tmp/backup ]; then
    echo "ERROR: There is already a backup program running."
    exit 8
fi

mkdir /tmp/backup
echo "$(date) backup started"

# Remove the set_htap_replication UDF for the time of a backup
mariadb -e 'DROP FUNCTION set_htap_replication;'

# ColumnStore table backup
if [[ $BACKUP_COLUMNSTORE_TABLES == "true" ]]; then
    # Put ColumnStore into read only mode.
    RESPONSE=$(columnstoreDBWrite -c suspend)
    # Check if ColumnStore was able to be put in read only mode. It can't currently be put into read only mode if there are pending write queries.
    # If ColumnStore can't be put into read only mode terminate the backup program and try again with the next CronJob execution. (We might be more lucky then)
    if [ $? -ne 0 ] || [[ ! $(echo $RESPONSE | grep "locked:") == "" ]]; then
        echo "ERROR: ColumnStore couldn't be put into read only mode, due to active writes to the system."
        echo $RESPONSE
        mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
        rm -rf /tmp/backup
        exit 9
    fi
    echo $RESPONSE
    
    # Stop the replication slave
    mariadb -e 'STOP SLAVE;'

    # Wait 30 seconds to flush the S3 cache.
    sleep 30

    # Verify that ColumnStore's "journal" directory is empty (all data has been flushed to S3).
    if [ -z "$(ls -A $JOURNAL_PATH/data1)" ]; then
        echo "INFO: ColumnStore's journal directory is empty"
    else
        echo "ERROR: ColumnStore's journal directory is not empty"
        columnstoreDBWrite -c resume
        mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
        mariadb -e 'START SLAVE;'
        rm -rf /tmp/backup
        exit 10
    fi

    # Perform the ColumnStore data backup
    ## Copy ColumnStore's "metadata" and "etc" directory to the S3 backup bucket.
    gsutil -m cp -r $METADATA_PATH/* $BACKUP_BUCKET/$BACKUP_PREFIX/metadata/
    if [ $? -ne 0 ]; then
        echo "ERROR: ColumnStore's metadata directory couldn't be copied"
        columnstoreDBWrite -c resume
        mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
        mariadb -e 'START SLAVE;'
        rm -rf /tmp/backup
        exit 11
    fi
    gsutil -m cp -r /etc/columnstore/* $BACKUP_BUCKET/$BACKUP_PREFIX/etc/
    if [ $? -ne 0 ]; then
        echo "ERROR: ColumnStore's /etc/columnstore directory couldn't be copied"
        columnstoreDBWrite -c resume
        mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
        mariadb -e 'START SLAVE;'
        rm -rf /tmp/backup
        exit 12
    fi

    ## Backup all data from the source S3 bucket.
    gsutil -m cp -r $SOURCE_BUCKET/* $BACKUP_BUCKET/$BACKUP_PREFIX/s3data/
    if [ $? -ne 0 ]; then
        echo "ERROR: ColumnStore's data directory couldn't be copied"
        columnstoreDBWrite -c resume
        mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
        mariadb -e 'START SLAVE;'
        rm -rf /tmp/backup
        exit 13
    fi

    ## Put ColumnStore into read/write mode again
    columnstoreDBWrite -c resume

    ## Start the replication slave
    mariadb -e 'START SLAVE;'
fi

# Perform the MaxScale replication configuration backup
curl -X GET -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/filters/replication_filter -o /tmp/backup/replication_filter.json
if [ $? -ne 0 ]; then
    echo "ERROR: Wasn't able to get replication configuration from MaxScale."
    mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
    rm -rf /tmp/backup
    exit 14
fi

# Get the MariaDB version information
if [ -z ${MARIADB_VERSION} ]; then
    echo 'ERROR: Was not able to determine the MariaDB Version from the ${MARIADB_VERSION} variable'
    exit 15
else
    echo ${MARIADB_VERSION} > /tmp/backup/MARIADB_VERSION
fi

# Backup all the configurations to the S3 bucket
cp /etc/columnstore/Columnstore.xml /tmp/backup/Columnstore.xml
gsutil -m cp /tmp/backup/* $BACKUP_BUCKET/$BACKUP_PREFIX/
if [ $? -ne 0 ]; then
    echo "ERROR: Wasn't able to upload the replication configuration to the S3 bucket"
    mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
    rm -rf /tmp/backup
    exit 16
fi

# Prepare the extra options in ~/.my.cnf for mariabackup that is executed by skysql-backup
echo "[mariabackup]" > ~/.my.cnf
echo "safe-slave-backup" >> ~/.my.cnf

# Perform the innodb data backup using skysql-backup
skysql-backup backup --bucket=$BACKUP_BUCKET --key=$SKYSQL_BACKUP_KEY
if [ $? -ne 0 ]; then
    echo "ERROR: Wasn't able to backup the innodb data using skysql-backup"
    rm -f ~/.my.cnf
    mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
    rm -rf /tmp/backup
    exit 16
fi

# Remove the backup lock file and recreate the set_htap_replication UDF
rm -f ~/.my.cnf
mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
rm -rf /tmp/backup

echo "$(date) backup completed"