#!/bin/bash
# shellcheck disable=SC2206
##
# Variable initialization
##

# Constants
SKY_IFLAG='/etc/columnstore/skysql-initialization-completed'

# Getting the needed variables
CMAPI_KEY="${CMAPI_KEY:-somekey123}"
NAMESPACE=$(cat /mnt/skysql/podinfo/namespace)
DNS_NAME="${HOSTNAME}.cs-cluster.${NAMESPACE}.svc.cluster.local"
SHORT_DNS_NAME="${HOSTNAME}.cs-cluster"

if [ -z $PM1_DNS ]; then
    PM1_DNS=$PM1
fi

##
# Functions
##

# Adds the node to the ColumnStore cluster and marks it as initialized
function add-node-to-cluster() {
    # Get last digits of the hostname
    MY_HOSTNAME=$(hostname)
    SPLIT_HOST=(${MY_HOSTNAME//-/ });
    CONT_INDEX=${SPLIT_HOST[(${#SPLIT_HOST[@]}-1)]}

    # Wait for CMAPI to be available to add new nodes
    echo "Waiting for CMAPI to be available to add a new node"
    NUM_NODES=$(curl -s https://$PM1_DNS:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .num_nodes -j)
    while [ $? -ne 0 ] || [ "$NUM_NODES" != "$CONT_INDEX" ]; do
        echo -n "."
        sleep 3
        NUM_NODES=$(curl -s https://$PM1_DNS:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .num_nodes -j)
    done

    # Adding node to ColumnStore cluster
    echo ""
    echo "Adding node $DNS_NAME to the ColumnStore cluster"
    curl -s -X PUT "https://$PM1_DNS:8640/cmapi/0.4.0/cluster/node" --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" --data "{\"timeout\":60, \"node\": \"$DNS_NAME\"}" -k | jq .
    curl -s https://$PM1_DNS:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k | jq .

    if [ $CLUSTER_TOPOLOGY == "columnstore" ]; then
        # Wait for MaxScale to be available
        echo "Waiting for MaxScale to be available"
        MAXSCALE_API_USERNAME=$(cat /mnt/skysql/columnstore-container-configuration/maxscale-api-username)
        MAXSCALE_API_PASSWORD=$(cat /mnt/skysql/columnstore-container-configuration/maxscale-api-password)
        curl -X GET -u ${MAXSCALE_API_USERNAME}:${MAXSCALE_API_PASSWORD} ${RELEASE_NAME}-mariadb-maxscale:8989/v1/maxscale --fail 2>/dev/null >/dev/null
        while [ $? -ne 0 ]; do
            echo -n "."
            sleep 3
            curl -X GET -u ${MAXSCALE_API_USERNAME}:${MAXSCALE_API_PASSWORD} ${RELEASE_NAME}-mariadb-maxscale:8989/v1/maxscale --fail 2>/dev/null >/dev/null
        done

        echo ""
        # Add node to MaxScale
        curl -X GET -u ${MAXSCALE_API_USERNAME}:${MAXSCALE_API_PASSWORD} ${RELEASE_NAME}-mariadb-maxscale:8989/v1/servers/$SHORT_DNS_NAME --fail 2>/dev/null >/dev/null
        if [ $? -ne 0 ]; then
            echo "Adding server $SHORT_DNS_NAME to MaxScale"
            curl -X POST -u ${MAXSCALE_API_USERNAME}:${MAXSCALE_API_PASSWORD} ${RELEASE_NAME}-mariadb-maxscale:8989/v1/servers -d '{"data":{"id":"'$SHORT_DNS_NAME'","type":"servers","attributes":{"parameters":{"address":"'$SHORT_DNS_NAME'","protocol":"MariaDBBackend","proxy_protocol":true}},"relationships":{"services":{"data":[{"id":"Read-Write-Service","type":"services"}]},"monitors":{"data":[{"id":"MariaDB-Monitor","type":"monitors"}]}}}}'
        fi
    fi

    # fix for https://jira.mariadb.org/browse/DBAAS-7726
    /etc/init.d/mariadb restart

    touch $SKY_IFLAG
}

##
# Main program
##

NODES_COUNT=`cat /mnt/skysql/t-shirt-and-custom-config/columnstore.nodes`
echo NODES_COUNT: $NODES_COUNT
# 1. initialize the ColumnStore node if not already done
if [ ! -e $SKY_IFLAG ]; then
    echo "SkySQL init flag missing"
    echo "Starting for the fist time"
    add-node-to-cluster
else
    # Wait for cmapi to be available
    echo "Waiting for cmapi to be available"
    DBRM_MODE=$(curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .\"$DNS_NAME\".dbrm_mode -j)
    while [ $? -ne 0 ] || { [ "$DBRM_MODE" != "offline" ] && [ "$DBRM_MODE" != "master" ] && [ "$DBRM_MODE" != "slave" ]; }; do
        echo -n "."
        sleep 3
        DBRM_MODE=$(curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .\"$DNS_NAME\".dbrm_mode -j)
    done
    echo ""

    # in case the DBRM mode is offline start the cluster
    DBRM_MODE=$(curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .\"$DNS_NAME\".dbrm_mode -j)
    if [ "$DBRM_MODE" == 'offline' ]; then
        echo "Starting the ColumnStore cluster"
        curl -s -X PUT https://localhost:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" --data '{"timeout":60}' -k | jq .
    fi

    # Put the node into read/write mode again
    DBRM_MODE=$(curl -s https://localhost:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header "x-api-key:$CMAPI_KEY" -k --fail | jq .\"$DNS_NAME\".dbrm_mode -j)
    if [ "$DBRM_MODE" != 'offline' ]; then
        echo "Setting the node back into read/write mode"
        columnstoreDBWrite -c resume

        # In case of HTAP re-add the HTAP UDF
        if [[ "$CLUSTER_TOPOLOGY" == "htap" ]]; then
            echo "Re-adding the HTAP UDF"
            mariadb -e 'CREATE OR REPLACE FUNCTION set_htap_replication RETURNS STRING SONAME "replication.so";'
            echo "$?"
        fi
    fi
fi
