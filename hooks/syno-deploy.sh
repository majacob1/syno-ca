#!/usr/bin/env bash
#
# deploy.sh
#
# Upload a certificate to Synology DSM via the WebAPI (DSM 7.x compatible).
# - Usage: ./deploy.sh <CN> <CERT_DIR>
# - Requires: curl, jq
#
# Behavior:
# 1) Logs in to DSM (creates a cookie jar)
# 2) Uploads key/cert/ca via SYNO.Core.Certificate import
# 3) Optionally sets the uploaded certificate as default (set_as_default=1)
# 4) Logs out and cleans up cookie jar
#
# Environment variables (preferred) or interactive prompts:
#   SYNO_HOST    - hostname or IP of Synology (default: localhost)
#   SYNO_PORT    - port (default: 5001)
#   SYNO_USER    - DSM username
#   SYNO_PASS    - DSM password (or leave empty to be prompted)
#   SYNO_OTP     - optional 2FA OTP code if your account requires it
#   INSECURE     - if "1", curl will skip TLS verification (default: 0)
#
# Notes:
# - This script uploads the certificate and requests it be set as default.
# - Adapt authentication and error handling to your environment and security policies.
# - Test carefully on a non-production DSM first.

set -euo pipefail

# --- helpers ---
err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[info] $*"; }

# --- args ---
if [ $# -lt 2 ]; then
  echo "Usage: $0 <CN> <CERT_DIR>"
  exit 2
fi

CN="$1"
CERT_DIR="$2"

# --- env / defaults ---
SYNO_HOST="${SYNO_HOST:-localhost}"
SYNO_PORT="${SYNO_PORT:-5001}"
SYNO_USER="${SYNO_USER:-}"
SYNO_PASS="${SYNO_PASS:-}"
SYNO_OTP="${SYNO_OTP:-}"
INSECURE="${INSECURE:-0}"

# --- check tools ---
command -v curl >/dev/null 2>&1 || err "curl is required"
command -v jq >/dev/null 2>&1 || err "jq is required"

# --- prompt for missing credentials ---
if [ -z "$SYNO_USER" ]; then
  read -r -p "Synology username: " SYNO_USER
fi
if [ -z "$SYNO_PASS" ]; then
  # read -s to avoid echoing password
  read -r -s -p "Synology password: " SYNO_PASS
  echo
fi

# --- files to upload ---
KEY_FILE="${CERT_DIR}/${CN}.key"
CRT_FILE="${CERT_DIR}/${CN}.crt"
# try to find root CA: prefer output/root.crt or parent/root.crt
if [ -f "${CERT_DIR}/root.crt" ]; then
  CA_FILE="${CERT_DIR}/root.crt"
elif [ -f "$(dirname "${CERT_DIR}")/root.crt" ]; then
  CA_FILE="$(dirname "${CERT_DIR}")/root.crt"
else
  CA_FILE=""
fi

[ -f "$KEY_FILE" ] || err "Private key not found: $KEY_FILE"
[ -f "$CRT_FILE" ] || err "Certificate not found: $CRT_FILE"
if [ -n "$CA_FILE" ]; then
  [ -f "$CA_FILE" ] || err "CA file not found: $CA_FILE"
fi

# --- curl options ---
CURL_OPTS=(-sS)
if [ "$INSECURE" = "1" ]; then
  CURL_OPTS+=(-k)
fi

# cookie jar
COOKIE_JAR="$(mktemp -t syno_cookie.XXXX)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# --- login ---
info "Logging in to ${SYNO_HOST}:${SYNO_PORT} as ${SYNO_USER}..."
AUTH_URL="https://${SYNO_HOST}:${SYNO_PORT}/webapi/auth.cgi"
LOGIN_QUERY="?api=SYNO.API.Auth&method=login&version=2"
LOGIN_QUERY="${LOGIN_QUERY}&account=$(printf '%s' "$SYNO_USER" | jq -s -R -r @uri)"
LOGIN_QUERY="${LOGIN_QUERY}&passwd=$(printf '%s' "$SYNO_PASS" | jq -s -R -r @uri)"
LOGIN_QUERY="${LOGIN_QUERY}&session=Core&format=sid"

# include OTP if provided
if [ -n "$SYNO_OTP" ]; then
  LOGIN_QUERY="${LOGIN_QUERY}&otp_code=$(printf '%s' "$SYNO_OTP" | jq -s -R -r @uri)"
fi

LOGIN_URL="${AUTH_URL}${LOGIN_QUERY}"

# perform login, save cookies to cookie jar
LOGIN_RESP="$(curl "${CURL_OPTS[@]}" -c "$COOKIE_JAR" -G "$LOGIN_URL")" || err "Login request failed"
LOGIN_OK="$(printf '%s' "$LOGIN_RESP" | jq -r '.success // false')"
if [ "$LOGIN_OK" != "true" ]; then
  ERR_MSG="$(printf '%s' "$LOGIN_RESP" | jq -r '.error.message // .error // "unknown error")"
  err "Login failed: $ERR_MSG"
fi

SID="$(printf '%s' "$LOGIN_RESP" | jq -r '.data.sid // empty')"
if [ -z "$SID" ]; then
  err "Login succeeded but no session id returned"
fi
info "Login successful (sid: ${SID})."

# --- import certificate ---
info "Uploading certificate for ${CN}..."

ENTRY_URL="https://${SYNO_HOST}:${SYNO_PORT}/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&set_as_default=1"

# Build curl form fields
FORM=(-F "key=@${KEY_FILE}" -F "cert=@${CRT_FILE}")
if [ -n "$CA_FILE" ]; then
  FORM+=(-F "ca=@${CA_FILE}")
fi

# perform upload using cookie jar for authentication
UPLOAD_RESP="$(curl "${CURL_OPTS[@]}" -b "$COOKIE_JAR" "${FORM[@]}" "$ENTRY_URL")" || err "Upload request failed"
UPLOAD_OK="$(printf '%s' "$UPLOAD_RESP" | jq -r '.success // false')"
if [ "$UPLOAD_OK" != "true" ]; then
  ERR_MSG="$(printf '%s' "$UPLOAD_RESP" | jq -r '.error.message // .error // "unknown error")"
  err "Certificate upload failed: $ERR_MSG"
fi

info "Certificate uploaded successfully."

# Optionally, parse returned data for cert id
CERT_ID="$(printf '%s' "$UPLOAD_RESP" | jq -r '.data.cert_id // empty')"
if [ -n "$CERT_ID" ]; then
  info "Uploaded certificate id: $CERT_ID"
fi

# --- optional: set certificate for services (example) ---
# The API to assign a certificate to a specific DSM service may vary by DSM version.
# You can list certificates and set defaults via SYNO.Core.Certificate methods if needed.
# For safety, this script only uploads and sets as default during import (set_as_default=1).
# If you need to assign to specific services, implement additional API calls here.

# --- logout ---
info "Logging out..."
LOGOUT_URL="https://${SYNO_HOST}:${SYNO_PORT}/webapi/auth.cgi?api=SYNO.API.Auth&method=logout&version=1&session=Core"
LOGOUT_RESP="$(curl "${CURL_OPTS[@]}" -b "$COOKIE_JAR" -G "$LOGOUT_URL")" || true
# ignore logout errors, but print if present
LOGOUT_OK="$(printf '%s' "$LOGOUT_RESP" | jq -r '.success // false' 2>/dev/null || echo "false")"
if [ "$LOGOUT_OK" = "true" ]; then
  info "Logged out."
else
  info "Logout response: $LOGOUT_RESP"
fi

info "Done."
exit 0

