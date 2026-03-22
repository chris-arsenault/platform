#!/usr/bin/env bash
set -euo pipefail

# Migrates all Terraform state from per-project buckets to the shared bucket.
#
# Prerequisites:
#   - AWS credentials with S3 access to all buckets
#   - platform-control has been applied (creates the shared bucket)
#
# This script copies state files, it does NOT delete from old buckets.

ACCOUNT_ID="559098897826"
NEW_BUCKET="tfstate-${ACCOUNT_ID}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

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

echo -e "${BOLD}=== State Migration ===${RESET}"
echo -e "Target bucket: ${NEW_BUCKET}"
echo

# Verify the new bucket exists
if ! aws s3 ls "s3://${NEW_BUCKET}" > /dev/null 2>&1; then
  echo -e "${RED}ERROR: ${NEW_BUCKET} does not exist. Apply platform-control first.${RESET}"
  exit 1
fi

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
echo "  1. In each project, run: terraform init -reconfigure -backend-config bucket=${NEW_BUCKET}"
echo "  2. Run: terraform plan  (should show no changes)"
echo "  3. Once verified, old buckets can be emptied and deleted"
