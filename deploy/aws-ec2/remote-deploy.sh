#!/usr/bin/env bash

set -euo pipefail

required_variables=(
  AWS_REGION
  IMAGE_URI
  RUNTIME_SECRET_ID
  RDS_MASTER_SECRET_ID
  RDS_ENDPOINT
  RDS_PORT
  POSTGRES_DATABASE
  POSTGRES_USERNAME
  S3_BUCKET_NAME
  CHATWOOT_DOMAIN
  LOG_GROUP_NAME
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing required variable: ${variable_name}" >&2
    exit 1
  fi
done

if [[ ! "${POSTGRES_DATABASE}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Invalid PostgreSQL database name." >&2
  exit 1
fi

if [[ ! "${POSTGRES_USERNAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Invalid PostgreSQL username." >&2
  exit 1
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"
install -d -m 700 /opt/chatwoot

runtime_json="$(aws secretsmanager get-secret-value --secret-id "${RUNTIME_SECRET_ID}" --query SecretString --output text)"
master_json="$(aws secretsmanager get-secret-value --secret-id "${RDS_MASTER_SECRET_ID}" --query SecretString --output text)"

secret_key_base="$(jq -er '.SECRET_KEY_BASE' <<<"${runtime_json}")"
active_record_primary_key="$(jq -er '.ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' <<<"${runtime_json}")"
active_record_deterministic_key="$(jq -er '.ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY' <<<"${runtime_json}")"
active_record_salt="$(jq -er '.ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT' <<<"${runtime_json}")"
postgres_password="$(jq -er '.POSTGRES_PASSWORD' <<<"${runtime_json}")"
redis_password="$(jq -er '.REDIS_PASSWORD' <<<"${runtime_json}")"
master_username="$(jq -er '.username' <<<"${master_json}")"
master_password="$(jq -er '.password' <<<"${master_json}")"

if ! command -v docker >/dev/null 2>&1; then
  dnf install -y docker jq
fi
systemctl enable --now docker

database_exists="$({
  docker run --rm \
    -e PGPASSWORD="${master_password}" \
    postgres:18-alpine \
    psql "host=${RDS_ENDPOINT} port=${RDS_PORT} dbname=postgres user=${master_username} sslmode=require" \
    -tAc "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DATABASE}'"
} | tr -d '[:space:]')"
database_existed=false
[[ "${database_exists}" == "1" ]] && database_existed=true

docker run --rm --interactive \
  -e PGPASSWORD="${master_password}" \
  postgres:18-alpine \
  psql "host=${RDS_ENDPOINT} port=${RDS_PORT} dbname=postgres user=${master_username} sslmode=require" \
  -v app_user="${POSTGRES_USERNAME}" \
  -v app_password="${postgres_password}" \
  -v app_database="${POSTGRES_DATABASE}" \
  -v ON_ERROR_STOP=1 <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_database', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app_database') \gexec
SQL

docker run --rm \
  -e PGPASSWORD="${master_password}" \
  postgres:18-alpine \
  psql "host=${RDS_ENDPOINT} port=${RDS_PORT} dbname=${POSTGRES_DATABASE} user=${master_username} sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS vector' \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm'

umask 077
printf '%s\n' \
  'RAILS_ENV=production' \
  'NODE_ENV=production' \
  'INSTALLATION_ENV=docker' \
  'RAILS_LOG_TO_STDOUT=true' \
  'RAILS_SERVE_STATIC_FILES=true' \
  'ENABLE_ACCOUNT_SIGNUP=false' \
  'FORCE_SSL=true' \
  "FRONTEND_URL=https://${CHATWOOT_DOMAIN}" \
  "SECRET_KEY_BASE=${secret_key_base}" \
  "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${active_record_primary_key}" \
  "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${active_record_deterministic_key}" \
  "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${active_record_salt}" \
  "POSTGRES_HOST=${RDS_ENDPOINT}" \
  "POSTGRES_PORT=${RDS_PORT}" \
  "POSTGRES_DATABASE=${POSTGRES_DATABASE}" \
  "POSTGRES_USERNAME=${POSTGRES_USERNAME}" \
  "POSTGRES_PASSWORD=${postgres_password}" \
  'PGSSLMODE=require' \
  "REDIS_URL=redis://:${redis_password}@redis:6379" \
  "REDIS_PASSWORD=${redis_password}" \
  'ACTIVE_STORAGE_SERVICE=amazon' \
  "AWS_REGION=${AWS_REGION}" \
  "S3_BUCKET_NAME=${S3_BUCKET_NAME}" \
  'RAILS_MAX_THREADS=5' \
  'SIDEKIQ_CONCURRENCY=10' \
  >/opt/chatwoot/.env
chmod 600 /opt/chatwoot/.env

docker network inspect chatwoot >/dev/null 2>&1 || docker network create chatwoot
docker volume inspect chatwoot-redis >/dev/null 2>&1 || docker volume create chatwoot-redis

if docker container inspect chatwoot-redis >/dev/null 2>&1; then
  docker rm -f chatwoot-redis >/dev/null
fi
docker run -d \
  --name chatwoot-redis \
  --network chatwoot \
  --restart unless-stopped \
  --volume chatwoot-redis:/data \
  -e REDIS_PASSWORD="${redis_password}" \
  redis:7-alpine \
  sh -c 'exec redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"' \
  >/dev/null

registry="${IMAGE_URI%%/*}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${registry}" >/dev/null
docker pull "${IMAGE_URI}"

migration_required=true
if [[ "${database_existed}" == true ]] && docker run --rm \
  --network chatwoot \
  --env-file /opt/chatwoot/.env \
  "${IMAGE_URI}" \
  bundle exec rails db:abort_if_pending_migrations \
  >/dev/null 2>&1; then
  migration_required=false
fi

if [[ "${migration_required}" == true ]]; then
  if [[ "${database_existed}" == true ]]; then
    backup_key="backups/postgres/chatwoot-$(date -u +%Y%m%dT%H%M%SZ).dump"
    echo "Pending migrations detected. Creating a database backup at s3://${S3_BUCKET_NAME}/${backup_key}"
    docker run --rm \
      -e PGPASSWORD="${postgres_password}" \
      postgres:18-alpine \
      pg_dump "host=${RDS_ENDPOINT} port=${RDS_PORT} dbname=${POSTGRES_DATABASE} user=${POSTGRES_USERNAME} sslmode=require" \
      --format=custom --no-owner --no-acl | aws s3 cp - "s3://${S3_BUCKET_NAME}/${backup_key}" --sse AES256
  else
    echo 'Preparing the new Chatwoot database.'
  fi

  docker run --rm \
    --network chatwoot \
    --env-file /opt/chatwoot/.env \
    --entrypoint docker/entrypoints/rails.sh \
    "${IMAGE_URI}" \
    bundle exec rails db:chatwoot_prepare
else
  echo 'No pending database migrations. Skipping database backup and migration.'
fi

if [[ -n "${BOOTSTRAP_SECRET_ID:-}" ]]; then
  bootstrap_json="$(aws secretsmanager get-secret-value --secret-id "${BOOTSTRAP_SECRET_ID}" --query SecretString --output text)"
  admin_name="$(jq -er '.admin_name' <<<"${bootstrap_json}")"
  admin_email="$(jq -er '.admin_email' <<<"${bootstrap_json}")"
  admin_password="$(jq -er '.admin_password' <<<"${bootstrap_json}")"
  account_name="$(jq -er '.account_name' <<<"${bootstrap_json}")"

  echo 'Creating or updating the initial administrator.'
  docker run --rm \
    --network chatwoot \
    --env-file /opt/chatwoot/.env \
    -e CHATWOOT_ADMIN_NAME="${admin_name}" \
    -e CHATWOOT_ADMIN_EMAIL="${admin_email}" \
    -e CHATWOOT_ADMIN_PASSWORD="${admin_password}" \
    -e CHATWOOT_ACCOUNT_NAME="${account_name}" \
    "${IMAGE_URI}" \
    bundle exec rails runner '
      email = ENV.fetch("CHATWOOT_ADMIN_EMAIL").downcase
      user = User.find_by(email: email)
      if user
        user.assign_attributes(
          name: ENV.fetch("CHATWOOT_ADMIN_NAME"),
          password: ENV.fetch("CHATWOOT_ADMIN_PASSWORD"),
          password_confirmation: ENV.fetch("CHATWOOT_ADMIN_PASSWORD"),
          type: "SuperAdmin"
        )
        user.confirm unless user.confirmed?
        user.save!
        account = user.accounts.find_by(name: ENV.fetch("CHATWOOT_ACCOUNT_NAME")) || Account.find_by(name: ENV.fetch("CHATWOOT_ACCOUNT_NAME"))
        account ||= Account.create!(name: ENV.fetch("CHATWOOT_ACCOUNT_NAME"))
        account_user = AccountUser.find_or_initialize_by(account: account, user: user)
        account_user.role = :administrator
        account_user.save!
      else
        AccountBuilder.new(
          account_name: ENV.fetch("CHATWOOT_ACCOUNT_NAME"),
          user_full_name: ENV.fetch("CHATWOOT_ADMIN_NAME"),
          email: email,
          user_password: ENV.fetch("CHATWOOT_ADMIN_PASSWORD"),
          super_admin: true,
          confirmed: true
        ).perform
      end
      Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
    '
fi

common_run_arguments=(
  --network chatwoot
  --env-file /opt/chatwoot/.env
  --restart unless-stopped
  --log-driver awslogs
  --log-opt "awslogs-region=${AWS_REGION}"
  --log-opt "awslogs-group=${LOG_GROUP_NAME}"
)

docker rm -f chatwoot-web chatwoot-worker >/dev/null 2>&1 || true

docker run -d \
  --name chatwoot-web \
  "${common_run_arguments[@]}" \
  --log-opt 'awslogs-stream=web' \
  --publish 3000:3000 \
  --entrypoint docker/entrypoints/rails.sh \
  "${IMAGE_URI}" \
  bundle exec rails server -p 3000 -b 0.0.0.0 \
  >/dev/null

docker run -d \
  --name chatwoot-worker \
  "${common_run_arguments[@]}" \
  --log-opt 'awslogs-stream=sidekiq' \
  "${IMAGE_URI}" \
  bundle exec sidekiq -C config/sidekiq.yml \
  >/dev/null

for attempt in {1..60}; do
  if curl --fail --silent http://127.0.0.1:3000/health >/dev/null; then
    echo 'Chatwoot health check passed.'
    docker image prune --force >/dev/null
    exit 0
  fi
  sleep 5
done

echo 'Chatwoot failed its local health check.' >&2
docker logs --tail 100 chatwoot-web >&2 || true
exit 1
