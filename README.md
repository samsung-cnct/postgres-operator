# Postgres Operator Helm Chart 3.5.2

* CrunchyData Helm Chart's _README.md_ are located [here](https://bitbucket.org/jecho-r/ep-postgres-operator/src/master/deployments/helm/postgres-operator)
* Unoffical for Postgres Operator 3.4.0 are located [here](https://github.com/jecho/postgres-operator-notes)
* Samsung-CNCT Confluence Doc are located [here](https://samsung-cnct.atlassian.net/wiki/spaces/EP/pages/306511902/Database+Containerization+PostgreSQL+Operator+Usage)

## Getting Started

These instructions will get you a copy of CrunchyData's Postgres Operator up and running on your local Kubernetes cluster. This README.md makes extensive use of a `Makefile` to simplify ease of testing and prototyping and as such not all aspects will be covered. This older _Makefile_ is housed in scripts directory.

Everything covered here only addresses a `secure` or `TLS` typed pgcluster.

Preperation is covered for 3.5.2.

### Terminology
* pgo = postgres operator
* pgcluster = postgres cluster
* pg/postgres instance = 1 running postgres

### Features to be aware of
* Autofail (automatic and manual)
* Has native load balancers (pgpool and pgbouncer)
* Able to back up and schedule backups (as PVC)
* Able to restore (multiple extensions)
* Has pod anti-affinity for pgclusters

### Shortcomings
* Cannot create 'pgcluster' in its own namespace (available in 4.0.0 release)
* TLS generation is standard and done by provided script and before `helm install`, not an init container of any sort
* Upgrading the operator and associated container images is not clear
* Operator is not HA

### Upcoming release 4.0.0
* 'pgcluster' can be namespaced
*  backups can be sent to cloud provider storage

### Prerequisites

* kubectl
* helm
* go 1.7
* [square/certstrap](https://github.com/square/certstrap)
> all can be brewed, or installed manually

If the Helm chart is set to use `custom_config` the following files need to be configured. These extends the basic functionality of the operator and the base configuration of Postgres and Pgpool instances.

```
: Operator
pgo.yaml

: Pgcluster
pg_hba.conf
pg_ident.conf
postgresql.conf

: Pgpool
pgpool.conf
```
A script through `make create-pgcluster-certs` will bootstrap certs and bundle the configuration into a ConfigMap to be consumed by an initalized `pgcluster`.

## Deploying the operator

Clone the repo

```
git clone git@bitbucket.org:seaecom/ep-postgres-operator.git
cd ep-postgres-operator
```

Install `pgo-cli` as it is a method to interact with the postgres-operator 

```
cd ~
wget https://github.com/CrunchyData/postgres-operator/releases/download/3.5.2/pgo-mac
chmod +x pgo-mac
mv pgo-mac /usr/local/bin/pgo
```

Setup env variables for `pgo-cli`

```
export COROOT=`pwd`
export PGO_CA_CERT=$COROOT/deployments/helm/postgres-operator/files/apiserver/server.crt
export PGO_CLIENT_CERT=$COROOT/deployments/helm/postgres-operator/files/apiserver/server.crt
export PGO_CLIENT_KEY=$COROOT/deployments/helm/postgres-operator/files/apiserver/server.key
echo "username:password" > $HOME/.pgouser
```

Generate the certs for the `pgo` and for our `pgcluster`
Change to the scripts folder found in this path

```
cd scripts/
```

Then run the following `make` commands

```
make create-operator-keys
make create-pgcluster-certs
```

Deploy the operator. This execute the default `values.yaml` which will deploy the `postgres-operator` along with the specified `pgcluster`. The `pgcluster` can be disabled if needed to be created seperately on launch. 

Default `values.yaml` consists of 1primary, 1replica, and 1pgpool and should be running. Main alteration components to glean are the `pgcluster` object.

```
make create-operator
```

After the cluster deploys allow a couple of seconds to generate our LoadBalanced IP. Connect our `pgo-cli` to our postges-operator by the following commands

```
export CO_APISERVER_NAME=$(kubectl get svc --selector=app=pgo -o=jsonpath="{.items[0].metadata.name}")
export HTTPS=https://
export CO_APISERVER_URL=$(kubectl get svc ${CO_APISERVER_NAME} --output=jsonpath='{range .status.loadBalancer.ingress[0]}{.ip}') 
export CO_APISERVER_PORT=8443
export CO_APISERVER_URL=${HTTPS}${CO_APISERVER_URL}:${CO_APISERVER_PORT}
```

### Deploying Operator and Pgcluster in a different namespace

Before deployment of the chart, you need to update the values of namespace in the `values.yaml` file. They appear on line 19 and 51. One controls the namespace the operator is deployed, and this variable is piped into the operator, the other controls where pgcluster will deploy too. At the moment, both the operator and the pgcluster have to be deployed in same namespace for the operator and all the postgres functionality to work properly. Version 4.0.0 should resolve this.

### Assigning Pod Affinity/Anti-affinity
> in progress

### Backup and Restoration for pgclusters

Goes over very basic functionality. Brief summary is there are multiple backup formats, `pgbasebackup` and `pgdump` to name a few. Pgdump is addressed below. `pgo-cli` must be configured.

Manual
```
pgo backup fromcrd --backup-type=pgdump
```

Scheduling
```
pgo create schedule fromcrd --schedule="18 * * * *" \ --schedule-type=pgdump --pvc-name=fromcrd-backup
```

Restoring
```
pgo restore fromcrd --backup-type=pgdump --backup-pvc=backup-fromcrd-pgdump-pvc
```

For more information, consult [here](https://samsung-cnct.atlassian.net/wiki/spaces/EP/pages/306511902/Database+Containerization+PostgreSQL+Operator+Usage) and [here](https://crunchydata.github.io/postgres-operator/stable/operator-cli/)

## Using the CLI

### Basic operations

```
pgo create cluster m            # creates primary db instance
pgo create cluster m --pgpool   # creates traditional postgres loadbalancer
pgo create cluster m --replica-count=2  # creates replica of N
pgo create cluster m --metrics          # enables metrics sidecar
pgo create cluster m --replica-count=2 --pgpool --replica-count=2   # aggregated args
pgp delete cluster m
pgo delete cluster m --delete-data --delete-backups # deletes all pvc and backup data
pgo status m
pgp show user m         # shows username and passwords for databases
```

## Testing pgclusters
> in progress

## Upgrading operator
> https://crunchydata.github.io/postgres-operator/stable/upgrade/

### Cleanup

```
# cleans up sample pgcluster fromcrd
make -i cleanup-fromcrd
sleep 120
# cleans up the operator
make -i cleanup-operator
```

## Configuration

### Postgres Operator _(values.yaml)_
| Parameter | Description | Default |
| ----- | ----------- | ------ |
| `image.repository` | Repository for postgres operator image | `crunchydata/postgres-operator` |
| `image.tag` | Tag for prometheus operator image | `centos7-3.5.2` |
| `image.pullPolicy` | Pull policy for postgres operator image | `IfNotPresent` |
| `env.ccp_image_prefix` |  | `crunchydata` |
| `env.ccp_image_tag` | Tag for crunchydata-postgres version | `centos7-11.2-2.3.1` |
| `env.cpp_image` | Name of crunchy-postgres image | `crunchy-postgres` |
| `env.co_image_prefix` | | `crunchydata` |
| `env.co_image_tag` | Tag for postgres operator version | `centos7-3.5.2` |
| `env.tls_no_verify` | Postgres operator requires TLS | `false` |
| `env.namespace` | Namespace to deploy operator | `default` |
| `service.type` | Postgres operator service type | `LoadBalancer` |
| `service.port` | Port to expose Postgres operator | `8443` |
| `pgcluster.enabled` | Deploy pgcluster | `true` |
| `pgcluster.tls.custom_config` | custom_config is a configMap that has configuration files required by the operator, postgres and pgpool instances along with bundled certificates | `go-custom-ssl-config` |
| `pgcluster.name` | Pgcluster name | `fromcrd` |
| `pgcluster.namespace` | Namespace to deploy pgcluster | `default` |
| `pgcluster.labels.archive` | ---- | `true` |
| `pgcluster.labels.archive_timeout` | ---- | `600` |
| `pgcluster.labels.autofail` | If true, enables autofail over to replica pod | `true` |
| `pgcluster.labels.autofail_replace_replica` | If true, enables creation of replica pod after failover | `true` |
| `pgcluster.labels.crunchy_pgbadger` | Deploy pgbadger sidecar | `false` |
| `pgcluster.labels.crunchy_collect` | Deploy prometheus-metric sidecar | `false` |
| `pgcluster.labels.crunchy_pgpool` | Deploy pgpool  | `true` |
| `pgcluster.labels.current-primary` | ---- | `fromcrd` |
| `pgcluster.labels.deployment-name` | Name of the pgcluster deployment | `fromcrd` |
| `pgcluster.labels.name` | Global name of the pgcluster | `fromcrd` |
| `pgcluster.labels.pg_cluster` | If true, enables backup type backrest | `false` |
| `pgcluster.labels.pgo_version` | Version of pgo to deploy | `3.5.2` |
| `pgcluster.labels.primary` | ---- | `true` |
| `pgcluster.spec.ccpimagetag` | Version of postgres and iteration agaisn't pgo | `centos7-11.2-2.3.1` |
| `pgcluster.spec.port` | Postgres port service runs on | `5432` |
| `pgcluster.spec.primarysecretname` | Name of replication secret | `fromcrd-primaryuser-secret` |
| `pgcluster.spec.replicas` | Number of replicas in pgcluster | `1` |
| `pgcluster.spec.rootsecretname` | Name of root secret | `fromcrd-postgres-secret` |
| `pgcluster.spec.strategy` | Autofailover strategy | `1` |
| `pgcluster.spec.user` | Name of client user | `testuser` |
| `pgcluster.spec.usersecretname` | Name of user secret | `fromcrd-testuser-secret` |
| `pgcluster.spec.secret.primaryuser.password` | Define the password for primaryuser | `T0p4EcRetDta2` |
| `pgcluster.spec.secret.postgres.password` | Define the password for postgres | `T0p4EcRetDta` |
| `pgcluster.spec.secret.testuser.password` | Define the password for testuser | `T0p4EcRetDta24` |
| `pgcluster.spec.ContainerResources` | Define resources request and limits for pods | `` |
| `pgcluster.spec.PrimaryStorage.accessmode` | Define access mode of PVC | `ReadWriteOnce` |
| `pgcluster.spec.PrimaryStorage.fsgroup` | Define security context of fsgroup | `0` |
| `pgcluster.spec.PrimaryStorage.matchLabels` | --- | `` |
| `pgcluster.spec.PrimaryStorage.name` | Name of the primary storage | `fromcrd` |
| `pgcluster.spec.PrimaryStorage.size` | Define the size of the allocated PVC | `1G` |
| `pgcluster.spec.PrimaryStorage.storageclass` | Define the storage class in use | `default` |
| `pgcluster.spec.PrimaryStorage.storagetype` | --- | `create` |
| `pgcluster.spec.PrimaryStorage.supplementalgroups` | Define security context of supplementalgroups  | `` |
| `pgcluster.spec.ReplicaStorage.accessmode` | Define access mode of PVC | `ReadWriteOnce` |
| `pgcluster.spec.ReplicaStorage.fsgroup` | Define security context of fsgroup | `0` |
| `pgcluster.spec.ReplicaStorage.matchLabels` | --- | `` |
| `pgcluster.spec.ReplicaStorage.name` | Name of the primary storage | `fromcrd` |
| `pgcluster.spec.ReplicaStorage.size` | Define the size of the allocated PVC | `1G` |
| `pgcluster.spec.ReplicaStorage.storageclass` | Define the storage class in use | `default` |
| `pgcluster.spec.ReplicaStorage.storagetype` | --- | `create` |
| `pgcluster.spec.ReplicaStorage.supplementalgroups` | Define security context of supplementalgroups  | `` |

### pgo.yaml
> in progress