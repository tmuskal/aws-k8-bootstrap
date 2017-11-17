#! /bin/bash
set -e
# set -x
#dialog="docker run --rm -it --entrypoint dialog frapsoft/shell-ui"
dialog="dialog"

function dlg(){
	$dialog "${@}" --stdout
}

DEFAULT_DOMAIN=${DOMAIN:-example.com}
DOMAIN=`dlg --title 'Domain' --inputbox 'Enter the domain' 0 0 $DEFAULT_DOMAIN`
# TODO: generate user and role for cluster
# TODO: add cost allocation tags

PREFIX=`dlg --title 'Name' --inputbox 'Enter cluster name' 0 0 k8a`
export NAME=$PREFIX.$DOMAIN
export KOPS_STATE_STORE=s3://k8.$DOMAIN
export THE_REGION=`aws configure get aws_default_region`
export AWS_DEFAULT_REGION=`aws configure get aws_default_region`
export AWS_ACCESS_KEY_ID=`aws configure get aws_access_key_id`
export AWS_SECRET_ACCESS_KEY=`aws configure get aws_secret_access_key`
jq="jq"
aws="docker run --rm -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} -e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} -v $PWD:/project mesosphere/aws-cli"
ZONES_TMP=(`$aws ec2 describe-availability-zones | $jq '.AvailabilityZones[].ZoneName' -r`)
ZONES=$(printf ",%s" "${ZONES_TMP[@]}")
ZONES=${ZONES:1}
kops="docker run --rm -it -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=$THE_REGION -e KOPS_STATE_STORE -v `pwd`:/tmp2 -v `pwd`/out/:/out/ -v $HOME/.kube/:/root/.kube/ pottava/kops:1.4"
kubectl="docker run --rm -it -v $HOME/.kube/:/root/.kube/ pottava/kubectl"
ktmpl="docker run --rm -v $PWD:/project -t inquicker/ktmpl"
# Setup configuration
SELECTED_COMPONENTS=`dlg --checklist "Choose the options you want:" 0 0 500  \
ssh "Generate SSH-Key" on \
bucket "Generate Bucket" on \
gitlab "Setup GitLab" on \
efs "Efs" on \
clusters "Setup cluster" on \
clusterl "Launch cluster" on \
savetos3 "Save configuration to S3" on \
env "Generate env file" on \
dashboard "Deploy Dashboard" on \
heapster "Deploy Heapster" on \
ssl "Generate Certificate for *.$Domain" on \
nodesautoscaling "Node Autoscaling" off
secrets "Config Secrets" on`
# upload configuration to S3
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
	echo -e  'y\n'|ssh-keygen -t rsa -C "admin@$DOMAIN" -f $NAME.rsa -q -N ""
	if enabled "savetos3"
	then
		$aws s3 cp --region $THE_REGION ./$NAME.rsa $KOPS_STATE_STORE/$NAME/keys/
		$aws s3 cp --region $THE_REGION ./$NAME.rsa.pub $KOPS_STATE_STORE/$NAME/keys/
	fi	
fi
# Create Cluster
if enabled "clusters"
then
	$kops create cluster \
	    --zones ${ZONES} \
	    --ssh-public-key=/tmp2/$NAME.rsa.pub ${NAME}
fi
if enabled "clusterl"
then
	$kops update cluster ${NAME} --yes
fi


if enabled "efs"
then
	FILE_SYSTEM_ID=`aws efs describe-file-systems --creation-token k8a.cybercyder.com | $jq '.FileSystems[0].FileSystemId' -r`
	if [ "$FILE_SYSTEM_ID" == "null" ]
	then
		FILE_SYSTEM_ID=`$aws efs create-file-system --creation-token $NAME | $jq '.FileSystemId' -r`
aws efs create-tags --file-system-id $FILE_SYSTEM_ID --tags Value=$NAME,Key=Name
	fi	
	# TODO: enable access - creating access endpoint in all the relevant subnets.
fi

if enabled "secrets"
then
	# setup secrets and envs
	$ktmpl /project/templates/secrets.tmpl.yaml --parameter AWS_ACCESS_KEY_ID $AWS_ACCESS_KEY_ID --parameter AWS_SECRET_ACCESS_KEY $AWS_SECRET_ACCESS_KEY > manifests/secrets.yaml	
	$ktmpl /project/templates/cluster_config.tmpl.yaml --parameter FILE_SYSTEM_ID $FILE_SYSTEM_ID --parameter CLUSTER $NAME --parameter REGION $THE_REGION > manifests/cluster_config.yaml	
	if enabled "savetos3"
	then
		echo Copying configuration to s3 - $KOPS_STATE_STORE
		$aws s3 cp --region $THE_REGION ./manifests/cluster_config.yaml $KOPS_STATE_STORE/$NAME/config/
		$aws s3 cp --region $THE_REGION ./manifests/secrets.yaml $KOPS_STATE_STORE/$NAME/secrets/
	fi
	$kubectl apply -f manifests/secrets.yaml
	$kubectl apply -f manifests/cluster_config.yaml
	# apply
	if enabled "efs"
	then
		$kubectl apply -f manifests/efs.yaml
		$kubectl apply -f manifests/efs-storage-class.yaml
		$kubectl apply -f manifests/efs-volume-claim.yaml
		# apply efs		
	fi
fi

if enabled "ssl"
then
	CERT_ARN=`$aws acm list-certificates --region $THE_REGION | jq --arg domain "$DOMAIN" '.CertificateSummaryList[] | select(.DomainName == "*." + $domain) | .CertificateArn  ' -r`
	echo $CERT_ARN
	if [ "$CERT_ARN" == "null" ]
	then
		echo Requesting certificate	
		CERT_ARN=`$aws acm request-certificate --region $THE_REGION --domain-name *.$DOMAIN --idempotency-token $DOMAIN | jq '.CertificateArn' -r`
	fi	
	STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN | jq '.Certificate.Status' -r`
	while [ "$STATUS" == "PENDING_VALIDATION" ];	do
		dlg --msgbox "Certificate Status: $STATUS.\n Please continue once you confirm the validation" 0 0
		STATUS=`$aws acm describe-certificate --region $THE_REGION --certificate-arn $CERT_ARN | jq '.Certificate.Status' -r`	
	done	
	dlg --msgbox "Certificate Status: $STATUS" 0 0
fi

if enabled "gitlab"
then
	echo Deploying gitlab
	# claim efs volume
	# apply gitlab	
fi

if enabled "heapster"
then
	echo Deploying heapster		
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi

if enabled "nodesautoscaling"
then
	$kubectl apply -f manifests/cluster-autoscaler.yaml
	# https://github.com/kubernetes/heapster/blob/master/docs/influxdb.md
fi

if enabled "dashboard"
then
	#discover existing certs
	echo Deploying dashboard
	$kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
	echo "http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/"
fi

if enabled "dockerregistry"
then
	echo Deploying docker registry
fi

if enabled "externaldns"
then
	echo Deploying external dns
	$kubectl apply -f manifests/external-dns.yaml
fi

if enabled "env"
then
	echo Generating env files
	# generate env file - aliases and exports (bucket, name)
	echo "run source $NAME.env"
	echo "run kubectl proxy"
fi
