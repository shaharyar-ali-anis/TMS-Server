#!/usr/bin/env bash
#
# TMS SSL Runbook — Step 2: generate the internal CA and server certificate.
# Ref: claude/ssl_implementation_plan.md, section 2.
#
# Usage:
#   sudo SERVER_IP=100.49.251.138 ./02_generate_certs.sh
#   # or just edit the default below and run: sudo ./02_generate_certs.sh
#
# Idempotency: safe to re-run. It regenerates the leaf cert/key each time but
# reuses the existing CA if ca.key/ca.crt are already present, so re-running
# does NOT invalidate certs a client machine has already trusted.

set -euo pipefail

SERVER_IP="${SERVER_IP:-100.49.251.138}"
CERT_DIR="${CERT_DIR:-/opt/hazen-stack/nginx/certs}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo). Exiting." >&2
  exit 1
fi

echo "== TMS SSL: generating certs for SERVER_IP=${SERVER_IP} in ${CERT_DIR} =="

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# --- 2.1 Root CA (10 year validity). Skip if it already exists. -------------
if [[ -f ca.key && -f ca.crt ]]; then
  echo "-- CA already exists, reusing it (existing client trust stays valid)"
else
  echo "-- Generating root CA"
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/C=SA/O=Hazen.ai/OU=TMS/CN=Hazen TMS Internal Root CA" \
    -out ca.crt
fi

# --- 2.2 Server key + CSR with IP SAN ---------------------------------------
echo "-- Writing server.cnf"
cat > server.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
distinguished_name = dn
req_extensions     = req_ext

[dn]
C  = SA
O  = Hazen.ai
OU = TMS
CN = ${SERVER_IP}

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = ${SERVER_IP}
EOF

echo "-- Generating server key + CSR"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -config server.cnf

# --- 2.3 Sign the leaf (398 days — safe default even though this deployment
#          is Windows/Chrome/Edge only and not Apple-constrained) ------------
echo "-- Writing server.ext"
cat > server.ext <<EOF
basicConstraints     = CA:FALSE
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth
subjectAltName       = @alt_names

[alt_names]
IP.1 = ${SERVER_IP}
EOF

echo "-- Signing leaf certificate"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 398 -sha256 -extfile server.ext

# --- 2.4 Filenames nginx expects, lock permissions --------------------------
cp server.crt server-cert.pem
cp server.key server-key.pem

chown root:root "$CERT_DIR"/*
chmod 600 "$CERT_DIR"/*.key "$CERT_DIR"/server-key.pem
chmod 644 "$CERT_DIR"/ca.crt "$CERT_DIR"/server-cert.pem

# --- 2.5 Verify --------------------------------------------------------------
echo ""
echo "== Verification =="

echo -n "SAN entry:      "
openssl x509 -in server-cert.pem -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | xargs

echo -n "Chain check:     "
openssl verify -CAfile ca.crt server-cert.pem

CERT_MD5=$(openssl x509 -noout -modulus -in server-cert.pem | openssl md5)
KEY_MD5=$(openssl rsa  -noout -modulus -in server-key.pem  | openssl md5)
echo "Cert modulus md5: $CERT_MD5"
echo "Key  modulus md5: $KEY_MD5"

if [[ "$CERT_MD5" == "$KEY_MD5" ]]; then
  echo "Key/cert pair MATCH — good."
else
  echo "!! Key/cert pair MISMATCH — do not proceed, re-run this script." >&2
  exit 1
fi

echo ""
echo "== Done. Never copy ca.key, server.key, or server-key.pem off this host =="
echo "== Only ${CERT_DIR}/ca.crt goes to client machines =="
