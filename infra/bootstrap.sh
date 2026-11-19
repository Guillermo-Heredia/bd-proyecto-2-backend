#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/turbinas-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -Is) turbinas bootstrap ==="

: "${REPO_URL:?Falta REPO_URL}"
: "${REPO_BRANCH:?Falta REPO_BRANCH}"
: "${DB_HOST:?Falta DB_HOST}"
: "${DB_PORT:?Falta DB_PORT}"
: "${DB_NAME:?Falta DB_NAME}"
: "${DB_MASTER_USER:?Falta DB_MASTER_USER}"
: "${DB_PASSWORD:?Falta DB_PASSWORD}"
: "${APP_DB_USER:=app_turbinas}"
: "${APP_DB_PASSWORD:?Falta APP_DB_PASSWORD}"
: "${CORS_ORIGINS:=*}"
: "${RESTORE_DATABASE:=true}"
: "${PROJECT_NAME:=turbinas}"

APP_DIR=/opt/turbinas
BACKEND_DIR="$APP_DIR"

install_pg_client() {
  if command -v pg_restore >/dev/null 2>&1 && command -v psql >/dev/null 2>&1; then
    return 0
  fi
  if dnf install -y postgresql16; then
    return 0
  fi
  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  dnf -qy module disable postgresql || true
  dnf install -y postgresql16
}

wait_for_db() {
  local i
  for i in $(seq 1 90); do
    if PGPASSWORD="$DB_PASSWORD" pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" >/dev/null 2>&1; then
      echo "RDS disponible"
      return 0
    fi
    echo "Esperando RDS ($i/90)"
    sleep 10
  done
  return 1
}

restore_database() (
  set -euo pipefail
  export PGPASSWORD="$DB_PASSWORD"
  export PGSSLMODE=require
  local psql_cmd=(psql "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_MASTER_USER sslmode=require")
  local exists

  exists=$("${psql_cmd[@]}" -tAc "SELECT to_regclass('public.lecturavibracion') IS NOT NULL" | tr -d '[:space:]')
  if [ "$exists" != "t" ]; then
    echo "Restaurando dumps/bd_1m.dump"
    pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$DB_NAME" --no-owner --no-privileges -j 2 "$APP_DIR/dumps/bd_1m.dump"
  else
    echo "La base ya tiene la tabla lecturavibracion; se omite pg_restore"
  fi

  "${psql_cmd[@]}" -v ON_ERROR_STOP=1 -f "$APP_DIR/indices/crear_indices.sql"
  "${psql_cmd[@]}" -v ON_ERROR_STOP=1 -c "VACUUM ANALYZE;"

  if "${psql_cmd[@]}" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$APP_DB_USER'" | grep -q 1; then
    "${psql_cmd[@]}" -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$APP_DB_USER\" WITH LOGIN PASSWORD '$APP_DB_PASSWORD';"
  else
    "${psql_cmd[@]}" -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$APP_DB_USER\" LOGIN PASSWORD '$APP_DB_PASSWORD';"
  fi

  "${psql_cmd[@]}" -v ON_ERROR_STOP=1 <<SQL
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$APP_DB_USER";
GRANT USAGE ON SCHEMA public TO "$APP_DB_USER";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$APP_DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "$APP_DB_USER";
ALTER PROCEDURE sp_crear_orden_desde_alerta(bigint, int, varchar, bigint) SECURITY DEFINER;
ALTER PROCEDURE sp_crear_orden_desde_alerta(bigint, int, varchar, bigint) SET search_path = public, pg_temp;
GRANT EXECUTE ON PROCEDURE sp_crear_orden_desde_alerta(bigint, int, varchar, bigint) TO "$APP_DB_USER";
ALTER PROCEDURE sp_cerrar_orden(bigint) SECURITY DEFINER;
ALTER PROCEDURE sp_cerrar_orden(bigint) SET search_path = public, pg_temp;
GRANT EXECUTE ON PROCEDURE sp_cerrar_orden(bigint) TO "$APP_DB_USER";
SQL

  "${psql_cmd[@]}" -tAc "SELECT count(*) FROM lecturavibracion;" | tr -d '[:space:]'
)

dnf install -y git curl python3.11
if ! python3.11 -m pip --version >/dev/null 2>&1; then
  dnf install -y python3.11-pip || python3.11 -m ensurepip --upgrade
fi

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch origin "$REPO_BRANCH"
  git -C "$APP_DIR" checkout "$REPO_BRANCH"
  git -C "$APP_DIR" pull --ff-only origin "$REPO_BRANCH"
else
  rm -rf "$APP_DIR"
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
fi

chown -R ec2-user:ec2-user "$APP_DIR"

cd "$BACKEND_DIR"
if [ ! -x .venv/bin/python ]; then
  python3.11 -m venv .venv
fi
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
chown -R ec2-user:ec2-user .venv

cat > .env <<EOF
PGHOST=$DB_HOST
PGPORT=$DB_PORT
PGDATABASE=$DB_NAME
PGUSER=$APP_DB_USER
PGPASSWORD=$APP_DB_PASSWORD
PGSSLMODE=require
PGPOOL_MAX=10
PG_STATEMENT_TIMEOUT_MS=25000
CORS_ORIGINS=$CORS_ORIGINS
LOG_LEVEL=INFO
EOF
chown ec2-user:ec2-user .env
chmod 600 .env

cat > /etc/systemd/system/turbinas-api.service <<'UNIT'
[Unit]
Description=Turbinas FastAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
Group=ec2-user
WorkingDirectory=/opt/turbinas
EnvironmentFile=/opt/turbinas/.env
ExecStart=/opt/turbinas/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1
Restart=always
RestartSec=5
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT

if [ "$RESTORE_DATABASE" = "true" ]; then
  install_pg_client
  if wait_for_db; then
    if restore_database; then
      echo "Restauración completada"
    else
      echo "ADVERTENCIA: falló la restauración; la API arrancará igual"
    fi
  else
    echo "ADVERTENCIA: RDS no respondió; la API arrancará igual"
  fi
fi

systemctl daemon-reload
systemctl enable turbinas-api
systemctl restart turbinas-api
sleep 3
systemctl --no-pager --full status turbinas-api || true
curl -fsS http://127.0.0.1:8000/api/health || true

echo "=== $(date -Is) bootstrap terminado ==="
