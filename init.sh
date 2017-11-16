#! /bin/bash
set -e
set -x
DOMAIN=`dialog --title "Domain" --inputbox "Enter the domain" 0 0 example.com --stdout`
# TODO: generate ssh private key, upload to aws, and use in kops. upload to bucket
# TODO: add cost allocation tags
# TODO: setup SSL

export NAME=k8a.$DOMAIN
export KOPS_STATE_STORE=s3://k8.$DOMAIN
export THE_REGION=`aws configure get aws_default_region`
export AWS_ACCESS_KEY_ID=`aws configure get aws_access_key_id`
export AWS_SECRET_ACCESS_KEY=`aws configure get aws_secret_access_key`
ZONES_TMP=(`aws ec2 describe-availability-zones | jq '.AvailabilityZones[].ZoneName' -r`)
ZONES=$(printf ",%s" "${ZONES_TMP[@]}")
ZONES=${ZONES:1}
alias kops="docker run --rm -it -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=$THE_REGION -e KOPS_STATE_STORE -v `pwd`/id_rsa.pub:/tmp/id_rsa.pub -v `pwd`/out/:/out/ -v $HOME/.kube/:/root/.kube/ pottava/kops"
alias kubectl="docker run --rm -it -v $HOME/.kube/:/root/.kube/ pottava/kubectl"
alias aws='docker run --rm -t $(tty &>/dev/null && echo "-i") -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}" -v "$(pwd):/project" mesosphere/aws-cli'
alias ktmpl='docker run --rm -v $PWD:/project -t inquicker/ktmpl'
alias dialog='docker run --rm -it --entrypoint dialog frapsoft/shell-ui'

# Setup configuration
dialog --checklist "Choose the options you want:" 0 0 0  1 "Generate SSH-Key" on 2 "Setup GitLab" on 3 "Efs" on 4 "Create cluster" on --stdout
# upload configuration to S3

# Bucket
aws s3 mb --region $THE_REGION $KOPS_STATE_STORE

# Create Cluster
# todo: configure
kops create cluster \
    --zones ${ZONES} \
    --ssh-public-key=/tmp/id_rsa.pub ${NAME}

# EFS
FILE_SYSTEM_ID=`aws efs create-file-system --creation-token $NAME |  jq '.FileSystemId' -r`
aws efs create-tags --file-system-id $FILE_SYSTEM_ID --tags Value=$NAME,Key=Name
NFS_SERVER=$FILE_SYSTEM_ID.efs.$THE_REGION.amazonaws.com

# setup secrets and envs
ktmpl /project/secrets.tmpl.yaml --parameter PASSWORD 5 > secrets.yaml

# setup dashboard
# setup aws autoscaling
# setup heapster
# select component - ncurses

# deploy gitlab
# setup docker registry
