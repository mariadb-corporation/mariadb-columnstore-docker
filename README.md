![MariaDB](https://mariadb.com/wp-content/uploads/2019/11/mariadb-logo_blue-transparent.png)

# Columnstore Docker Project

## Summary
MariaDB ColumnStore is a columnar storage engine that utilizes a massively parallel distributed data architecture. It was built by porting InfiniDB to MariaDB and has been released under the GPL license.

MariaDB ColumnStore is designed for big data scaling to process petabytes of data, linear scalability and exceptional performance with real-time response to analytical queries. It leverages the I/O benefits of columnar storage, compression, just-in-time projection, and horizontal and vertical partitioning to deliver tremendous performance when analyzing large data sets.

## Requirements

Please install the following software packages before you begin.

*   [Git](https://git-scm.com/downloads)
*   [Docker](https://www.docker.com/get-started)

Also make sure to grab your download credentials from our website:

*   [MariaDB Enterprise Token](https://customers.mariadb.com/downloads/token/)

## Quick Start Instructions (All)

*   ```$ git clone https://github.com/mariadb-corporation/mariadb-columnstore-docker.git```
*   ```$ cd mariadb-columnstore-docker```
*   ```$ cp .env_example .env```
*   Customize the ```.env``` file
*   ```$ ./build```
*   ```$ ./run_project```

```
Waiting for PM1 to be initialized ................... done
Adding PM1 to CMAPI ... done
Adding PM2 to CMAPI ... done
Adding PM3 to CMAPI ... done
Adding PM1 to MaxScale 1 ... done
Adding PM2 to MaxScale 1 ... done
Adding PM3 to MaxScale 1 ... done
Adding PM1 to MaxScale 2 ... done
Adding PM2 to MaxScale 2 ... done
Adding PM3 to MaxScale 2 ... done
Adding SERVICE to MaxScale 1 ... done
Adding SERVICE to MaxScale 2 ... done
Adding LISTENER to MaxScale 1 ... done
Adding LISTENER to MaxScale 2 ... done
Adding MONITOR to MaxScale 1 ... done
Adding MONITOR to MaxScale 2 ... done
Waiting for CMAPI cluster start ....... done
Validating ColumnStore engine ... done
```

## Docker-Compose Instructions (Cluster)

*   ```$ git clone https://github.com/mariadb-corporation/mariadb-columnstore-docker.git```
*   ```$ cd mariadb-columnstore-docker```
*   ```$ cp .env_example .env```
*   Customize the ```.env``` file
*   ```$ ./build```
*   ```$ docker compose up -d && docker exec -it mcs1 provision```

```
Waiting for PM1 to be initialized ................... done
Adding PM1 to CMAPI ... done
Adding PM2 to CMAPI ... done
Adding PM3 to CMAPI ... done
Waiting for CMAPI cluster start ....... done
Validating ColumnStore engine ... done
```

## Docker Run Instructions (Single Node)

*   ```$ git clone https://github.com/mariadb-corporation/mariadb-columnstore-docker.git```
*   ```$ cd mariadb-columnstore-docker```
*   ```$ cp .env_example .env```
*   Customize the ```.env``` file
*   ```$ ./build```
*   ```$ docker run -d --shm-size=512m -e PM1=mcs1 --hostname=mcs1 --name mcs1 mariadb/columnstore && docker exec -it mcs1 provision```

```
Waiting for PM1 to be initialized ................... done
Adding PM1 to CMAPI ... done
Waiting for CMAPI cluster start ........ done
Validating ColumnStore engine ... done
```

#### Run Variables

| Variable | Type | Default | Required |
|---|---|---|---|
| ADMIN_HOST | String | % | No |
| ADMIN_PASS | String | C0lumnStore! | No |
| ADMIN_USER | String | Admin | No |
| CEJ_PASS | String | C0lumnStore! | No |
| CEJ_USER | String | cej | No |
| CMAPI_KEY | String | somekey123 | No |
| PM1 | Hostname | mcs1 | **Yes** |
| S3_ACCESS_KEY_ID | String | None | No |
| S3_BUCKET | String | None | No |
| S3_ENDPOINT | URL | None | No |
| S3_REGION | String | None | No |
| S3_SECRET_ACCESS_KEY | String | None | No |
| USE_S3_STORAGE | Boolean | false | No |

## Access

#### Columnstore CLI Access

*   PM1: ```$ docker exec -it mcs1 mariadb```
*   PM2: ```$ docker exec -it mcs2 mariadb```
*   PM3: ```$ docker exec -it mcs3 mariadb```

#### MaxScale 1 GUI Access

*   URL: `http://127.0.0.1:8989`
*   username: `admin`
*   password: `mariadb`

#### MaxScale 2 GUI Access

*   URL: `http://127.0.0.1:8990`
*   username: `admin`
*   password: `mariadb`

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

#### Other Glossary Items
*   **PM**: Performance Module
*   **PM1**: Primary Database Node
*   **PM2**: Secondary Database Node
*   **PM3**: Tertiary Database Node
*   **MX1**: Primary MaxScale Node
*   **MX2**: Secondary MaxScale Node


## MCS Commandline Instructions

##### Set API Code:

``` mcs cluster set api-key --key <api_key>```

###### Get Status:

```mcs cluster status```

###### Start Cluster:

```mcs cluster start```

###### Stop Cluster:

```mcs cluster stop```

###### Add Node:

```mcs cluster node add --node <node>```

###### Remove Node:

```mcs cluster node remove --node <node>```

###### Mode Set Read Only:

```mcs cluster set mode --mode readonly```

###### Mode Set Read/Write:

```mcs cluster set mode --mode readwrite```


## REST-API Instructions

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
$ curl -s https://127.0.0.1:8640/cmapi/0.4.0/cluster/status --header 'Content-Type:application/json' --header 'x-api-key:somekey123' -k | jq .
```
###### Start Cluster:
```
$ curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/start --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20}' -k | jq .
```
###### Stop Cluster:
```
$ curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/shutdown --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20}' -k | jq .
```
###### Add Node:
```
$ curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "node": "<replace_with_desired_hostname>"}' -k | jq .
```
###### Remove Node:
```
$ curl -s -X DELETE https://127.0.0.1:8640/cmapi/0.4.0/cluster/node --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "node": "<replace_with_desired_hostname>"}' -k | jq .
```

###### Mode Set:
```
$ curl -s -X PUT https://127.0.0.1:8640/cmapi/0.4.0/cluster/mode-set --header 'Content-Type:application/json' --header 'x-api-key:somekey123' --data '{"timeout":20, "mode": "readwrite"}' -k | jq .
```