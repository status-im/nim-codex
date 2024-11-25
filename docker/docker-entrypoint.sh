#!/bin/bash

# Environment variables from files
# If set to file path, read the file and export the variables
# If set to directory path, read all files in the directory and export the variables
if [[ -n "${ENV_PATH}" ]]; then
  set -a
  [[ -f "${ENV_PATH}" ]] && source "${ENV_PATH}" || for f in "${ENV_PATH}"/*; do source "$f"; done
  set +a
fi

# Parameters
if [[ -z "${CODEX_NAT}" ]]; then
  if [[ "${NAT_IP_AUTO}" == "true" && -z "${NAT_PUBLIC_IP_AUTO}" ]]; then
    export CODEX_NAT=$(hostname --ip-address)
    echo "Private: CODEX_NAT=${CODEX_NAT}"
  elif [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
    # Run for 60 seconds if fail
    WAIT=120
    SECONDS=0
    SLEEP=5
    while (( SECONDS < WAIT )); do
      export CODEX_NAT=$(curl -s -f -m 5 "${NAT_PUBLIC_IP_AUTO}")
      # Check if exit code is 0 and returned value is not empty
      if [[ $? -eq 0 && -n "${CODEX_NAT}" ]]; then
        echo "Public: CODEX_NAT=${CODEX_NAT}"
        break
      else
        # Sleep and check again
        echo "Can't get Public IP - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
        sleep $SLEEP
      fi
    done
  fi
fi

# Stop Codex run if can't get NAT IP when requested
if [[ "${NAT_IP_AUTO}" == "true" && -z "${CODEX_NAT}" ]]; then
  echo "Can't get Private IP - Stop Codex run"
  exit 1
elif [[ -n "${NAT_PUBLIC_IP_AUTO}" && -z "${CODEX_NAT}" ]]; then
  echo "Can't get Public IP in $WAIT seconds - Stop Codex run"
  exit 1
fi

# If marketplace is enabled from the testing environment,
# The file has to be written before Codex starts.
for key in PRIV_KEY ETH_PRIVATE_KEY; do
  keyfile="private.key"
  if [[ -n "${!key}" ]]; then
    [[ "${key}" == "PRIV_KEY" ]] && echo "PRIV_KEY variable is deprecated and will be removed in the next releases, please use ETH_PRIVATE_KEY instead!"
    echo "${!key}" > "${keyfile}"
    chmod 600 "${keyfile}"
    export CODEX_ETH_PRIVATE_KEY="${keyfile}"
    echo "Private key set"
  fi
done

# Circuit downloader
# cirdl [circuitPath] [rpcEndpoint] [marketplaceAddress]
if [[ "$@" == *"prover"* ]]; then
  echo "Prover is enabled - Run Circuit downloader"

  # Set variables required by cirdl from command line arguments when passed
  for arg in data-dir circuit-dir eth-provider marketplace-address; do
    arg_value=$(grep -o "${arg}=[^ ,]\+" <<< $@ | awk -F '=' '{print $2}')
    if [[ -n "${arg_value}" ]]; then
      var_name=$(tr '[:lower:]' '[:upper:]' <<< "CODEX_${arg//-/_}")
      export "${var_name}"="${arg_value}"
    fi
  done

  # Set circuit dir from CODEX_CIRCUIT_DIR variables if set
  if [[ -z "${CODEX_CIRCUIT_DIR}" ]]; then
    export CODEX_CIRCUIT_DIR="${CODEX_DATA_DIR}/circuits"
  fi

  # Download circuit
  mkdir -p "${CODEX_CIRCUIT_DIR}"
  chmod 700 "${CODEX_CIRCUIT_DIR}"
  download="cirdl ${CODEX_CIRCUIT_DIR} ${CODEX_ETH_PROVIDER} ${CODEX_MARKETPLACE_ADDRESS}"
  echo "${download}"
  eval "${download}"
  [[ $? -ne 0 ]] && { echo "Failed to download circuit files"; exit 1; }
fi

# Run
echo "Run Codex node"
exec "$@"
