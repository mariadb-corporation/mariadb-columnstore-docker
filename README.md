# Columnstore Cluster (SkySQL Version)

#### Cluster Setup Instructions

*   ```git clone https://github.com/mariadb-corporation/mariadb-skysql-columnstore-docker.git```
*   ```cd mariadb-skysql-columnstore-docker```
*   ```$ cp .env_example .env```
*   Customize the ```.env``` file
*   ```docker-compose up -d && docker exec -it mcs1 cluster-demo```

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

#### Single Node Setup Instructions

*   ```docker run -d --shm-size=512m -e PM1=mcs1 --hostname=mcs1 --name mcs1 mariadb/skysql-enterprise-columnstore-handoff```
*   ```docker exec -it mcs1 single-node-demo```

```
Waiting for PM1 to be initialized ..... done
Adding PM1 to cluster ... done
Validating ... done
```

#### Access Containers

*   PM1: ```docker exec -it mcs1 bash```
*   PM2: ```docker exec -it mcs2 bash```
*   PM3: ```docker exec -it mcs3 bash```
*   MaxScale: ```docker exec -it mx1 bash```

#### Cluster Manipulation Tools

*   `core`  Change directory to /var/log/mariadb/columnstore/corefiles
*   `dbrm` Change directory to /var/lib/columnstore/data1/systemFiles/dbrm
*   `extentSave` Backup extent map
*   `mcsModule` View current module name
*   `mcsReadOnly` Set cluster to Read-Only mode via CMAPI
*   `mcsReadWrite` Set cluster to Read-Write mode via CMAPI
*   `mcsShutdown` Shutdown cluster via CMAPI
*   `mcsStart` Start cluster via CMAPI
*   `mcsStatus` Get cluster status via CMAPI
*   `tcrit` Tail crit.log
*   `tdebug` Tail debug.log
*   `terror` Tail error.log
*   `tinfo` Tail info.log
*   `twarning` Tail warning.log

#### REST-API Instructions

##### Format of url endpoints for REST API:

```perl
https://{server}:{port}/cmapi/{version}/{route}/{command}
```

##### Examples urls for available endpoints:

*   `https://127.0.0.1:8640/cmapi/0.4.0/cluster/status`
*   `https://127.0.0.1:8640/cmapi/0.4.0/cluster/start`
*   `https://127.0.0.1:8640/cmapi/0.4.0/cluster/shutdown`
*   `https://127.0.0.1:8640/cmapi/0.4.0/cluster/node`
*   `https://127.0.0.1:8640/cmapi/0.4.0/cluster/mode-set`

##### Request Headers Needed:

*   'x-api-key': 'somekey123'
*   'Content-Type': 'application/json'

*Note: x-api-key can be set to any value of your choice during the first call to the server. Subsequent connections will require this same key*

##### Examples using curl:

###### Get Status:
```
curl -s https://127.0.0.1:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header 'x-api-key:somekey123' -k | jq .
```
###### Start Cluster:
```
curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20}' -k | jq .
```
###### Stop Cluster:
```
curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/shutdown --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20}' -k | jq .
```
###### Add Node:
```
curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "node": "<replace_with_desired_hostname>"}' -k | jq .
```
###### Remove Node:
```
curl -s -X DELETE https://127.0.0.1:8640/cmapi/0.4.0/cluster/node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "node": "<replace_with_desired_hostname>"}' -k | jq .
```

###### Mode Set:
```
curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/mode-set --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "mode": "readwrite"}' -k | jq .
```

#### MaxScale GUI Info

*   url: `http://127.0.0.1:8989`
*   username: `admin`
*   password: `mariadb`
