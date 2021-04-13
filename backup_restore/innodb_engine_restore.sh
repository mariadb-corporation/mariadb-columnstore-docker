#!/bin/bash

set -x

# Parse command line arguments
if [ $# -ge 2 ]; then
    BACKUP_BUCKET=$1
    BACKUP_PREFIX=$2
    SKYSQL_BACKUP_KEY=$3
else
    echo $0 BACKUP_BUCKET BACKUP_PREFIX SKYSQL_BACKUP_KEY
    exit 1
fi

# Check that we are using S3 storage
if [ ${USE_S3_STORAGE} -eq 1 ] || [ ${USE_S3_STORAGE} = true ]; then
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

# Get the MariaDB version information of the current system
if [ -z ${MARIADB_VERSION} ]; then
    echo 'ERROR: Was not able to determine the MariaDB version of the current system from the ${MARIADB_VERSION} variable'
    exit 6
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
    exit 7
  else
    echo "The MariaDB version of the backup (${BACKUP_MARIADB_VERSION}) is lower than the version of the current system (${MARIADB_VERSION})."
    echo "A MariaDB upgrade will be attempted"
    ATTEMPT_MARIADB_UPGRADE=1
  fi
fi

echo "$(date) innodb restore started"

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

echo "$(date) innodb restore finished"