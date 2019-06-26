
#	https://github.com/jecho/postgres-operator-notes
#	https://crunchydata.github.io/postgres-operator/3.5.2/operator-cli/
#	^------- helpful notes on operator and pgo-cli

PG_RELEASE_NAME       	?= default
PG_NAMESPACE          	?= $(PG_RELEASE_NAME)
PG_VALUES             	?= ./deployments/helm/cockroachdb/values.yaml
COROOT				  	?= `pwd`

PGO_CMD				  	?= /usr/local/bin/pgo
PGO_NAMESPACE		  	?= $(PG_NAMESPACE)
PGCLUSTER_NAME 	      	?= fromcrd
PGCLUSTER_REPLICA	    ?= 1
PGCLUSTER_CUSTOM_CONFIG ?= pgo-custom-ssl-config
PGBACKUP_DATE			?= 2019-04-24-05-20-54
PGCLUSTER_RESTORE_NAME  ?= restoredcluster
GOBIN                 	?= $GOPATH/bin

#	downloads and installs the pgo-cli
client-binary-install:
	cd ~
	wget https://github.com/CrunchyData/postgres-operator/releases/download/3.5.2/pgo-mac
	chmod +x pgo-mac
	mv pgo-mac /usr/local/bin/pgo

#	creates and deploys keys required to talk to the pg operator
create-operator-keys:
	chmod +x $(COROOT)/deployments/helm/gen-pgo-keys.sh
	$(COROOT)/deployments/helm/gen-pgo-keys.sh

#	deploy the postgres-operator
create-operator:
	helm install --name=$(PG_RELEASE_NAME) --namespace=$(PG_NAMESPACE) $(COROOT)/deployments/helm/postgres-operator

create-pgclient:
	kubectl --namespace=$(PG_NAMESPACE) run --generator=run-pod/v1  postgres-client --image postgres --replicas=1
	#psql "postgresql://testuser@fromcrd:5432/userdb?sslmode=verify-full&sslrootcert=/configs/ca.crt&sslcrl=/configs/ca.crl&sslcert=/configs/client.crt&sslkey=/configs/client.key"

exec:
	kubectl --namespace=$(PG_NAMESPACE) exec -it postgres-client /bin/bash

#	deploy a postgres cluster
create-pgcluster:
	pgo create cluster $(PGCLUSTER_NAME) --custom-config pgo-custom-ssl-config --replica-count=$(PGCLUSTER_REPLICA)

#	creates certs used by a pgcluster
create-pgcluster-certs:
	#sed -i.bak "/^CONTAINER_NAME /s/=.*$/= your-replacement/" $(COROOT)/scripts/pgcluster-certs/create.sh
	$(COROOT)/scripts/pgcluster-certs/create.sh

load-pgcluster-certs:
	kubectl -n $(PG_NAMESPACE) cp $(COROOT)/scripts/pgcluster-certs/certs postgres-client:/configs

basic-test:
	helm test $(PG_RELEASE_NAME)

# regarding backup and restores
# https://crunchydata.github.io/postgres-operator/3.5.2/operator-cli/
# postgres is not secure, do not use as its used as ping by normal operator commands
#
schedule-backup:
	pgo create schedule $(PGCLUSTER_NAME) --schedule="0 8 * * *" \
		--schedule-type=pgbackrest --pgbackrest-backup-type=full \
		--database=userdb --secret=$(PGCLUSTER_NAME)-testuser-secret

#	pgbasebackup
backup-bbup:
	pgo backup $(PGCLUSTER_NAME)

restore:
	pgo restore something

#	Restore from pgbasebackup
restore-create-bbup:
	pgo create cluster $(PGCLUSTER_RESTORE_NAME) --backup-path=/pgdata/$(PGCLUSTER_NAME)-backups/$(PGBACKUP_DATE) \
		--backup-pvc=$(PGCLUSTER_NAME)-backup --secret-from=$(PGCLUSTER_NAME) --replica-count=$(PGCLUSTER_REPLICA)

pgo-expose:
	kubectl -n $(PG_NAMESPACE) patch svc $(PG_RELEASE_NAME)-pgo -p '{"spec": {"type": "LoadBalancer"}}'

event:
	kubectl -n $(PG_NAMESPACE) get event -w

status:
	kubectl -n $(PG_NAMESPACE) get all
	kubectl -n $(PG_NAMESPACE) get secrets

logs-api:
	kubectl -n $(PG_NAMESPACE) logs `kubectl get pod --selector=name=postgres-operator -o jsonpath="{.items[0].metadata.name}"` -c apiserver

logs-ops:
	kubectl -n $(PG_NAMESPACE) logs `kubectl get pod --selector=name=postgres-operator -o jsonpath="{.items[0].metadata.name}"` -c operator

logs-scheduler:
	kubectl -n $(PG_NAMESPACE) logs `kubectl get pod --selector=name=postgres-operator -o jsonpath="{.items[0].metadata.name}"` -c scheduler

cleanup-fromcrd:
	pgo delete cluster $(PGCLUSTER_NAME) --delete-data --delete-backups
	kubectl --namespace=$(PG_NAMESPACE) delete secret --selector=pg-database=$(PG_RELEASE_NAME)

cleanup-fromcrd-nocli:
	kubectl --namespace=$(PG_NAMESPACE) delete pgcluster $(PGCLUSTER_NAME)
	kubectl --namespace=$(PG_NAMESPACE) delete pvc --selector=pg-cluster=$(PGCLUSTER_NAME)
	kubectl --namespace=$(PG_NAMESPACE) delete secret --selector=pg-database=$(PGCLUSTER_NAME)

cleanup-pgclient:
	kubectl --namespace=$(PG_NAMESPACE) delete po postgres-client
	kubectl --namespace=$(PG_NAMESPACE) delete deploy postgres-client

cleanup-operator:
	helm delete --purge $(PG_RELEASE_NAME)
	kubectl --namespace=$(PG_NAMESPACE) delete cm $(PGCLUSTER_CUSTOM_CONFIG)

#	unsafely destroys everything
cleanup-nuke:
	helm delete --purge $(PG_RELEASE_NAME)
	kubectl --namespace=$(PG_NAMESPACE) delete secret fromcrd-pgpool-secret
	kubectl --namespace=$(PG_NAMESPACE) delete rs --all
	kubectl --namespace=$(PG_NAMESPACE) delete deploy --all
	kubectl --namespace=$(PG_NAMESPACE) delete pvc --all