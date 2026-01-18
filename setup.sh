#!/bin/sh
set -e

###############################################################################
# ENV-DRIVEN NGINX REVERSE PROXY GENERATOR
# FINAL VERSION – OPTION C (FULL DEBUGGING & PERFORMANCE)
###############################################################################

###############################################################################
# Helpers
###############################################################################
error() {
  echo "[ERROR] $1" >&2
  exit 1
}

info() {
  echo "[INFO]  $1"
}

###############################################################################
# Load ENV (PATH SAFE)
###############################################################################
[ ! -f ".env" ] && error ".env file not found"

ORIGINAL_PATH="$PATH"
# shellcheck disable=SC1091
. ./.env
PATH="$ORIGINAL_PATH"
export PATH

command -v docker >/dev/null || error "docker command not found"
command -v mkdir  >/dev/null || error "mkdir command not found"
command -v cat    >/dev/null || error "cat command not found"

###############################################################################
# Required Global ENV
###############################################################################
: "${SERVICE_COUNT:?SERVICE_COUNT is required}"

: "${NGINX_WORKER_PROCESSES:?}"
: "${NGINX_WORKER_CONNECTIONS:?}"
: "${NGINX_KEEPALIVE_TIMEOUT:?}"
: "${NGINX_CLIENT_MAX_BODY_SIZE:?}"

: "${NGINX_PROXY_READ_TIMEOUT:?}"
: "${NGINX_PROXY_CONNECT_TIMEOUT:?}"
: "${NGINX_PROXY_SEND_TIMEOUT:?}"

: "${NGINX_LOG_MODE:?}"                # file | stdout
: "${NGINX_ERROR_LOG_LEVEL:?}"          # debug|info|warn|error
: "${NGINX_GLOBAL_ACCESS_LOG:?}"        # true|false
: "${NGINX_GLOBAL_ERROR_LOG:?}"         # true|false
: "${NGINX_LOG_BASE_PATH:?}"

: "${NGINX_RATE_LIMIT_ENABLED:?}"
: "${NGINX_RATE_LIMIT_ZONE_NAME:?}"
: "${NGINX_RATE_LIMIT_RATE:?}"
: "${NGINX_RATE_LIMIT_BURST:?}"

: "${CERTBOT_ENABLED:?}"
: "${CERTBOT_RENEW_ENABLED:?}"

[ "$CERTBOT_ENABLED" = "true" ] && : "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"

NGINX_NETWORK="${NGINX_NETWORK:-shared-net}"

###############################################################################
# Ensure Docker network exists (IDEMPOTENT)
###############################################################################
if ! docker network inspect "$NGINX_NETWORK" >/dev/null 2>&1; then
  info "Creating docker network: $NGINX_NETWORK"
  docker network create "$NGINX_NETWORK"
else
  info "Docker network already exists: $NGINX_NETWORK"
fi

###############################################################################
# Prepare output directories
###############################################################################
OUT="generated"
NGX_ROOT="$OUT/nginx"
NGX_CONF="$NGX_ROOT/conf.d"

rm -rf "$OUT"
mkdir -p "$NGX_CONF"

###############################################################################
# Logging directories (AUTO CREATE + FAIL FAST)
###############################################################################
if [ "$NGINX_LOG_MODE" = "file" ]; then
  mkdir -p "$NGINX_LOG_BASE_PATH" \
    || error "Cannot create log directory: $NGINX_LOG_BASE_PATH"
fi

###############################################################################
# nginx.conf (GLOBAL)
###############################################################################
cat > "$NGX_ROOT/nginx.conf" <<EOF
user nginx;
worker_processes ${NGINX_WORKER_PROCESSES};

events {
  worker_connections ${NGINX_WORKER_CONNECTIONS};
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;

  keepalive_timeout ${NGINX_KEEPALIVE_TIMEOUT};
  client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

  proxy_connect_timeout ${NGINX_PROXY_CONNECT_TIMEOUT};
  proxy_read_timeout    ${NGINX_PROXY_READ_TIMEOUT};
  proxy_send_timeout    ${NGINX_PROXY_SEND_TIMEOUT};

  log_format main
    '\$remote_addr - \$host [\$time_local] "\$request" '
    '\$status \$body_bytes_sent rt=\$request_time';

EOF

# --- Global Logging ---
if [ "$NGINX_LOG_MODE" = "file" ]; then
  [ "$NGINX_GLOBAL_ACCESS_LOG" = "true" ] && \
    echo "  access_log ${NGINX_LOG_BASE_PATH}/access.log main;" >> "$NGX_ROOT/nginx.conf"

  [ "$NGINX_GLOBAL_ERROR_LOG" = "true" ] && \
    echo "  error_log  ${NGINX_LOG_BASE_PATH}/error.log ${NGINX_ERROR_LOG_LEVEL};" >> "$NGX_ROOT/nginx.conf"
else
  [ "$NGINX_GLOBAL_ACCESS_LOG" = "true" ] && \
    echo "  access_log /dev/stdout main;" >> "$NGX_ROOT/nginx.conf"

  [ "$NGINX_GLOBAL_ERROR_LOG" = "true" ] && \
    echo "  error_log  /dev/stderr ${NGINX_ERROR_LOG_LEVEL};" >> "$NGX_ROOT/nginx.conf"
fi

# --- Rate limit zone ---
if [ "$NGINX_RATE_LIMIT_ENABLED" = "true" ]; then
cat >> "$NGX_ROOT/nginx.conf" <<EOF
  limit_req_zone \$binary_remote_addr
    zone=${NGINX_RATE_LIMIT_ZONE_NAME}:10m
    rate=${NGINX_RATE_LIMIT_RATE};
EOF
fi

cat >> "$NGX_ROOT/nginx.conf" <<EOF

  include /etc/nginx/conf.d/*.conf;
}
EOF

###############################################################################
# HTTP DEFAULT SERVER (PATH ROUTING)
###############################################################################
HAS_ROOT_PATH="false"

cat > "$NGX_CONF/00-http.conf" <<EOF
server {
  listen 80 default_server;
  server_name _;

  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }
EOF

i=1
while [ "$i" -le "$SERVICE_COUNT" ]; do
  eval NAME=\$SERVICE_${i}_NAME
  eval PATH_ROUTE=\$SERVICE_${i}_PATH
  eval PORT=\$SERVICE_${i}_PORT
  eval RATE=\$SERVICE_${i}_RATE_LIMIT

  [ -z "$NAME" ] && error "SERVICE_${i}_NAME missing"
  [ -z "$PORT" ] && error "SERVICE_${i}_PORT missing"
  [ -z "$PATH_ROUTE" ] && { i=$((i+1)); continue; }

  [ "$PATH_ROUTE" = "/" ] && HAS_ROOT_PATH="true"

  RATE_LINE=""
  if [ "$NGINX_RATE_LIMIT_ENABLED" = "true" ] && [ "$RATE" = "true" ]; then
    RATE_LINE="limit_req zone=${NGINX_RATE_LIMIT_ZONE_NAME} burst=${NGINX_RATE_LIMIT_BURST};"
  fi

cat >> "$NGX_CONF/00-http.conf" <<EOF

  location $PATH_ROUTE {
    $RATE_LINE
    proxy_pass http://$NAME:$PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto http;
  }
EOF

  i=$((i+1))
done

if [ "$HAS_ROOT_PATH" != "true" ]; then
cat >> "$NGX_CONF/00-http.conf" <<EOF

  location / {
    default_type text/plain;
    return 200 "reverse-proxy: ok\n";
  }
EOF
fi

cat >> "$NGX_CONF/00-http.conf" <<EOF
}
EOF

###############################################################################
# DOMAIN ROUTING (HTTP / HTTPS) + PER-SERVICE LOGGING
###############################################################################
CERTBOT_DOMAINS=""
CERTBOT_RENEW_DOMAINS=""

i=1
while [ "$i" -le "$SERVICE_COUNT" ]; do
  eval NAME=\$SERVICE_${i}_NAME
  eval DOMAIN=\$SERVICE_${i}_DOMAIN
  eval PORT=\$SERVICE_${i}_PORT
  eval SSL=\$SERVICE_${i}_SSL
  eval RATE=\$SERVICE_${i}_RATE_LIMIT

  eval ACCESS_LOG=\$SERVICE_${i}_ACCESS_LOG
  eval ERROR_LOG=\$SERVICE_${i}_ERROR_LOG
  eval LOG_PATH=\$SERVICE_${i}_LOG_PATH

  eval CERT_RENEW=\$SERVICE_${i}_CERTBOT_RENEW

  [ -z "$DOMAIN" ] && { i=$((i+1)); continue; }

  # --- per-service log dir ---
  if [ "$NGINX_LOG_MODE" = "file" ] && \
     { [ "$ACCESS_LOG" = "true" ] || [ "$ERROR_LOG" = "true" ]; }; then
    mkdir -p "$LOG_PATH" \
      || error "Cannot create log directory: $LOG_PATH"
  fi

  RATE_LINE=""
  if [ "$NGINX_RATE_LIMIT_ENABLED" = "true" ] && [ "$RATE" = "true" ]; then
    RATE_LINE="limit_req zone=${NGINX_RATE_LIMIT_ZONE_NAME} burst=${NGINX_RATE_LIMIT_BURST};"
  fi

  ACCESS_LOG_LINE=""
  ERROR_LOG_LINE=""

  if [ "$NGINX_LOG_MODE" = "file" ]; then
    [ "$ACCESS_LOG" = "true" ] && ACCESS_LOG_LINE="access_log $LOG_PATH/access.log main;"
    [ "$ERROR_LOG"  = "true" ] && ERROR_LOG_LINE="error_log  $LOG_PATH/error.log ${NGINX_ERROR_LOG_LEVEL};"
  else
    [ "$ACCESS_LOG" = "true" ] && ACCESS_LOG_LINE="access_log /dev/stdout main;"
    [ "$ERROR_LOG"  = "true" ] && ERROR_LOG_LINE="error_log  /dev/stderr ${NGINX_ERROR_LOG_LEVEL};"
  fi

  if [ "$SSL" = "true" ]; then
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $DOMAIN"
    [ "$CERT_RENEW" = "true" ] && CERTBOT_RENEW_DOMAINS="$CERTBOT_RENEW_DOMAINS -d $DOMAIN"
  fi

cat > "$NGX_CONF/${DOMAIN}.conf" <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  ${ACCESS_LOG_LINE}
  ${ERROR_LOG_LINE}

EOF

if [ "$SSL" = "true" ]; then
cat >> "$NGX_CONF/${DOMAIN}.conf" <<EOF
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl;
  server_name $DOMAIN;

  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  ${ACCESS_LOG_LINE}
  ${ERROR_LOG_LINE}
EOF
fi

cat >> "$NGX_CONF/${DOMAIN}.conf" <<EOF
  location / {
    $RATE_LINE
    proxy_pass http://$NAME:$PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto ${SSL:+https}${SSL:=http};
  }
}
EOF

  i=$((i+1))
done

###############################################################################
# docker-compose.yml
###############################################################################
cat > "$OUT/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ${NGINX_LOG_BASE_PATH}:${NGINX_LOG_BASE_PATH}
      - certbot-etc:/etc/letsencrypt
      - certbot-www:/var/www/certbot
    networks:
      - ${NGINX_NETWORK}
EOF

if [ "$CERTBOT_ENABLED" = "true" ] && [ -n "$CERTBOT_DOMAINS" ]; then
cat >> "$OUT/docker-compose.yml" <<EOF

  certbot:
    image: certbot/certbot
    command: certonly --webroot
      --webroot-path=/var/www/certbot
      --agree-tos --no-eff-email
      -m ${CERTBOT_EMAIL}
      ${CERTBOT_DOMAINS}
    volumes:
      - certbot-etc:/etc/letsencrypt
      - certbot-www:/var/www/certbot
    networks:
      - ${NGINX_NETWORK}
EOF
fi

if [ "$CERTBOT_RENEW_ENABLED" = "true" ] && [ -n "$CERTBOT_RENEW_DOMAINS" ]; then
cat >> "$OUT/docker-compose.yml" <<EOF

  certbot-renew:
    image: certbot/certbot
    entrypoint: /bin/sh -c
    command: |
      while true; do
        certbot renew --quiet;
        sleep 12h;
      done
    volumes:
      - certbot-etc:/etc/letsencrypt
      - certbot-www:/var/www/certbot
    networks:
      - ${NGINX_NETWORK}
EOF
fi

cat >> "$OUT/docker-compose.yml" <<EOF

networks:
  ${NGINX_NETWORK}:
    external: true

volumes:
  certbot-etc:
  certbot-www:
EOF

###############################################################################
# Final instructions
###############################################################################
echo ""
echo "========================================"
echo " SETUP COMPLETE (FINAL VERSION)"
echo "========================================"
echo "Docker network : ${NGINX_NETWORK}"
echo ""
echo "Next steps:"
echo "  cd generated"
echo "  docker compose up -d"
echo ""
