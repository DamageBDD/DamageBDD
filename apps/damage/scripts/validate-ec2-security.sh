#!/usr/bin/env bash
set -euo pipefail

: "${INSTANCE_ID:?INSTANCE_ID is required}"
: "${EXPECTED_INSTANCE_PROFILE_ARN:?EXPECTED_INSTANCE_PROFILE_ARN is required}"
: "${EXPECTED_ROLE_NAME:?EXPECTED_ROLE_NAME is required}"
EXPECTED_HOP_LIMIT="${EXPECTED_HOP_LIMIT:-1}"

instance_json=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --output json)

jq -e \
  --arg profile "$EXPECTED_INSTANCE_PROFILE_ARN" \
  --argjson hop "$EXPECTED_HOP_LIMIT" '
  .Reservations[0].Instances[0] as $i
  | ($i.MetadataOptions.State == "applied")
    and ($i.MetadataOptions.HttpEndpoint == "enabled")
    and ($i.MetadataOptions.HttpTokens == "required")
    and ($i.MetadataOptions.HttpPutResponseHopLimit == $hop)
    and ($i.MetadataOptions.InstanceMetadataTags == "disabled")
    and ($i.IamInstanceProfile.Arn == $profile)
    and ($i.PublicIpAddress == null)
  ' <<<"$instance_json" >/dev/null

profile_name=${EXPECTED_INSTANCE_PROFILE_ARN##*/}
profile_json=$(aws iam get-instance-profile \
  --instance-profile-name "$profile_name" \
  --output json)

jq -e --arg role "$EXPECTED_ROLE_NAME" '
  (.InstanceProfile.Roles | length) == 1
  and .InstanceProfile.Roles[0].RoleName == $role
' <<<"$profile_json" >/dev/null

jq -n \
  --arg instance_id "$INSTANCE_ID" \
  --arg role "$EXPECTED_ROLE_NAME" \
  --arg profile "$EXPECTED_INSTANCE_PROFILE_ARN" \
  --argjson hop "$EXPECTED_HOP_LIMIT" \
  '{result:"ok",instance_id:$instance_id,role:$role,
    instance_profile:$profile,http_tokens:"required",hop_limit:$hop,
    metadata_tags:"disabled",public_ipv4:false}'
