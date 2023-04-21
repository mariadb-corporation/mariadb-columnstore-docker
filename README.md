![MariaDB](https://mariadb.com/wp-content/uploads/2019/11/mariadb-logo_blue-transparent.png)

# Columnstore Docker Project

## Summary
MariaDB ColumnStore is a columnar storage engine that utilizes a massively parallel distributed data architecture. It was built by porting InfiniDB to MariaDB and has been released under the GPL license.

MariaDB ColumnStore is designed for big data scaling to process petabytes of data, linear scalability and exceptional performance with real-time response to analytical queries. It leverages the I/O benefits of columnar storage, compression, just-in-time projection, and horizontal and vertical partitioning to deliver tremendous performance when analyzing large data sets.

## Requirements

Please install the following software packages before you begin.

*   [Docker](https://www.docker.com/get-started)

## Docker-Compose Instructions (Cluster)

*   Clone this project to your local system
*   Copy **_.env_example_** to **_.env_**
*   Edit **_.env_** with your custom settings
*   ```$ docker compose up -d```
*   ```$ docker exec -it mcs1 provision mcs1 mcs2 mcs3```

```
Waiting for PM1 To Be Initialized .... done
Adding PM(s) To Cluster ... done
Restarting Cluster ... done
Validating ColumnStore Engine ... done
```

## Docker Run Instructions (Single Node)

*   ```$ docker run -d -p 3307:3306 --shm-size=512m -e PM1=mcs1 --hostname=mcs1 --name mcs1 mariadb/columnstore```
*   ```$ docker exec -it mcs1 provision mcs1```

```
Waiting for PM1 To Be Initialized .. done
Adding PM(s) To Cluster ... done
Restarting Cluster ... done
Validating ColumnStore Engine ... done
```

## Run Variables

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

#### Database Access

*   ```$ mysql -h 127.0.0.1 -P 3307 -u admin -p```
*   The default password is: **C0lumnStore!**

#### MaxScale 1 GUI Access

*   URL: `http://127.0.0.1:8989`
*   username: `admin`
*   password: `mariadb`

#### MaxScale 2 GUI Access

*   URL: `http://127.0.0.1:8990`
*   username: `admin`
*   password: `mariadb`

#### Glossary Items
*   **PM**: Performance Module
*   **PM1**: Primary Database Node
*   **PM2**: Secondary Database Node
*   **PM3**: Tertiary Database Node
*   **MX1**: Primary MaxScale Node
*   **MX2**: Secondary MaxScale Node

## CLI Instructions

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

## Log Info

Logs are stored in ```/var/log/mariadb/columnstore```