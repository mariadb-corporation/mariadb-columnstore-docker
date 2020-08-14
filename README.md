# INTERNAL TESTING ONLY

### Setup Instructions

* ```git clone https://github.com/mariadb-corporation/columnstore-docker-cluster.git```
* ```cd columnstore-docker-cluster```
* Customize the ```.env``` file
* ```docker-compose up```

### Access Containers

* ```docker exec -it mcs1 bash```
* ```docker exec -it mcs2 bash```
* ```docker exec -it mcs3 bash```

## Demo

### Create Cluster & Load Sample Data

#### Access Primary Container
```
$ docker exec -it mcs1 bash
```
#### Run "demo" Bash Script
```
[root@mcs1 /]# demo
```

This [script](scripts/demo) adds the 2nd and 3rd node to the cluster. It also loads some sample data for testing.

#### Enter MariaDB Client
```
[root@mcs1 /]# mariadb
```
#### Run Sample Query
```sql
SELECT
q.airline,
q.volume flight_count,
Round(100 * q.volume / SUM(q.volume) OVER (ORDER BY q.airline ROWS BETWEEN unbounded preceding AND unbounded following),2) market_share_pct,
Round(100 * (q.cancelled / q.volume), 2) cancelled_pct,
Round(100 * (q.diverted / q.volume), 2) diverted_pct
FROM (
    SELECT a.airline,
    COUNT(*) volume,
    SUM(diverted) diverted,
    SUM(cancelled) cancelled
    FROM flights.flights f
    join flights.airlines a ON f.carrier = a.iata_code
    WHERE f.year = 2018
    GROUP BY a.airline
) q
ORDER BY flight_count DESC;
```

## API Info

### Request Headers Needed:

* 'x-api-key': 'somekey123'
* 'Content-Type': 'application/json'

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
