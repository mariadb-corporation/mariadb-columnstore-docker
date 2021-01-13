# Columnstore Cluster (SkySQL Version)

### Build instructions

To build the ColumnStore image an extra GitHub personal access token needs to be provided to be able to fetch the `skysql-backup` tool from a private repository [1].  
This GitHub personal access token shall **not** be hard coded in this repository as it grants access to other private MariaDB GitHub repositories.  

Instead the GitHub personal access token should be provided as build argument:
```bash
docker build . -t "<<DockerHub_Repository>>:<<Tag>>" --build-arg SKYSQL_BACKUP_GITHUB_TOKEN="<<GitHub_Personal_Access_Token>>"
```

We would be happy to share a GitHub personal access token of one of our functional build accounts through 1password if desired. [2]  
It is at your discretion to alternatively hard code any `skysql-backup` binary directly in this repository, create and use GitHub personal access tokens of your own accounts, or alter the backup/restore procedure completely.

[1] https://github.com/mariadb-corporation/skysql-backup  
[2] https://mariadb.1password.com/

### Setup Instructions

*   ```git clone https://github.com/mariadb-corporation/columnstore-docker-cluster.git```
*   ```cd columnstore-docker-cluster```
*   Customize the ```.env``` file
*   ```docker-compose up -d && docker exec -it mcs1 demo```
```
Waiting for PM1 to be initialized ................... done
Adding PM1 to cluster ... done
Adding PM2 to cluster ... done
Adding PM3 to cluster ... done
Validating ... done
Adding PM3 to MaxScale ... done
Adding PM2 to MaxScale ... done
Adding PM1 to MaxScale ... done
Adding service ... done
Adding listener ... done
Adding monitor ... done
```


### Access Containers

*   PM1: ```docker exec -it mcs1 bash```
*   PM2: ```docker exec -it mcs2 bash```
*   PM3: ```docker exec -it mcs3 bash```
*   MaxScale: ```docker exec -it mx1 bash```

## Columnstore API Info

### Request Headers Needed:

*   'x-api-key': 'somekey123'
*   'Content-Type': 'application/json'

*Note: x-api-key can be set to any value of your choice during the first call to the server. Subsequent connections will require this same key*

### Examples using curl:

#### Add Node 1:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/add-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs1"}' -k | jq .
```
#### Add Node 2:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/add-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs2"}' -k | jq .
```
#### Add Node 3:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/add-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs3"}' -k | jq .
```
#### Get Status:
```
curl -s https://mcs1:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header 'x-api-key:somekey123' -k | jq .
```
#### Remove Node 1:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/remove-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs1"}' -k | jq .
```
#### Remove Node 2:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/remove-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs2"}' -k | jq .
```
#### Remove Node 3:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/remove-node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60, "node": "mcs3"}' -k | jq .
```
#### Stop Cluster:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/shutdown --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60}' -k | jq .
```
#### Start Cluster:
```
curl -s -X PUT https://mcs1:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":60}' -k | jq .
```

## MaxScale GUI Info

*   url: `http://127.0.0.1:8989`
*   username: `admin`
*   password: `mariadb`
