#! /bin/bash
kops delete cluster $NAME --yes

# remove efs
FILE_SYSTEM_ID=`aws efs describe-file-systems --creation-token $NAME | $jq '.FileSystems[0].FileSystemId' -r`

# remove bucket
