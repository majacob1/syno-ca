#!/bin/bash
set -e

BASE_DIR=$(cd "$(dirname "$0")" && pwd)
CA_DIR="${BASE_DIR}/ca"
WORK_DIR="${BASE_DIR}/work"
OUT_DIR="${BASE_DIR}/output"
HOOK_DIR="${BASE_DIR}/hooks"

mkdir -p "$CA_DIR" "$WORK_DIR" "$OUT_DIR" "$HOOK_DIR"

CONFIG_FILE=""
RENEW_THRESHOLD_DAYS=""

if [[ "$1" == "--config" ]]; then
  CONFIG_FILE="$2"
  shift 2
fi

if [[ "$1" == "--renew" ]]; then
  RENEW_THRESHOLD_DAYS="$2"
  shift 2
fi

if [[ -n "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE"
  exit 1
fi

#Export RANDFILE so OpenSSL uses that file
export RANDFILE=/tmp/.rnd
if [ ! -f "$RANDFILE" ]; then
  head -c 512 /dev/urandom > "$RANDFILE"
  chmod 600 "$RANDFILE"
fi


json() {
  jq -r "$1" "$CONFIG_FILE"
}

run_hook() {
  local hook="$1"
  if [[ -x "${HOOK_DIR}/${hook}.sh" ]]; then
    "${HOOK_DIR}/${hook}.sh" "$@"
  fi
}

lint_certificate() {
  local cert="$1"
  local ca="$2"

  echo "Linting certificate: $cert"

  if ! openssl x509 -noout -text -in "$cert" >/dev/null 2>&1; then
    echo "❌ Invalid certificate structure"
    return 1
  fi

  if ! openssl verify -CAfile "$ca" "$cert" >/dev/null 2>&1; then
    echo "❌ Certificate does NOT verify against CA"
    return 1
  fi

  if ! openssl x509 -noout -text -in "$cert" | grep -q "Subject Alternative Name"; then
    echo "❌ Missing SAN extension"
    return 1
  fi

  echo "✔ Certificate passed linting"
}

decrypt_ca_key_if_needed() {
  local ENC_KEY="${CA_DIR}/root.key.enc"
  local DEC_KEY="${CA_DIR}/root.key"

  if [[ -f "$DEC_KEY" ]]; then
    return 0
  fi

  if [[ ! -f "$ENC_KEY" ]]; then
    return 0
  fi

  echo "Encrypted CA key found. Unlock required."
  read -s -p "Enter CA key password: " CAPASS
  echo

  openssl pkey -in "$ENC_KEY" -passin pass:"$CAPASS" -out "$DEC_KEY"
  chmod 600 "$DEC_KEY"
}

maybe_reencrypt_ca_key() {
  local ENC_KEY="${CA_DIR}/root.key.enc"
  local DEC_KEY="${CA_DIR}/root.key"

  if [[ ! -f "$ENC_KEY" && -f "$DEC_KEY" ]]; then
    echo "Encrypting CA key for the first time..."
    read -s -p "Set password for CA key: " CAPASS1
    echo
    read -s -p "Repeat password: " CAPASS2
    echo
    if [[ "$CAPASS1" != "$CAPASS2" ]]; then
      echo "Passwords do not match."
      exit 1
    fi
    openssl pkey -aes256 -in "$DEC_KEY" -out "$ENC_KEY" -passout pass:"$CAPASS1"
    chmod 600 "$ENC_KEY"
    echo "Encrypted CA key stored at $ENC_KEY"
    echo "You can delete $DEC_KEY to keep CA locked."
  fi
}

create_or_import_ca() {
  local DEC_KEY="${CA_DIR}/root.key"
  local ENC_KEY="${CA_DIR}/root.key.enc"
  local CA_CRT="${CA_DIR}/root.crt"

  if [[ -n "$CONFIG_FILE" ]]; then
    local CREATE_NEW
    CREATE_NEW=$(json '.root_ca.create_new')
    local CA_CN
    CA_CN=$(json '.root_ca.common_name')

    if [[ "$CREATE_NEW" == "true" ]]; then
      echo "Creating new Ed25519 Root CA..."
      openssl genpkey -algorithm ED25519 -out "$DEC_KEY"
      openssl req -x509 -key "$DEC_KEY" -out "$CA_CRT" -days 3650 -sha512 -subj "/CN=${CA_CN}"
      maybe_reencrypt_ca_key
    else
      local RK RC
      RK=$(json '.root_ca.root_key')
      RC=$(json '.root_ca.root_crt')
      cp "$RK" "$DEC_KEY"
      cp "$RC" "$CA_CRT"
      maybe_reencrypt_ca_key
    fi
  else
    echo "Root CA setup:"
    echo "1) Create new CA"
    echo "2) Use existing CA"
    read -p "Choose: " choice
    if [[ "$choice" == "1" ]]; then
      read -p "Enter CA CN: " CA_CN
      openssl genpkey -algorithm ED25519 -out "$DEC_KEY"
      openssl req -x509 -key "$DEC_KEY" -out "$CA_CRT" -days 3650 -sha512 -subj "/CN=${CA_CN}"
      maybe_reencrypt_ca_key
    else
      read -p "Path to root.key (decrypted or encrypted): " RK
      read -p "Path to root.crt: " RC
      if openssl pkey -in "$RK" -noout >/dev/null 2>&1; then
        cp "$RK" "$DEC_KEY"
      else
        cp "$RK" "${CA_DIR}/root.key.enc"
        decrypt_ca_key_if_needed
      fi
      cp "$RC" "$CA_CRT"
      maybe_reencrypt_ca_key
    fi
  fi

  [[ -f "${CA_DIR}/index.txt" ]] || touch "${CA_DIR}/index.txt"
  [[ -f "${CA_DIR}/serial" ]] || echo "1000" > "${CA_DIR}/serial"
}

issue_certificate() {
  local CN="$1"
  local SANLIST="$2"
  local DAYS="$3"

  local CERT_DIR="${OUT_DIR}/${CN}"
  mkdir -p "$CERT_DIR" "${CERT_DIR}/archive"

  local SANBLOCK="DNS.1 = ${CN}\n"
  local i=2

  if [[ "$CN" != \*.* ]]; then
    local domain
    domain=$(echo "$CN" | sed 's/^[^.]*\.//')
    SANBLOCK+="DNS.${i} = *.${domain}\n"
    ((i++))
  fi

  for san in $SANLIST; do
    SANBLOCK+="DNS.${i} = ${san}\n"
    ((i++))
  done

  cat > "${WORK_DIR}/san.cnf" <<EOF
[ req ]
distinguished_name = dn
req_extensions = req_ext
prompt = no

[ dn ]
CN = ${CN}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
${SANBLOCK}
EOF

  local KEY="${CERT_DIR}/${CN}.key"
  local CRT="${CERT_DIR}/${CN}.crt"
  local CA_CRT="${CA_DIR}/root.crt"

  if [[ -f "$CRT" ]]; then
    local TS
    TS=$(date +"%Y%m%d-%H%M%S")
    cp "$CRT" "${CERT_DIR}/archive/${CN}-${TS}.crt"
    cp "$KEY" "${CERT_DIR}/archive/${CN}-${TS}.key"
  fi

  run_hook "pre-renew" "$CN" "$CERT_DIR"

  openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"
  openssl req -new -key "$KEY" -out "${WORK_DIR}/req.csr" -config "${WORK_DIR}/san.cnf"

  openssl x509 -req \
    -in "${WORK_DIR}/req.csr" \
    -CA "$CA_CRT" -CAkey "${CA_DIR}/root.key" \
    -CAserial "${CA_DIR}/serial" \
    -out "$CRT" \
    -days "$DAYS" -sha512 \
    -extfile "${WORK_DIR}/san.cnf" -extensions req_ext

  cp "$CA_CRT" "${OUT_DIR}/root.crt"

  lint_certificate "$CRT" "${OUT_DIR}/root.crt"

  run_hook "post-renew" "$CN" "$CERT_DIR"
  run_hook "deploy" "$CN" "$CERT_DIR"

  echo "Issued certificate for ${CN}:"
  echo "  Key:  ${KEY}"
  echo "  Cert: ${CRT}"
}

needs_renewal() {
  local CRT="$1"
  local THRESHOLD_DAYS="$2"

  if [[ ! -f "$CRT" ]]; then
    return 0
  fi

  local end_date
  end_date=$(openssl x509 -enddate -noout -in "$CRT" | cut -d= -f2)
  local end_ts
  end_ts=$(date -d "$end_date" +%s)
  local now_ts
  now_ts=$(date +%s)
  local diff_days=$(( (end_ts - now_ts) / 86400 ))

  if (( diff_days <= THRESHOLD_DAYS )); then
    return 0
  else
    return 1
  fi
}

create_or_import_ca
decrypt_ca_key_if_needed

if [[ -n "$CONFIG_FILE" ]]; then
  local_count=$(json '.certificates | length')
  for ((i=0; i<local_count; i++)); do
    CN=$(json ".certificates[$i].cn")
    SANLIST=$(json ".certificates[$i].sans[]?" | tr '\n' ' ')
    DAYS=$(json ".certificates[$i].days")

    local CERT_DIR="${OUT_DIR}/${CN}"
    local CRT="${CERT_DIR}/${CN}.crt"

    if [[ -n "$RENEW_THRESHOLD_DAYS" ]]; then
      if needs_renewal "$CRT" "$RENEW_THRESHOLD_DAYS"; then
        issue_certificate "$CN" "$SANLIST" "$DAYS"
      else
        echo "Skipping ${CN}, not yet within renewal window."
      fi
    else
      issue_certificate "$CN" "$SANLIST" "$DAYS"
    fi
  done

  AUTO_ENABLED=$(json '.auto_renew.enabled')
  if [[ "$AUTO_ENABLED" == "true" && -z "$RENEW_THRESHOLD_DAYS" ]]; then
    CRON_TIME=$(json '.auto_renew.cron_time')
    RENEW_DAYS=$(json '.auto_renew.renew_days_before_expiry')
    echo
    echo "Suggested crontab entry for auto-renewal:"
    echo "${CRON_TIME} cd ${BASE_DIR} && ./syno-ca.sh --config ${CONFIG_FILE} --renew ${RENEW_DAYS} >/dev/null 2>&1"
  fi
else
  while true; do
    read -p "CN: " CN
    read -p "SANs (comma-separated): " SANLIST
    read -p "Days (default 825): " DAYS
    DAYS=${DAYS:-825}
    SANLIST=$(echo "$SANLIST" | tr ',' ' ')
    issue_certificate "$CN" "$SANLIST" "$DAYS"
    read -p "Issue another? (y/n): " again
    [[ "$again" == "y" ]] || break
  done
fi

echo "Done."
