BUILDTYPE:=$(if $(JENKINS_HOME),jenkins,local)
THIS_FILE:=$(lastword $(MAKEFILE_LIST))

ifeq ($(BUILDTYPE),local)
-include ~/.userenv
export
endif

PROJECTDIR?=${PIPELINE_WORKSPACE}
AZURE_CLIENT_ID?=${AZURE_CLIENT_ID}
AZURE_CLIENT_SECRET?=${AZURE_CLIENT_SECRET}
AZURE_TENANT_ID?=${AZURE_TENANT_ID}
DOCKERFILES?=
DOCKERLOGIN?=jenkins
DOCKERPASSWORD?=changeme
DOCKERPROJECT?=estore
DOCKERREGISTRY?=harbor.cnct.team
DOCKERTAG?=${PIPELINE_DOCKERTAG}
HELM_INJECT_VALUEPATHS?=
HELM_INJECT_VERSION?=${PIPELINE_CHARTVERSION}
HELM_TILLER_NAMESPACE?=${PIPELINE_TILLER_NAMESPACE}
HELMCHART?=
HELMLOGIN?=${PIPELINE_CHART_CREDS_USERNAME}
HELMPASSWORD?=${PIPELINE_CHART_CREDS_PASSWORD} 
HELMRELEASE?=${PIPELINE_TARGET_RELEASE}
HELMREPONAME?=${PIPELINE_HELM_REPO_NAME}
HELMTIMEOUT?=${PIPELINE_TIMEOUT}
HELMVERSION?=${PIPELINE_CHARTVERSION}
KUBECONTEXT?=
KUBENAMESPACE?=${PIPELINE_TARGET_NAMESPACE}
KUBESECRETS?=
LOCALCREDS:=$(if ${JENKINS_HOME},'',$(PROJECTDIR)/.docker)

# template for generating dockerfile targets
tmpl-image=image-$1

# template fr generating SOPS targets
tmpl-sops=sops-$1

# template for generating k8s resource targets
tmpl-kubectl=kubectl-$1

# template for generating value injection helm chart targets
tmpl-valinject=valinject-$(subst =,_setto_,$1)

# template for generating helm chart install targets
tmpl-helminstall=helminstall-$1

# template execution rules
tmpl-for=$(foreach x,$2,$(call $1,$x))
rule-for=$(foreach x,$2,$(eval $(call $1,$x)))

# rule for building a 'dockerfile'
define build-image-rule
$(call tmpl-image,$1):TOBUILD:=$1
.PHONY: $(call tmpl-image,$1)
endef

# rule for decrypting a SOPS secret
define decrypt-sops-rule
$(call tmpl-sops,$1):TODECRYPT:=$1
.PHONY: $(call tmpl-sops,$1)
endef

# rule for creating a k8s secret
define create-k8s-rule
$(call tmpl-kubectl,$1):TOCREATE:=$1
.PHONY: $(call tmpl-kubectl,$1)
endef

# rule for operating helm charts
define valinject-chart-rule
$(call tmpl-valinject,$1):INJECTVALPATH:=$1
.PHONY: $(call tmpl-valinject,$1)
endef

# rule for installing helm charts
define helminstall-chart-rule
$(call tmpl-helminstall,$1):HELMCHART:=$1
.PHONY: $(call tmpl-helminstall,$1)
endef

.PHONY: list
list:
	@$(MAKE) -pRrq -f $(lastword $(THIS_FILE)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$'

# generates a static docker registry credential set
# for use inside running docker images
imagebuild-local-pre:
	@echo Getting temporary docker registry credentials
	@mkdir -p $(LOCALCREDS)
	@docker run -v $(LOCALCREDS):/root/.docker docker sh -c "echo $(DOCKERPASSWORD) | docker login $(DOCKERREGISTRY) -u $(DOCKERLOGIN) --password-stdin"

# build all docker images
imagebuild-all: $(call tmpl-for,tmpl-image,$(DOCKERFILES))

# build each individual dockerfile, each one get a generated target
$(call rule-for,build-image-rule,$(DOCKERFILES)) 
ifeq ($(BUILDTYPE),local)
$(call tmpl-for,tmpl-image,$(DOCKERFILES)): imagebuild-local-pre
else
$(call tmpl-for,tmpl-image,$(DOCKERFILES)):
endif
	@echo Building container: $(TOBUILD)
	$(eval CONTEXTVAR:=$(shell echo $(TOBUILD) | tr - _ | tr a-z A-Z)_DOCKER_CONTEXT)
	$(eval CONTEXTVAL:=$(shell echo ${$(CONTEXTVAR)}))
	$(eval BUILDARGNAMESVAR:=$(shell echo $(TOBUILD) | tr - _ | tr a-z A-Z)_DOCKER_BUILDARGNAMES)
	$(eval BUILDARGNAMESVAL:=$(shell echo ${$(BUILDARGNAMESVAR)}))
	$(if $(BUILDARGNAMESVAL),$(eval BUILDARGNAMESENVVALS:=$(foreach argpart,$(shell echo ${$(BUILDARGNAMESVAR)} | tr - _ | tr a-z A-Z), $(shell echo $(TOBUILD) | tr - _ | tr a-z A-Z)_DOCKER_$(argpart))))
	$(if $(BUILDARGNAMESVAL),$(eval NLIST:=$(shell for x in $$(seq 1 $(words $(BUILDARGNAMESVAL))); do echo $$x; done)))
	$(if $(BUILDARGNAMESVAL),$(eval BUILDARGS:=$(foreach index,$(NLIST), --build-arg $(word $(index),$(BUILDARGNAMESVAL))="$(shell echo ${$(word $(index),$(BUILDARGNAMESENVVALS))})")))

ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-v $(LOCALCREDS):/kaniko/.docker \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-kaniko:latest \
		-f $(PROJECTDIR)/build/docker/$(TOBUILD)/Dockerfile -c $(CONTEXTVAL) \
		--destination=harbor.cnct.team/estore/$(TOBUILD):$(DOCKERTAG) --reproducible --cache=true $(BUILDARGS)		
else
	@/kaniko/executor -f $(PROJECTDIR)/build/docker/$(TOBUILD)/Dockerfile -c $(CONTEXTVAL) \
		--destination=harbor.cnct.team/estore/$(TOBUILD):$(DOCKERTAG) --reproducible --cache=true $(BUILDARGS)
endif

# decrypt all raw secrets
sops-raw-all: $(call tmpl-for,tmpl-sops,$(KUBESECRETS))

# decrypt each individual raw kubernetes secret, each one gets a target
$(call rule-for,decrypt-sops-rule,$(KUBESECRETS)) 
$(call tmpl-for,tmpl-sops,$(KUBESECRETS)):
	@echo Decrypting file: $(PROJECTDIR)/$(TODECRYPT)
	@mkdir -p $(PROJECTDIR)/.decrypted
ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-e AZURE_CLIENT_ID=$(AZURE_CLIENT_ID) \
		-e AZURE_CLIENT_SECRET=$(AZURE_CLIENT_SECRET) \
		-e AZURE_TENANT_ID=$(AZURE_TENANT_ID) \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-sops:latest \
		sops --config $(PROJECTDIR)/.sops.yaml --output $(PROJECTDIR)/.decrypted/decrypted-raw-$(notdir $(TODECRYPT)) --decrypt $(PROJECTDIR)/$(TODECRYPT)
else
	@sops --config $(PROJECTDIR)/.sops.yaml --output $(PROJECTDIR)/.decrypted/decrypted-raw-$(notdir $(TODECRYPT)) --decrypt $(PROJECTDIR)/$(TODECRYPT)
endif

# decrypt all helm secrets
sops-helm-all: $(call tmpl-for,tmpl-sops,$(HELMSECRETS))

# decrypt each individual raw kubernetes secret, each one gets a target
$(call rule-for,decrypt-sops-rule,$(HELMSECRETS)) 
$(call tmpl-for,tmpl-sops,$(HELMSECRETS)):
	@echo Decrypting helm secrets $(TODECRYPT)
	@mkdir -p $(PROJECTDIR)/.decrypted
ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-e AZURE_CLIENT_ID=$(AZURE_CLIENT_ID) \
		-e AZURE_CLIENT_SECRET=$(AZURE_CLIENT_SECRET) \
		-e AZURE_TENANT_ID=$(AZURE_TENANT_ID) \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-sops:latest \
		sops --config $(PROJECTDIR)/.sops.yaml --output $(PROJECTDIR)/.decrypted/decrypted-helm-$(notdir $(TODECRYPT)) --decrypt $(PROJECTDIR)/$(TODECRYPT)
else
	@sops --config $(PROJECTDIR)/.sops.yaml --output $(PROJECTDIR)/.decrypted/decrypted-helm-$(notdir $(TODECRYPT)) --decrypt $(PROJECTDIR)/$(TODECRYPT)
endif

# create all secrets
kubectl-create-all: $(call tmpl-for,tmpl-kubectl,$(KUBESECRETS))

# create each individual raw kubernetes secret, each one get a target
$(call rule-for,create-k8s-rule,$(KUBESECRETS)) 
$(call tmpl-for,tmpl-kubectl,$(KUBESECRETS)):
	@echo Creating secret: $(PROJECTDIR)/$(TOCREATE)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-v $(HOME)/.kube:/root/.kube \
		-e KUBECONFIG=/root/.kube/config \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest \
		kubectl create namespace $(KUBENAMESPACE) --context=$(KUBECONTEXT) || true
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-v $(HOME)/.kube:/root/.kube \
		-v $(PROJECTDIR)/.decrypted:/root/.decrypted \
		-e KUBECONFIG=/root/.kube/config \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest \
		kubectl apply -f $(PROJECTDIR)/.decrypted/decrypted-raw-$(notdir $(TOCREATE)) --context=$(KUBECONTEXT) -n $(KUBENAMESPACE)
else
	@kubectl create namespace $(KUBENAMESPACE) || true
	@kubectl apply -f $(PROJECTDIR)/.decrypted/decrypted-raw-$(notdir $(TOCREATE)) -n $(KUBENAMESPACE)
endif

# inject all helm chart values
valinject-all: $(call tmpl-for,tmpl-valinject,$(HELM_INJECT_VALUEPATHS)) valinject-version

# inject each individual chart with values, each one get a generated target
$(call rule-for,valinject-chart-rule,$(HELM_INJECT_VALUEPATHS)) 
$(call tmpl-for,tmpl-valinject,$(HELM_INJECT_VALUEPATHS)):
	$(eval INJECTVAR:=HELM_INJECT_$(shell echo $(INJECTVALPATH) | tr . _ | tr a-z A-Z))
	$(eval INJECTVAL:=$(shell echo ${$(INJECTVAR)}))
	@echo Injecting $(INJECTVALPATH)="$(INJECTVAL)" in: $(HELMCHART)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
			$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-valueparse:latest \
			--file $(PROJECTDIR)/deployments/helm/$(HELMCHART)/values.yaml --key-val $(INJECTVALPATH)="$(INJECTVAL)"
else
	@parse.py --file $(PROJECTDIR)/deployments/helm/$(HELMCHART)/values.yaml --key-val $(INJECTVALPATH)="$(INJECTVAL)"
endif

# inject chart version
valinject-version:
	@echo Injecting version=$(HELM_INJECT_VERSION) into: $(PROJECTDIR)/deployments/helm/$(HELMCHART)/Chart.yaml
ifeq ($(BUILDTYPE),local)
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-valueparse:latest \
		--file $(PROJECTDIR)/deployments/helm/$(HELMCHART)/Chart.yaml --key-val version=$(HELM_INJECT_VERSION);
else
	@parse.py --file $(PROJECTDIR)/deployments/helm/$(HELMCHART)/Chart.yaml --key-val version=$(HELM_INJECT_VERSION);
endif

# helm init
helm-init:
ifeq ($(BUILDTYPE),local)
	@mkdir -p $(HOME)/.helm
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm init --client-only; \
			helm repo add --username=$(HELMLOGIN) --password=$(HELMPASSWORD) $(HELMREPONAME) \
			https://$(DOCKERREGISTRY)/chartrepo/$(DOCKERPROJECT); 
else
	@helm init --client-only; \
		helm repo add --username=$(HELMLOGIN) --password=$(HELMPASSWORD) $(HELMREPONAME) \
		https://$(DOCKERREGISTRY)/chartrepo/$(DOCKERPROJECT); 
endif

# helm install
helm-install-repo: 
	@echo Installing: $(HELMCHART)
	$(eval HELMVALUESARGS:=$(foreach arg,$(HELMVALUES),-f $(PROJECTDIR)/$(arg)))
	$(eval HELMSECRETSARGS:=$(foreach arg,$(HELMSECRETS),-f $(PROJECTDIR)/.decrypted/decrypted-helm-$(notdir $(arg))))
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm upgrade --install \
			$(HELMRELEASE) $(HELMREPONAME)/$(HELMCHART) --wait --timeout $(HELMTIMEOUT) --tiller-namespace $(HELM_TILLER_NAMESPACE) \
								--namespace $(KUBENAMESPACE) $(HELMVALUESARGS) $(HELMSECRETSARGS) --version $(HELMVERSION) --kube-context=$(KUBECONTEXT)
else
	@helm upgrade --install \
	$(HELMRELEASE) $(HELMREPONAME)/$(HELMCHART) --wait --timeout $(HELMTIMEOUT) --tiller-namespace $(HELM_TILLER_NAMESPACE) \
		--namespace $(KUBENAMESPACE) $(HELMVALUESARGS) $(HELMSECRETSARGS) --version $(HELMVERSION)
endif

helm-install-source:
	@echo Installing: $(HELMCHART)
	$(eval HELMVALUESARGS:=$(foreach arg,$(HELMVALUES),-f $(PROJECTDIR)/$(arg)))
	$(eval HELMSECRETSARGS:=$(foreach arg,$(HELMSECRETS),-f $(PROJECTDIR)/.decrypted/decrypted-helm-$(notdir $(arg))))
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm dependency update --debug $(PROJECTDIR)/deployments/helm/$(HELMCHART)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm upgrade --install \
			$(HELMRELEASE) $(PROJECTDIR)/deployments/helm/$(HELMCHART) --wait --timeout $(HELMTIMEOUT) --tiller-namespace $(HELM_TILLER_NAMESPACE) \
								--namespace $(KUBENAMESPACE) $(HELMVALUESARGS) $(HELMSECRETSARGS) --kube-context=$(KUBECONTEXT)
else
	@helm dependency update --debug $(PROJECTDIR)/deployments/helm/$(HELMCHART)
	@helm upgrade --install \
	$(HELMRELEASE) $(PROJECTDIR)/deployments/helm/$(HELMCHART) --wait --timeout $(HELMTIMEOUT) --tiller-namespace $(HELM_TILLER_NAMESPACE) \
		--namespace $(KUBENAMESPACE) $(HELMVALUESARGS) $(HELMSECRETSARGS)
endif
	@rm -f $(PROJECTDIR)/deployments/helm/$(HELMCHART)/requirements.lock
	@rm -rf $(PROJECTDIR)/deployments/helm/$(HELMCHART)/charts

helm-test: 
	@echo Testing release: $(HELMRELEASE)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm test $(HELMRELEASE) --timeout $(HELMTIMEOUT) --kube-context=$(KUBECONTEXT)
else
	@helm test $(HELMRELEASE) --timeout $(HELMTIMEOUT)
endif	

helm-clean:
	@echo Cleaning release: $(HELMRELEASE)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm delete $(HELMRELEASE) --purge --kube-context=$(KUBECONTEXT) || true
	@docker run -v $(PROJECTDIR):$(PROJECTDIR) \
		-v $(HOME)/.kube:/root/.kube \
		-e KUBECONFIG=/root/.kube/config \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest \
		kubectl delete namespace $(KUBENAMESPACE) --context=$(KUBECONTEXT) || true
else
	@helm delete $(HELMRELEASE) --purge || true
	@kubectl delete namespace $(KUBENAMESPACE) --context=$(KUBECONTEXT) || true
endif	
	@rm -f $(PROJECTDIR)/deployments/helm/$(HELMCHART)/requirements.lock
	@rm -rf $(PROJECTDIR)/deployments/helm/$(HELMCHART)/charts

helm-package: 
	@echo Packaging $(HELMCHART)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm dependency update --debug $(PROJECTDIR)/deployments/helm/$(HELMCHART)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest helm package --debug --destination $(PROJECTDIR) $(PROJECTDIR)/deployments/helm/$(HELMCHART) 
else
	@helm dependency update --debug $(PROJECTDIR)/deployments/helm/$(HELMCHART)
	@helm package --debug --destination $(PROJECTDIR) $(PROJECTDIR)/deployments/helm/$(HELMCHART)
endif	
	@rm -f $(PROJECTDIR)/deployments/helm/$(HELMCHART)/requirements.lock
	@rm -rf $(PROJECTDIR)/deployments/helm/$(HELMCHART)/charts

helm-push:
	@echo Pushing $(HELMCHART)
ifeq ($(BUILDTYPE),local)
	@docker run -v $(HOME)/.kube:/root/.kube \
		-v $(HOME)/.helm:$(HOME)/.helm \
		-v $(PROJECTDIR):$(PROJECTDIR) \
		-e KUBECONFIG=/root/.kube/config \
		-e HELM_HOME=$(HOME)/.helm \
		$(DOCKERREGISTRY)/$(DOCKERPROJECT)/pipeline-step-helm:latest curl -u $(HELMLOGIN):$(HELMPASSWORD) \
			-F chart=@$(PROJECTDIR)/$(HELMCHART)-$(HELM_INJECT_VERSION).tgz https://$(DOCKERREGISTRY)/api/chartrepo/$(DOCKERPROJECT)/charts --show-error --fail
else
	@curl -u $(HELMLOGIN):$(HELMPASSWORD) \
			-F chart=@$(PROJECTDIR)/$(HELMCHART)-$(HELM_INJECT_VERSION).tgz https://$(DOCKERREGISTRY)/api/chartrepo/$(DOCKERPROJECT)/charts --show-error --fail
endif	
	@rm -f $(PROJECTDIR)/$(HELMCHART)-$(HELM_INJECT_VERSION).tgz

git-commit: 
	@echo Pushing changes to git
ifeq ($(BUILDTYPE),local)
	@echo NOOP for local
else
	@git config user.email $$PIPELINE_IGNORED_COMMITTER; \
		git config user.name Jenkins; \
		git pull --no-edit origin master; \
		git add .; \
		git commit --allow-empty -m 'Automated push by Jenkins CI'; \
		git push origin HEAD:master
endif	

git-tag: 
	@echo Tagging git
ifeq ($(BUILDTYPE),local)
	@echo NOOP for local
else
	@git config user.email $$PIPELINE_IGNORED_COMMITTER; \
		git config user.name Jenkins; \
		git fetch --all; \
		if git rev-parse $$PIPELINE_GITTAG >/dev/null 2>&1; then \
		echo 'Tag already exists'; else \
		git tag -a $$PIPELINE_GITTAG -m 'Automated push by Jenkins CI'; \
		git push origin --tags; fi
endif