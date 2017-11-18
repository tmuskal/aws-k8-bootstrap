#! /bin/bash
kops="kops"
aws="aws"
jq="jq"
$aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID | $jq '.MountTargets[].MountTargetId' | xargs -n 1 $aws efs delete-mount-target --mount-target-id
$kops delete cluster $NAME --yes

# remove efs
FILE_SYSTEM_ID=`$aws efs describe-file-systems --creation-token $NAME | $jq '.FileSystems[0].FileSystemId' -r`
$aws efs delete-file-system --file-system-id $FILE_SYSTEM_ID

# remove config and keys?
# remove bucket?
