#! /bin/bash
kops="kops"
aws="aws"
$kops delete cluster $NAME --yes
jq="jq"

# remove efs
FILE_SYSTEM_ID=`$aws efs describe-file-systems --creation-token $NAME | $jq '.FileSystems[0].FileSystemId' -r`
$aws efs delete-file-system --file-system-id $FILE_SYSTEM_ID
# remove efs subnets and endpoints

# remove config and keys?
# remove bucket?
