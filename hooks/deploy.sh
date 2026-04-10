#!/bin/bash
CN="$1"
CERT_DIR="$2"
echo "[deploy] CN=${CN}, dir=${CERT_DIR}"
# Here you could:
# - scp "${CERT_DIR}/${CN}.crt" and "${CERT_DIR}/${CN}.key" to another host
# - call Synology API to import the cert

