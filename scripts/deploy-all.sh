#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${HOME}/src"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

deploy() {
  local name="$1"
  local dir="${SRC_DIR}/${name}"

  if [ ! -d "${dir}" ]; then
    echo -e "${RED}ERROR: ${dir} not found${RESET}" >&2
    return 1
  fi

  if [ ! -f "${dir}/scripts/deploy.sh" ]; then
    echo -e "${RED}ERROR: ${dir}/scripts/deploy.sh not found${RESET}" >&2
    return 1
  fi

  echo -e "${BOLD}[${name}]${RESET} Deploying..."
  (cd "${dir}" && bash scripts/deploy.sh)
  echo -e "${GREEN}[${name}]${RESET} Done."
  echo
}

echo -e "${BOLD}=== Platform Deploy ===${RESET}"
echo

# Layer 0: Control plane (IAM roles, state buckets, GitHub secrets)
deploy platform-control

# Layer 1: Infrastructure (VPC, ALB, VPN)
deploy platform-network

# Layer 2: Shared services (Cognito, RDS, observability)
deploy platform-services

echo -e "${GREEN}${BOLD}All platform layers deployed.${RESET}"
