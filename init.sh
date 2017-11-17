#! /bin/bash
set -e
#set -x
#dialog="docker run --rm -it --entrypoint dialog frapsoft/shell-ui"
dialog="dialog"

function dlg(){
	$dialog "${@}" --stdout
}

DEFAULT_DOMAIN=${DOMAIN:-example.com}
DOMAIN=`dlg --title 'Domain' --inputbox 'Enter the domain' 0 0 $DEFAULT_DOMAIN`
# TODO: generate ssh private key, upload to aws, and use in kops. upload to bucket
# TODO: add cost allocation tags
# TODO: setup SSL

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
	$aws s3 cp --region $THE_REGION ./$NAME.rsa $KOPS_STATE_STORE/keys/
	$aws s3 cp --region $THE_REGION ./$NAME.rsa.pub $KOPS_STATE_STORE/keys/
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
	NFS_SERVER=$FILE_SYSTEM_ID.efs.$THE_REGION.amazonaws.com
fi

if enabled "secrets"
then
	# setup secrets and envs
	$ktmpl /project/secrets.tmpl.yaml --parameter PASSWORD 5 > secrets.yaml
	# upload secret to s3?
fi

if enabled "gitlab"
then
	echo Deploying gitlab
fi

if enabled "heapster"
then
	echo Deploying heapster
fi

if enabled "ssl"
then
	echo Requesting certificate
fi

if enabled "dashboard"
then
	echo Deploying dashboard
fi

if enabled "dockerregistry"
then
	echo Deploying docker registry
fi

if enabled "externaldns"
then
	echo Deploying external dns
fi


if enabled "env"
then
	echo Generating env files
	# generate env file - aliases and exports (bucket, name)
fi

if enabled "savetos3"
then
	echo Copying configuration to s3 - $KOPS_STATE_STORE
fi

