#! /bin/bash
set -e
# set -x
#dialog="docker run --rm -it --entrypoint dialog frapsoft/shell-ui"
dialog="dialog"

function dlg(){
	$dialog "${@}" --stdout
}

DEFAULT_DOMAIN=${DOMAIN:-example.com}
clear
cat logo.txt
sleep 1.5

if [ "DOMAIN" == "" ] 
then
	DOMAIN=`dlg --title 'Domain' --inputbox 'Enter the domain' 0 0 $DEFAULT_DOMAIN`
fi

# TODO: generate aws user and role for cluster - use this key and add to policy to nodes and master
# TODO: put cluster in subdomain
# TODO: add autoscaling for pods
# TODO: add ELB certificate and hook ssl to port 80 with http proto - http://kubernetes-on-aws.readthedocs.io/en/latest/user-guide/tls-termination.html
# TODO: add cnames for services
# TODO: add hostnames for services - http://kubernetes-on-aws.readthedocs.io/en/latest/user-guide/tls-termination.html
# TODO: sizes of volumes in gitlab
# TODO: add cost allocation tags
# TODO: todo ldap compatible dir
# TODO: hook LDAP to all services.
# TODO: https://funktion.fabric8.io/docs/#installing-runtimes-and-connectors
# TODO: minio - https://docs.minio.io/docs/minio-bucket-notification-guide
# TODO: ipsilon
# TODO: freeipa and samba
# TODO: add kibana and integrate 
# TODO: add monitoring and integrate 
# TODO: add company logo
# TODO: add navigator docker
# TODO: add email server and workspace
# TODO: s3 email integration
# TODO: email server and web client
# TODO: multiple clusters: https://medium.com/@alejandro.ramirez.ch/reserving-a-kubernetes-node-for-specific-nodes-e75dc8297076

if [ "$PREFIX" == "" ] 
then
	PREFIX=`dlg --title 'Name' --inputbox 'Enter cluster name' 0 0 k8a`
fi

NAME=$PREFIX.$DOMAIN
KOPS_STATE_STORE=s3://k8.$DOMAIN
THE_REGION=`aws configure get aws_default_region`
AWS_ACCESS_KEY_ID=`aws configure get aws_access_key_id`
if [ "$AWS_ACCESS_KEY_ID" == "" ] 
then
	AWS_ACCESS_KEY_ID=`dlg --title 'AWS_ACCESS_KEY_ID' --inputbox 'Enter your AWS_ACCESS_KEY_ID' 0 0 AKXXXX`
fi
AWS_SECRET_ACCESS_KEY=`aws configure get aws_secret_access_key`
if [ "$AWS_SECRET_ACCESS_KEY" == "" ] 
then
	dlg --clear --insecure --passwordbox "Enter your AWS_SECRET_ACCESS_KEY" 10 50 > tmp
	AWS_SECRET_ACCESS_KEY=`cat tmp`
	rm tmp
fi
if [ "$THE_REGION" == "" ] 
then
	THE_REGION=`dlg --title 'Region' --inputbox 'Enter the region' 0 0 us-west-2`
fi

if [ "$PASSWD" == "" ] 
then
	dlg --clear --insecure --passwordbox "Enter your root password" 10 50 > passwd.tmp
	PASSWD=`cat passwd.tmp`
fi



AWS_DEFAULT_REGION=$THE_REGION
jq="jq"
aws="docker run --rm -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} -e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} -v $PWD:/project mesosphere/aws-cli"
kops="docker run --rm -it -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=$THE_REGION -e KOPS_STATE_STORE -v `pwd`:/tmp2 -v `pwd`/out/:/out/ -v $HOME/.kube/:/root/.kube/ pottava/kops:1.5"
kops="kops"
helm="docker run --rm -it -v $HOME/.kube/:/root/.kube/ -v $HOME/.helm/:/root/.helm/ linkyard/docker-helm"
# helm="helm"
kubectl="docker run --rm -it -v $HOME/.kube/:/root/.kube/ -v $PWD/manifests/:/manifests/ pottava/kubectl"
ktmpl="docker run --rm -v $PWD:/project -t inquicker/ktmpl"
# Setup configuration
if [ "$SELECTED_COMPONENTS" == "" ]
then
	SELECTED_COMPONENTS=`dlg --checklist "Choose the options you want:" 0 0 500  \
		bucket "Generate Bucket" on \
		ssh "Generate SSH-Key" on \
		savetos3 "Save configuration to S3" on \
		efs "Efs" on \
		ssl "*.$Domain Certificates" on \
		clusters "Setup cluster" on \
		clusterl "Launch cluster" on \
		secrets "Config Secrets" on \
		env "Generate env file" on \
		helm "Init helm" on \
		externaldns "DNS auto registration" on \
		dashboard "Deploy Dashboard" on \
		metabase "metabase" on \
		orangehrm "Orange HRM" on \
		heapster "Deploy Heapster" on \
		gitlab "Setup GitLab" on \
		freeipa "FreeIPA" on \
		chartmuseum "chartmuseum" on \
		nodesautoscaling "Node Autoscaling" on \
		phabricator "Phabricator" on \
		owncloud "Owncloud" on \
		wiki "Mediawiki" on \
		kubeaws "k8 aws extensions" on \
		nexus "Sonatype Nexus Repo" on \
		testing "Testing tools" on \
		minio "minio" on \
		wordpress "wordpress" on \
		artifactory "artifactory" on \
		hadoop "hadoop" on \
		social "Social components" on \
		sugarcrm "sugarcrm" on \
		che "Che" on \
		airflow "Airflow" on \
		fabric8 "fabric8" off`
		# taiga "Taiga" on \
		# letschat "letschat" on \		
		# orion "Orion" on \
fi

function enabled(){
	case "${SELECTED_COMPONENTS=[@]}" in  *"$1"*) return 0;; esac
	return 1;
}

if enabled "bucket"
then
	if aws s3 ls "$KOPS_STATE_STORE" 2>&1 | grep -q 'NoSuchBucket'
	then
		echo "Generating Bucket $KOPS_STATE_STORE"
		$aws s3 mb --region $THE_REGION $KOPS_STATE_STORE
	fi
fi
if enabled "ssh"
then
	set +e
	echo -e  'n\n'|ssh-keygen -t rsa -C "admin@$DOMAIN" -f $NAME.rsa -q -N "" > /dev/null
	set -e
	if enabled "savetos3"
	then
		$aws s3 cp --region $THE_REGION ./$NAME.rsa $KOPS_STATE_STORE/meta/$NAME/keys/ > /dev/null
		$aws s3 cp --region $THE_REGION ./$NAME.rsa.pub $KOPS_STATE_STORE/meta/$NAME/keys/ > /dev/null
	fi	
fi
ZONES_TMP=(`$aws ec2 describe-availability-zones | $jq '.AvailabilityZones[].ZoneName' -r`)
ZONES=$(printf ",%s" "${ZONES_TMP[@]}")
ZONES=${ZONES:1}

# Create Cluster
if enabled "clusters"
then
	set +e
	$kops validate cluster $NAME 2>&1 | grep "not found" > /dev/null
	CLUSTER_NOT_FOUND=$?
	set -e	
	if [ $CLUSTER_NOT_FOUND -eq 0 ]
	then
		$kops create cluster \
			--kubernetes-version 1.8.3 \
		    --zones ${ZONES} --node-count 6 --cloud-labels "K8Cluster=$NAME" \
		    --ssh-public-key=./$NAME.rsa.pub ${NAME}
	else
		echo "skipping cluster setup"
	fi
fi
if enabled "clusterl"
then
	set +e
	$kops validate cluster $NAME 2>&1 | grep "does not exist"	> /dev/null
	CLUSTER_NOT_EXIST=$?
	set -e
	if [ $CLUSTER_NOT_EXIST -eq 0 ]
	then
		$kops update cluster ${NAME} --yes
		echo Launched. sleeping		
	else 
		echo "skipping cluster launch"		
	fi
	set +e
	$kops validate cluster $NAME 2>&1 | grep "dial tcp"	> /dev/null
	CLUSTER_NOT_READY=$?
	set -e
	i=55
	while [ $CLUSTER_NOT_READY -eq 0 ]
	do	
		echo $i | dialog --gauge "Cluster loading" 10 70 0
		(( i+=5 ))
		set +e
		$kops validate cluster $NAME 2>&1 | grep "dial tcp"	> /dev/null
		CLUSTER_NOT_READY=$?
		set -e
		sleep 5
	done	
	echo 90 | dialog --gauge "Cluster almost ready" 10 70 0
	sleep 1
	echo 100 | dialog --gauge "Cluster ready" 10 70 0
fi

if enabled "helm"
then
	$helm init
	$helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com/
fi


# if enabled "orion"
# then	
# 	$kubectl apply -f http://central.maven.org/maven2/io/fabric8/devops/apps/orion/2.2.327/orion-2.2.327-kubernetes.yml 
# fi

if enabled "secrets"
then
	# setup secrets and envs
	$ktmpl /project/templates/secrets.tmpl.yaml --parameter AWS_ACCESS_KEY_ID `echo -n $AWS_ACCESS_KEY_ID | base64` --parameter AWS_SECRET_ACCESS_KEY `echo -n $AWS_SECRET_ACCESS_KEY | base64` > manifests/secrets.yaml
	$ktmpl /project/templates/cluster_config.tmpl.yaml --parameter CLUSTER $NAME --parameter DOMAIN $DOMAIN --parameter REGION $THE_REGION > manifests/cluster_config.yaml	
	if enabled "savetos3"
	then
		echo Copying configuration to s3 - $KOPS_STATE_STORE
		$aws s3 cp --region $THE_REGION ./manifests/cluster_config.yaml $KOPS_STATE_STORE/meta/$NAME/config/
		$aws s3 cp --region $THE_REGION ./manifests/secrets.yaml $KOPS_STATE_STORE/meta/$NAME/secrets/
	fi
	echo "applying config and secrets"
	$kubectl apply -f /manifests/secrets.yaml
	$kubectl apply -f /manifests/cluster_config.yaml
	# apply
fi

if enabled "efs"
then	
	FILE_SYSTEM_ID=`aws efs describe-file-systems --creation-token $NAME | $jq '.FileSystems[0].FileSystemId' -r`
	if [ "$FILE_SYSTEM_ID" == "null" ]
	then
		FILE_SYSTEM_ID=`$aws efs create-file-system --creation-token $NAME | $jq '.FileSystemId' -r`
aws efs create-tags --file-system-id $FILE_SYSTEM_ID --tags Value=$NAME,Key=Name
	fi	
	MASTER_SEC_GROUP=`$aws ec2 describe-security-groups | jq --arg name "$NAME" '.SecurityGroups[] | select(.GroupName == "masters." + $name) | .GroupId' -r`
	SUBNETS=`$aws ec2 describe-subnets | jq --arg name "$NAME" '.Subnets[] | select(.Tags[]? | select(.Key=="KubernetesCluster") | .Value == $name) | .SubnetId' -r`
	# SUBNETS=$(printf ",%s" "${SUBNETS_TMP[@]}")
	# SUBNETS=${SUBNETS:1}
	# TODO: enable access - creating access endpoint in all the relevant subnets. + sec groups
	MOUNT_TARGETS=`$aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID | jq '.MountTargets[].MountTargetId'`
	if [ "$MOUNT_TARGETS" == "" ]
	then
		echo $SUBNETS | xargs -n 1 $aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --security-groups $MASTER_SEC_GROUP --subnet-id 
	fi
	$ktmpl /project/templates/efs.tmpl.yaml --parameter FILE_SYSTEM_ID $FILE_SYSTEM_ID --parameter REGION $THE_REGION > manifests/efs.yaml	
	$kubectl apply -f /manifests/efs.yaml
	$kubectl delete storageclass default		
	$kubectl apply -f /manifests/efs-storage-class.yaml
	$kubectl patch storageclass default -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	set +e
	$kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
	$kubectl delete storageclass gp2 
	set -e
	$kubectl patch storageclass default -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	$kubectl apply -f /manifests/efs-volume-claim.yaml
fi

if enabled "ssl"
then
	CERT_ARN=`$aws acm list-certificates --region $THE_REGION | jq --arg domain "$DOMAIN" '.CertificateSummaryList[] | select(.DomainName == "*." + $domain) | .CertificateArn  ' -r`
	echo $CERT_ARN
	if [ "$CERT_ARN" == "" ]
	then
		echo Requesting certificate	
		CERT_ARN=`$aws acm request-certificate --region $THE_REGION --domain-name *.$DOMAIN --idempotency-token $PREFIX | jq '.CertificateArn' -r`
	fi	
	STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN | jq '.Certificate.Status' -r`
	while [ "$STATUS" == "PENDING_VALIDATION" ];	do
		dlg --msgbox "Certificate Status: $STATUS.\n Please continue once you confirm the validation" 0 0
		STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN | jq '.Certificate.Status' -r`	
	done	

	CERT_ARN_CI=`$aws acm list-certificates --region $THE_REGION | jq --arg domain "ci.$DOMAIN" '.CertificateSummaryList[] | select(.DomainName == "*." + $domain) | .CertificateArn  ' -r`	
	echo CERT_ARN_CI $CERT_ARN_CI
	if [ "$CERT_ARN_CI" == "" ]
	then
		echo Requesting certificate	
		CERT_ARN_CI=`$aws acm request-certificate --region $THE_REGION --domain-name *.ci.$DOMAIN --idempotency-token ci$PREFIX | jq '.CertificateArn' -r`
	fi	
	STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN_CI | jq '.Certificate.Status' -r`
	while [ "$STATUS" == "PENDING_VALIDATION" ];	do
		dlg --msgbox "Certificate Status: $STATUS.\n Please continue once you confirm the validation" 0 0
		STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN_CI | jq '.Certificate.Status' -r`	
	done	

	# CERT_ARN_FAB=`$aws acm list-certificates --region $THE_REGION | jq --arg domain "fabric8.$DOMAIN" '.CertificateSummaryList[] | select(.DomainName == "*." + $domain) | .CertificateArn  ' -r`	
	# echo CERT_ARN_FAB $CERT_ARN_FAB
	# if [ "$CERT_ARN_FAB" == "" ]
	# then
	# 	echo Requesting certificate	
	# 	CERT_ARN_FAV=`$aws acm request-certificate --region $THE_REGION --domain-name *.fabric8.$DOMAIN --idempotency-token fabric8$PREFIX | jq '.CertificateArn' -r`
	# fi	
	# STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN_FAB | jq '.Certificate.Status' -r`
	# while [ "$STATUS" == "PENDING_VALIDATION" ];	do
	# 	dlg --msgbox "Certificate Status: $STATUS.\n Please continue once you confirm the validation" 0 0
	# 	STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN_FAB | jq '.Certificate.Status' -r`	
	# done		

	#dlg --msgbox "Certificate Status: $STATUS" 0 0
fi

set +e
if enabled "owncloud"
then
	$helm install --name owncloud --set owncloudUsername=admin,owncloudPassword="$PASSWD",owncloudHost=owncloud.$DOMAIN stable/owncloud
fi

if enabled "phabricator"
then
	$helm install  --name phabricator --set phabricatorPassword="$PASSWD",phabricatorHost=phabricator.$DOMAIN stable/phabricator
fi

if enabled "wiki"
then
	$helm install --name wiki --set mediawikiPassword="$PASSWD" stable/mediawiki
fi
if enabled "kubeaws"
then	
	$helm install --name kube2iam stable/kube2iam
	$helm install --set awsRegion=$THE_REGION --name fluentd-cloudwatch incubator/fluentd-cloudwatch
	$helm install stable/cluster-autoscaler --name awsautoscaler --set "autoscalingGroups[0].name=nodes.$NAME,autoscalingGroups[0].maxSize=10,autoscalingGroups[0].minSize=4"
	$kubectl apply -f manifests/kube-node-labeller.ds.yaml
fi

if enabled "grafana"
then
	$helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
	$helm install --name grafana --set server.adminPassword="$PASSWD" incubator/grafana
fi

if enabled "che"
then
	$kubectl apply -f http://central.maven.org/maven2/io/fabric8/online/apps/che/1.0.54/che-1.0.54-kubernetes.yml	
fi

if enabled "airflow"
then
	$kubectl apply -f manifests/airflow.all.yaml
fi


if enabled "artifactory"
then
	echo Deploying artifactory
	$helm install --name artifactory --set database.env.pass="$PASSWD",artifactory.image.repository=docker.bintray.io/jfrog/artifactory-oss stable/artifactory
fi

if enabled "hadoop"
then
	$helm install --name hadoop $(stable/hadoop/tools/calc_resources.sh 50) \
	  --set persistence.nameNode.enabled=true \
	  --set persistence.nameNode.storageClass=standard \
	  --set persistence.dataNode.enabled=true \
	  --set persistence.dataNode.storageClass=standard \
	  stable/hadoop

	$helm install --name zeppelin --set hadoop.useConfigMap=true stable/zeppelin
	# $helm install --name spark stable/spark
fi

if enabled "sugarcrm"
then
	echo deploying sugarcrm
	$helm install --name sugarcrm --set sugarcrmPassword="$PASSWD",sugarcrmHost=sugarcrm.$DOMAIN stable/sugarcrm
fi

if enabled "consul"
then
	$helm install --name consul --set ui.enabled=true stable/consul
fi

if enabled "nexus"
then
	echo deploying nexus3
	$helm install --name nexus stable/sonatype-nexus
fi

if enabled "orangehrm"
then
	echo deploying orangehrm
	$helm install --name orangehrm stable/orangehrm
fi

if enabled "testing"
then	
	$helm install --name selenium stable/selenium
	$helm install --name testlink --set testlinkPassword="$PASSWD" stable/testlink
fi

if enabled "wordpress"
then		
	$helm install --set wordpressPassword="$PASSWD" --name wordpress stable/wordpress
fi

if enabled "minio"
then		
	$helm install --name minio --set mode=distributed,accessKey=$AWS_ACCESS_KEY_ID,secretKey=$AWS_SECRET_ACCESS_KEY stable/minio
fi

if enabled "phpbb"
then		
	$helm install --set phpbbPassword="$PASSWD" --name phpbb stable/phpbb
fi

if enabled "social"
then
	$kubectl apply -f http://central.maven.org/maven2/io/fabric8/platform/packages/social/2.4.24/social-2.4.24-kubernetes.yml 
fi

if enabled "taiga"
then			
	$kubectl apply -f http://central.maven.org/maven2/io/fabric8/devops/apps/taiga/2.2.327/taiga-2.2.327-kubernetes.yml 
fi

if enabled "chartmuseum"
then
	$helm install --name=chartmuseum incubator/chartmuseum
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi


if enabled "dashboard"
then
	#discover existing certs
	echo Deploying dashboard
	$kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
	$kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard-head.yaml
	$helm install --name=kube-ops-view stable/kube-ops-view
	echo "http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard-head:/proxy/"
fi

if enabled "metabase"
then
	#discover existing certs
	echo Deploying metabase
	$helm install --name metabase --set service.type=LoadBalancer stable/metabase
fi

set -e

function setRoute53() {
	record_name=$1
	record_value=$2

	[[ -z $record_name  ]] && echo "record_name is: $record_name" && exit 1
	[[ -z $record_value ]] && echo "record_value is: $record_value" && exit 1

	## set some defaults if variables haven't been overridden on script execute
	zone_name=${zone_name:-$3}
	action=${action:-CREATE}
	record_type=${record_type:-A}
	ttl=${ttl:-300}
	wait_for_sync=${wait_for_sync:-false}

	change_id=$(submit_resource_record_change_set $record_name $record_value) || exit 1
	echo "Record change submitted! Change Id: $change_id"
	if $wait_for_sync; then
		echo -n "Waiting for all Route53 DNS to be in sync..."
		until [[ $(get_change_status $change_id) == "INSYNC" ]]; do
		 	echo -n "."
		 	sleep 5
		done
		echo "!"
		echo "Your record change has now propogated."
	fi	
}

function change_batch() {
	$jq -c -n "{\"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"$1\", \"Type\": \"CNAME\", \"TTL\": 300, \"ResourceRecords\": [{\"Value\": \"$2\"} ] } } ] }"
}

function get_change_status() {
	$aws route53 get-change --id $1 | $jq -r '.ChangeInfo.Status'
}

function hosted_zone_id() {
   $aws route53 list-hosted-zones | $jq -r ".HostedZones[] | select(.Name == \"${zone_name}\") | .Id" | cut -d'/' -f3
}

function submit_resource_record_change_set() {
	$aws route53 change-resource-record-sets --hosted-zone-id $(hosted_zone_id) --change-batch $(change_batch $1 $2) | jq -r '.ChangeInfo.Id' | cut -d'/' -f3
}

if enabled "gitlab"
then	
	$helm repo add gitlab https://charts.gitlab.io
	echo Deploying gitlab	
	set +e	
	# $helm del --purge gitlab
	set -e		
	# EMAIL=`dlg --title 'Email' --inputbox 'Enter your email' 0 0 admin@$DOMAIN`
	EMAIL=admin@$DOMAIN
	set +e	
	$helm install --name gitlab --set gitlabDataStorageClass=standard,gitlabRegistryStorageClass=standard,gitlabConfigStorageClass=standard,postgresStorageClass=standard,redisStorageClass=standard,legoEmail=$EMAIL,provider=,gitlabRootPassword="$PASSWD",baseDomain=ci.$DOMAIN gitlab/gitlab-omnibus
	set -e
	sleep 10
	GITLAB_LB_HOSTNAME=`$kubectl get svc --namespace nginx-ingress nginx  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`	

	# set wildcard alias in route53 for *.gitlab.$DOMAIN -> LB
	setRoute53 '*.ci.'$DOMAIN $GITLAB_LB_HOSTNAME $DOMAIN.

	# attach CERT_ARN_GITLAB certificate to ELB

	# TODO: enable auto devops
	# TODO: email intergration 
	# TODO: taiga intergration	

	# $kubectl get svc --namespace default gitlab-gitlab-ce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
	
	# $helm install --name gitlab-runner --set runnerRegistrationToken="$PASSWD",gitlabURL=http://gitlab.$DOMAIN/ gitlab/gitlab-runner
	# claim efs volume
	# set cname
	# apply gitlab	
fi

if enabled "heapster"
then
	echo Deploying heapster		
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi

if enabled "nodesautoscaling"
then
	$kubectl apply -f /manifests/cluster-autoscaler.yaml
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi


if enabled "freeipa"
then
	$helm repo add cnct http://atlas.cnct.io
	$helm install --name openldap --set OpenLdap.AdminPassword=$PASSWD,OpenLdap.Domain=$DOMAIN cnct/openldap

	$kubectl apply -f /manifests/freeipa.yaml
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi


if enabled "externaldns"
then
	echo Deploying external dns
	$kubectl apply -f /manifests/external-dns.yaml
fi

if enabled "fabric8"
then
	set +e
	# $kubectl delete namespace fabric8
	set -e
	curl -sS https://get.fabric8.io/download.txt | bash
	# $helm repo add fabric8 https://fabric8.io/helm
	# $helm install fabric8/fabric8-platform	
	# rm tmp
	# ~/.fabric8/bin/gofabric8 deploy --package system --http=true --legacy=false -n fabric8 -y	
	if [ "$GITHUB_OAUTH_CLIENT_ID" == "" ] 
	then
		GITHUB_OAUTH_CLIENT_ID=`dlg --title 'GITHUB_OAUTH_CLIENT_ID' --inputbox 'Enter your GITHUB_OAUTH_CLIENT_ID' 0 0 AKXXXX`
	fi	
	if [ "$GITHUB_OAUTH_CLIENT_SECRET" == "" ] 
	then
		dlg --clear --insecure --passwordbox "Enter your GITHUB_OAUTH_CLIENT_SECRET" 10 50 > tmp
		GITHUB_OAUTH_CLIENT_SECRET=`cat tmp`
		rm tmp
	fi	
	# wget http://central.maven.org/maven2/io/fabric8/platform/packages/fabric8-full/4.0.208/fabric8-full-4.0.208-k8s-template.yml
	# wget http://central.maven.org/maven2/io/fabric8/platform/packages/social/4.0.208/social-4.0.208-kubernetes.yml
	# wget http://central.maven.org/maven2/io/fabric8/platform/packages/funktion-platform/2.4.24/funktion-platform-2.4.24-kubernetes.yml
	# wget http://central.maven.org/maven2/io/fabric8/platform/packages/management/4.0.208/management-4.0.208-kubernetes.yml
	set +e
	~/.fabric8/bin/gofabric8 deploy --github-client-id $GITHUB_OAUTH_CLIENT_ID --github-client-secret $GITHUB_OAUTH_CLIENT_SECRET --domain=$DOMAIN --ingress=true --namespace fabric8 --package fabric8-full-4.0.208-k8s-template.yml --http=true --legacy=true -n fabric8 -y
	~/.fabric8/bin/gofabric8 deploy --domain=$DOMAIN --namespace fabric8 --package social-4.0.208-kubernetes.yml -y --ingress=true --http=true --legacy=true
	~/.fabric8/bin/gofabric8 deploy --domain=$DOMAIN --namespace fabric8 --package funktion-platform-2.4.24-kubernetes.yml -y --ingress=true --http=true --legacy=true
	~/.fabric8/bin/gofabric8 deploy --domain=$DOMAIN --namespace fabric8 --package management-4.0.208-kubernetes.yml -y --ingress=true --http=true --legacy=true
	set -e
	HOSTNAME=`$kubectl get svc --namespace nginx-ingress nginx-ingress  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`	

	# set wildcard alias in route53 for *.gitlab.$DOMAIN -> LB
	setRoute53 '*.fabric8.'$DOMAIN $HOSTNAME $DOMAIN.	
fi

if enabled "env"
then
	echo Generating env files
	# generate env file - aliases and exports (bucket, name)
	if enabled "savetos3"
	then
		echo uploading env to s3
	fi
	echo "run source $NAME.env"
	echo "run kubectl proxy"
fi
