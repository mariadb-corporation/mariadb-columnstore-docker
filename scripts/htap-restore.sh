#!/bin/bash

#set -x
echo "WARNING: THIS IS AN EARLY VERSION OF THIS SCRIPT IT IS FOR DEVELOPMENT PURPOSES ONLY"

function stopColumnStore(){
    echo "Stopping all ColumnStore processes on this node as well as the ColumnStore cluster"
    monit unmonitor all
    curl -s -X PUT https://localhost:8640/cmapi/0.4.0/cluster/shutdown --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" --data '{"timeout":60}' -k | jq .
    /usr/bin/cmapi-stop
}

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
if [ ${USE_S3_STORAGE} = true ]; then
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
    echo "ERROR: Couldn't access backed up ColumnStore data."
    exit 5
fi

# Check if we need to restore backed up ColumnStore tables as well
gsutil ls $BACKUP_BUCKET/$BACKUP_PREFIX/etc > /dev/null 2>/dev/null
if [ $? -eq 0 ]; then
    RESTORE_COLUMNSTORE_TABLES="true"

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
    if [ -z $METADATA_PATH ] || [ ! -d $METADATA_PATH ]; then
        echo "ERROR: ColumnStore's metadata directory $METADATA_PATH couldn't be found."
        exit 7
    fi

    JOURNAL_PATH=$(awk '/^journal_path =/' /etc/columnstore/storagemanager.cnf | sed -e "s/^journal_path = //")
    if [ -z $JOURNAL_PATH ] || [ ! -d $JOURNAL_PATH ]; then
        echo "ERROR: ColumnStore's journal directory $JOURNAL_PATH couldn't be found."
        exit 8
    fi

    CACHE_PATH=$(sed -n -e '/\[Cache\]/,/path =/ p' /etc/columnstore/storagemanager.cnf | awk '/^path =/' | sed -e "s/^path = //")
    if [ -z $CACHE_PATH ] || [ ! -d $CACHE_PATH ]; then
        echo "ERROR: ColumnStore's cache directory $CACHE_PATH couldn't be found."
        exit 9
    fi
fi

# Get the MariaDB version information of the current system
if [ -z ${MARIADB_VERSION} ]; then
    echo 'ERROR: Was not able to determine the MariaDB version of the current system from the ${MARIADB_VERSION} variable'
    exit 10
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
    exit 11
  else
    echo "The MariaDB version of the backup (${BACKUP_MARIADB_VERSION}) is lower than the version of the current system (${MARIADB_VERSION})."
    echo "A MariaDB upgrade will be attempted"
	ATTEMPT_MARIADB_UPGRADE=1
  fi
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
    exit 12
fi

# Get the cmapi key
if [ -z ${CMAPI_KEY} ]; then
    CMAPI_KEY=$(cat /etc/columnstore/cmapi_server.conf | grep 'x-api-key' | grep -oP "(?<=').*?(?=')")
    if [ $? -ne 0 ] || [ -z ${CMAPI_KEY} ]; then
        echo "ERROR: Wasn't able to extract the cmapi key"
        exit 13
    fi
fi

echo "$(date) restore started"

# Record the current skysql_admin user's credentials
SKYSQL_ADMIN_USER_HASH=$(mariadb -NBe "select password from mysql.user where user='skysql_admin' and host='localhost';");
SKYSQL_ADMIN_USER_HASH=${SKYSQL_ADMIN_USER_HASH:0:41}
SKYSQL_MAXSCALE_USER_HASH=$(mariadb -NBe "select password from mysql.user where user='skysql_maxscale' and host='%';");
SKYSQL_MAXSCALE_USER_HASH=${SKYSQL_MAXSCALE_USER_HASH:0:41}
SKYSQL_REPLICATION_USER_HASH=$(mariadb -NBe "select password from mysql.user where user='idbrep' and host='%';");
SKYSQL_REPLICATION_USER_HASH=${SKYSQL_REPLICATION_USER_HASH:0:41}

# Stop the ColumnStore daemon to start the restore process
stopColumnStore

if [[ $RESTORE_COLUMNSTORE_TABLES == 'true' ]]; then
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
fi

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

# Connect to MaxScale and restore the replication configuration from the S3 backup bucket.
## Remove all filters from the Replication-Service
curl -X PATCH -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/services/Replication-Service/relationships/filters -d  '{ "data": [] }'

## Remove the replication_filter
curl -X DELETE -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/filters/replication_filter

## Restore the replication filter
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/replication_filter.json /tmp/replication_filter.json
cat <<EOF > /tmp/get_new_replication_filter_json_data.py
#!/usr/bin/python2
import json
with open('/tmp/replication_filter.json') as backup_file:
    backup_data = json.load(backup_file)
    filter_data = {
        "data": {
            "id": "replication_filter",
            "type": "filters",
            "attributes": backup_data["data"]["attributes"]
        }
    }
    print(json.dumps(filter_data))
EOF
chmod +x /tmp/get_new_replication_filter_json_data.py
REPLICATION_FILTER_JSON_DATA=$(/tmp/get_new_replication_filter_json_data.py)
curl -X POST -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/filters -d "${REPLICATION_FILTER_JSON_DATA}"

## Assign the restored replication_filter to the Replication-Service
curl -X PATCH -u ${MAXSCALE_API_USER}:${MAXSCALE_API_PASS} ${MAXSCALE_API_HOST}:${MAXSCALE_API_PORT}/v1/services/Replication-Service/relationships/filters -d  '{ "data": [ { "id": "replication_filter", "type": "filters" } ] }'

# Restore the correct credentials for the cross engine join user in Columnstore.xml
gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/Columnstore.xml /tmp/Columnstore.xml
mcsSetConfig CrossEngineSupport Password "$(mcsGetConfig -c /tmp/Columnstore.xml CrossEngineSupport Password)"

if [[ $RESTORE_COLUMNSTORE_TABLES == 'true' ]]; then
    # Restore the correct S3 object_size in storagemanager.cnf
    gsutil cp $BACKUP_BUCKET/$BACKUP_PREFIX/etc/storagemanager.cnf /tmp/storagemanager.cnf
    BACKUP_OBJECT_SIZE=$(awk '/^object_size = /' /tmp/storagemanager.cnf)
    CURRENT_OBJECT_SIZE=$(awk '/^object_size = /' /etc/columnstore/storagemanager.cnf)
    sed -i "s@$CURRENT_OBJECT_SIZE@$BACKUP_OBJECT_SIZE@g" /etc/columnstore/storagemanager.cnf
fi

# Start ColumnStore
cmapi-start
curl -s -X PUT https://localhost:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" --data '{"timeout":60}' -k | jq .
curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:${CMAPI_KEY}" -k | jq .
columnstoreDBWrite -c resume

# Attempt a MariaDB upgrade if needed
if [ $ATTEMPT_MARIADB_UPGRADE -eq 1 ]; then
    mariadb-upgrade
    if [ $? -ne 0 ]; then
        echo "ERROR: mariadb-upgrade exited with exit code unequal 0"
        exit 14
    fi
fi

# Restore the old skysql_admin user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_admin_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_ADMIN_USER_HASH>>\";") FROM mysql.user WHERE user="skysql_admin"' >> /tmp/restore_skysql_admin_credentials.sql
echo "set global strict_password_validation=1;" >> /tmp/restore_skysql_admin_credentials.sql
sed -i "s@<<SKYSQL_ADMIN_USER_HASH>>@${SKYSQL_ADMIN_USER_HASH}@g" /tmp/restore_skysql_admin_credentials.sql
mariadb < /tmp/restore_skysql_admin_credentials.sql
rm -f /tmp/restore_skysql_admin_credentials.sql

# Extract the replication match regular expression, the destination schema and source schema
cat <<EOF > /tmp/get_replication_filter_match.py
#!/usr/bin/python2
import json
with open('/tmp/replication_filter.json') as backup_file:
    backup_data = json.load(backup_file)
    print(backup_data["data"]["attributes"]["parameters"]["match"].encode('utf8'))
EOF
chmod +x /tmp/get_replication_filter_match.py
# Notice: We loose one escape sign here. Doesn't seem to have an effect though.
REPLICATION_FILTER_MATCH=$(/tmp/get_replication_filter_match.py)

cat <<EOF > /tmp/get_replication_filter_destination_schema.py
#!/usr/bin/python2
import json
with open('/tmp/replication_filter.json') as backup_file:
    backup_data = json.load(backup_file)
    print(backup_data["data"]["attributes"]["parameters"]["rewrite_dest"].encode('utf8'))
EOF
chmod +x /tmp/get_replication_filter_destination_schema.py
REPLICATION_FILTER_DESTINATION_SCHEMA=$(/tmp/get_replication_filter_destination_schema.py)

cat <<EOF > /tmp/get_replication_filter_source_schema.py
#!/usr/bin/python2
import json
with open('/tmp/replication_filter.json') as backup_file:
    backup_data = json.load(backup_file)
    print(backup_data["data"]["attributes"]["parameters"]["rewrite_src"].encode('utf8'))
EOF
chmod +x /tmp/get_replication_filter_source_schema.py
REPLICATION_FILTER_SOURCE_SCHEMA=$(/tmp/get_replication_filter_source_schema.py)

if [[ ${REPLICATION_FILTER_MATCH} == "N/A" ]] && [[ ${REPLICATION_FILTER_DESTINATION_SCHEMA} == "N/A" ]] && [[ ${REPLICATION_FILTER_SOURCE_SCHEMA} == "N/A" ]]; then
    echo "INFO: No replication is setup. No need to extract any ColumnStore CREATE TABLE statements."
else
    echo "INFO: Extracting CREATE TABLE statements for ColumnStore tables that are configured as replication targets."
    # Find all relevant source schemas
    mariadb -s -N -e 'SELECT DISTINCT table_schema FROM information_schema.tables where Engine="InnoDB"' > /tmp/all_innodb_schemas
    pcre2grep "${REPLICATION_FILTER_SOURCE_SCHEMA}" /tmp/all_innodb_schemas > /tmp/filtered_innodb_schemas
    # Find the relevant replication sources
    while read line; do
        mariadb -s -N -e "SELECT concat(table_schema, \".\", table_name) FROM information_schema.tables WHERE ENGINE='InnoDB' AND table_schema=\"${line}\"" >> /tmp/possible_replication_sources
    done < /tmp/filtered_innodb_schemas
    pcre2grep "${REPLICATION_FILTER_MATCH}" /tmp/possible_replication_sources > /tmp/replication_sources
    # Infer the replication targets from the replication_sources
    sed "s/.*\./${REPLICATION_FILTER_DESTINATION_SCHEMA}\./" /tmp/replication_sources > /tmp/replication_targets
    # Get the create table statements for the replication targets
    while read line; do
        mariadb -s -N -e "SHOW CREATE TABLE ${line}" | sed "s/.*\t//" >> /tmp/columnstore_create_table_statements.sql
        echo ";" >> /tmp/columnstore_create_table_statements.sql
    done < /tmp/replication_targets
fi

if [[ $RESTORE_COLUMNSTORE_TABLES == 'true' ]]; then
    # Delete all ColumnStore tables that are replication targets
    if [[ ${REPLICATION_FILTER_MATCH} == "N/A" ]] && [[ ${REPLICATION_FILTER_DESTINATION_SCHEMA} == "N/A" ]] && [[ ${REPLICATION_FILTER_SOURCE_SCHEMA} == "N/A" ]]; then
        echo "INFO: No replication is setup. No need to delete any replication target tables."
    else
        echo "INFO: Deleting old replication target tables."
        while read line; do
            mariadb -s -N -e "DROP TABLE ${line}"
        done < /tmp/replication_targets
    fi
else
    # Delete all ColumnStore table references
    mariadb -s -N -e 'select concat("DROP TABLE IF EXISTS `", table_schema, "`.`", table_name, "`;") FROM information_schema.tables where Engine="Columnstore" AND table_schema!="calpontsys";' > /tmp/drop-cs-tables.sql
    mariadb < /tmp/drop-cs-tables.sql
fi

# Recreate the old replicated ColumnStore tables and repopulate their data from their innodb sources
if [[ ${REPLICATION_FILTER_MATCH} == "N/A" ]] && [[ ${REPLICATION_FILTER_DESTINATION_SCHEMA} == "N/A" ]] && [[ ${REPLICATION_FILTER_SOURCE_SCHEMA} == "N/A" ]]; then
    echo "INFO: No replication is setup. No need to execute any ColumnStore CREATE TABLE statements."
else
    echo "INFO: Recreating ColumnStore target schema and tables"
    mariadb -e "CREATE DATABASE IF NOT EXISTS ${REPLICATION_FILTER_DESTINATION_SCHEMA}"
    mariadb ${REPLICATION_FILTER_DESTINATION_SCHEMA} < /tmp/columnstore_create_table_statements.sql
    while read line; do
        REPLICATION_TABLE_NAME=$(echo $line | sed "s/.*\.//")
        mariadb ${REPLICATION_FILTER_DESTINATION_SCHEMA} -e "INSERT INTO ${REPLICATION_TABLE_NAME} SELECT * FROM ${line};"
    done < /tmp/replication_sources
fi

# restore original skysql_replication user credentials
echo "set global strict_password_validation=0;" > /tmp/restore_skysql_replication_credentials.sql
mariadb -s -N -e 'SELECT concat("SET PASSWORD FOR `", user, "`@`", host, "` = \"<<SKYSQL_REPLICATION_USER_HASH>>\";") FROM mysql.user WHERE user="idbrep"' >> /tmp/restore_skysql_replication_credentials.sql
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
# setup replication
mariadb < /mnt/skysql/columnstore-container-scripts/02-htap_replication.sql

# Reactivate monit
monit monitor all

# Restore completed
echo "$(date) restore completed"
echo "Please restart the container"
