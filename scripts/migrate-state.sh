#!/usr/bin/env bash
set -euo pipefail

# Migrates all Terraform state from per-project buckets to the shared bucket.
#
# Prerequisites:
#   - AWS credentials with S3 access to all buckets
#
# This script creates the shared bucket if needed, copies state files,
# and does NOT delete from old buckets.

ACCOUNT_ID="559098897826"
NEW_BUCKET="tfstate-${ACCOUNT_ID}"
REGION="us-east-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Ensure shared state bucket exists ---

if ! aws s3api head-bucket --bucket "${NEW_BUCKET}" 2>/dev/null; then
  echo -e "${BOLD}Creating state bucket: ${NEW_BUCKET}${RESET}"
  aws s3api create-bucket --bucket "${NEW_BUCKET}" --region "${REGION}"

  aws s3api put-bucket-versioning --bucket "${NEW_BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption --bucket "${NEW_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

  aws s3api put-public-access-block --bucket "${NEW_BUCKET}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  aws s3api put-bucket-policy --bucket "${NEW_BUCKET}" \
    --policy "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"DenyBareStateKeys\",
          \"Effect\": \"Deny\",
          \"Principal\": \"*\",
          \"Action\": \"s3:PutObject\",
          \"Resource\": [
            \"arn:aws:s3:::${NEW_BUCKET}/terraform.tfstate\",
            \"arn:aws:s3:::${NEW_BUCKET}/.terraform.lock.hcl\"
          ]
        }
      ]
    }"

  echo -e "${GREEN}Bucket created.${RESET}"
else
  echo -e "Bucket ${NEW_BUCKET} already exists."
fi

echo

# --- Copy state files ---

copy_state() {
  local old_bucket="$1"
  local old_key="$2"
  local new_key="$3"

  echo -e "${BOLD}Copying${RESET} s3://${old_bucket}/${old_key} -> s3://${NEW_BUCKET}/${new_key}"

  if aws s3 ls "s3://${old_bucket}/${old_key}" > /dev/null 2>&1; then
    aws s3 cp "s3://${old_bucket}/${old_key}" "s3://${NEW_BUCKET}/${new_key}"
    # Copy lock file if it exists
    aws s3 cp "s3://${old_bucket}/${old_key}.tflock" "s3://${NEW_BUCKET}/${new_key}.tflock" 2>/dev/null || true
    echo -e "${GREEN}Done${RESET}"
  else
    echo -e "${RED}Source not found, skipping${RESET}"
  fi
}

# Platform repos
copy_state "tf-state-boilerplate-${ACCOUNT_ID}" "aws-boilerplate.tfstate"     "platform/control.tfstate"
copy_state "tf-state-vpn-${ACCOUNT_ID}"         "wireguard.tfstate"           "platform/network.tfstate"
copy_state "tf-state-platform-${ACCOUNT_ID}"    "platform-services.tfstate"   "platform/services.tfstate"

# Consumer projects
copy_state "tf-state-websites-${ACCOUNT_ID}"    "ahara-static-websites.tfstate" "projects/websites.tfstate"
copy_state "tf-state-websites-${ACCOUNT_ID}"    "svap.tfstate"                  "projects/svap.tfstate"

echo
echo -e "${GREEN}${BOLD}State files copied.${RESET}"
echo
echo "Next steps:"
echo "  1. Run each project's deploy script (scripts/deploy.sh) — it will"
echo "     pick up the new bucket from its default and re-init automatically."
echo "  2. Verify terraform plan shows no unexpected changes."
echo "  3. Once verified, old buckets can be emptied and deleted."
