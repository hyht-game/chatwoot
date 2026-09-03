#!/usr/bin/env bash

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_DIR}/../.." && pwd)"
STACK_NAME="${CHATWOOT_STACK_NAME:-chatwoot-prod}"
SOURCE_PREFIX_DEFAULT="${CHATWOOT_SOURCE_PREFIX:-game-server-prod}"
RUNTIME_SECRET_NAME=""
BOOTSTRAP_SECRET_NAME=""
SOURCE_ARCHIVE=""

usage() {
  cat <<'USAGE'
Usage: bin/deploy-aws

Interactively creates or updates a production Chatwoot deployment on AWS.
It reuses an existing VPC, private subnets, ALB, and PostgreSQL RDS instance.

Optional environment variables:
  AWS_PROFILE             AWS CLI profile to use
  AWS_REGION              AWS region (default: current CLI region or us-east-1)
  CHATWOOT_STACK_NAME     CloudFormation stack name (default: chatwoot-prod)
  CHATWOOT_SOURCE_PREFIX  Prefix of the existing infrastructure exports
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  usage >&2
  exit 1
fi

for command_name in aws git jq curl openssl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "错误：未找到 ${command_name}。" >&2
    exit 1
  fi
done

cd "${PROJECT_ROOT}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo '错误：工作区存在尚未提交的修改。生产镜像必须从可追踪的 Git 提交构建。' >&2
  echo '请先提交修改，然后重新运行 bin/deploy-aws。' >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
if [[ "${current_branch}" != 'develop' ]]; then
  echo "提示：当前分支是 ${current_branch}，不是 develop。"
fi

default_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
default_region="${default_region:-us-east-1}"

prompt() {
  local label="$1"
  local default_value="$2"
  local result

  read -r -p "${label} [${default_value}]: " result
  printf '%s' "${result:-${default_value}}"
}

confirm() {
  local label="$1"
  local default_answer="$2"
  local suffix='[y/N]'
  local answer

  [[ "${default_answer}" == 'y' ]] && suffix='[Y/n]'
  read -r -p "${label} ${suffix}: " answer
  answer="${answer:-${default_answer}}"
  [[ "${answer}" == 'y' || "${answer}" == 'Y' ]]
}

region="$(prompt 'AWS 区域' "${default_region}")"
export AWS_REGION="${region}"
aws sts get-caller-identity >/dev/null
account_id="$(aws sts get-caller-identity --query Account --output text)"

stack_exists=false
if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" >/dev/null 2>&1; then
  stack_exists=true
fi

existing_parameter() {
  local key="$1"
  local fallback="$2"
  local value

  if [[ "${stack_exists}" != true ]]; then
    printf '%s' "${fallback}"
    return
  fi

  value="$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue | [0]" \
    --output text)"
  if [[ -z "${value}" || "${value}" == 'None' ]]; then
    value="${fallback}"
  fi
  printf '%s' "${value}"
}

echo
if [[ "${stack_exists}" == true ]]; then
  echo "检测到现有部署 ${STACK_NAME}，本次将执行更新。"
else
  echo "未检测到 ${STACK_NAME}，本次将创建首次部署所需资源。"
fi
echo

environment="$(prompt '环境名称' "$(existing_parameter Environment prod)")"
domain_name="$(prompt 'Chatwoot 域名' "$(existing_parameter DomainName support.spinbison.com)")"
domain_name="$(printf '%s' "${domain_name}" | tr '[:upper:]' '[:lower:]')"
source_prefix="$(prompt '现有基础设施名称前缀' "$(existing_parameter SourceInfrastructurePrefix "${SOURCE_PREFIX_DEFAULT}")")"
instance_type="$(prompt 'Chatwoot EC2 规格' "$(existing_parameter InstanceType t3.large)")"
root_volume_size="$(prompt 'EC2 系统盘大小（GB）' "$(existing_parameter RootVolumeSize 80)")"
postgres_database="$(prompt 'Chatwoot 数据库名称' "$(existing_parameter PostgresDatabase chatwoot_production)")"
postgres_username="$(prompt 'Chatwoot 数据库用户' "$(existing_parameter PostgresUsername chatwoot_app)")"

if [[ ! "${environment}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo '错误：环境名称只能包含小写字母、数字和连字符，并且必须以字母开头。' >&2
  exit 1
fi
if [[ ! "${domain_name}" =~ ^[A-Za-z0-9.-]+$ || "${domain_name}" != *.* ]]; then
  echo '错误：域名格式无效。' >&2
  exit 1
fi
if [[ ! "${postgres_database}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || ! "${postgres_username}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo '错误：PostgreSQL 数据库名称和用户名只能包含字母、数字和下划线，并且不能以数字开头。' >&2
  exit 1
fi
if [[ ! "${root_volume_size}" =~ ^[0-9]+$ || "${root_volume_size}" -lt 40 ]]; then
  echo '错误：系统盘大小必须是至少 40 GB 的整数。' >&2
  exit 1
fi

bootstrap_admin=false
bootstrap_default='n'
[[ "${stack_exists}" == false ]] && bootstrap_default='y'
if confirm '是否创建或重置初始超级管理员' "${bootstrap_default}"; then
  bootstrap_admin=true
  account_name="$(prompt '初始账户名称' 'HYHT Support')"
  admin_name="$(prompt '管理员姓名' 'Administrator')"
  admin_email="$(prompt '管理员邮箱' 'admin@hyht.com')"
  if [[ ! "${admin_email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo '错误：管理员邮箱格式无效。' >&2
    exit 1
  fi
  while true; do
    read -r -s -p '管理员密码（至少 12 位）: ' admin_password
    echo
    if [[ ${#admin_password} -lt 12 || ! "${admin_password}" =~ [A-Z] || ! "${admin_password}" =~ [a-z] || ! "${admin_password}" =~ [0-9] || ! "${admin_password}" =~ [^A-Za-z0-9] ]]; then
      echo '密码至少 12 位，并且需要包含大写字母、小写字母、数字和特殊字符。'
      continue
    fi
    read -r -s -p '再次输入管理员密码: ' admin_password_confirmation
    echo
    if [[ "${admin_password}" == "${admin_password_confirmation}" ]]; then
      unset admin_password_confirmation
      break
    fi
    echo '两次输入的密码不一致，请重新输入。'
  done
fi

export_value() {
  local export_name="$1"
  local value
  value="$(aws cloudformation list-exports \
    --query "Exports[?Name=='${export_name}'].Value | [0]" \
    --output text)"
  if [[ -z "${value}" || "${value}" == 'None' ]]; then
    echo "错误：找不到 CloudFormation Export：${export_name}" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

echo
echo '正在检查现有 AWS 网络、ALB 和 RDS...'
vpc_id="$(export_value "${source_prefix}-vpc-id")"
private_subnet_a="$(export_value "${source_prefix}-private-subnet-a")"
alb_security_group_id="$(export_value "${source_prefix}-alb-sg-id")"
rds_security_group_id="$(export_value "${source_prefix}-postgres-sg-id")"
rds_endpoint="$(export_value "${source_prefix}-postgres-endpoint")"
rds_port="$(export_value "${source_prefix}-postgres-port")"
alb_dns_name="$(export_value "${source_prefix}-alb-dns")"
alb_arn="$(aws elbv2 describe-load-balancers --names "${source_prefix}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
https_listener_arn="$(aws elbv2 describe-listeners --load-balancer-arn "${alb_arn}" --query 'Listeners[?Port==`443`].ListenerArn | [0]' --output text)"
if [[ -z "${https_listener_arn}" || "${https_listener_arn}" == 'None' ]]; then
  echo '错误：现有 ALB 没有 HTTPS 443 Listener。' >&2
  exit 1
fi

certificate_covers_domain=false
certificate_arns="$(aws elbv2 describe-listener-certificates \
  --listener-arn "${https_listener_arn}" \
  --query 'Certificates[].CertificateArn' \
  --output text)"
for certificate_arn in ${certificate_arns}; do
  certificate_names="$(aws acm describe-certificate \
    --certificate-arn "${certificate_arn}" \
    --query 'Certificate.SubjectAlternativeNames' \
    --output text)"
  for certificate_name in ${certificate_names}; do
    if [[ "${certificate_name}" == "${domain_name}" ]]; then
      certificate_covers_domain=true
      break 2
    fi
    if [[ "${certificate_name}" == \*.* ]]; then
      certificate_base="${certificate_name#*.}"
      domain_label="${domain_name%.${certificate_base}}"
      if [[ "${domain_name}" == *."${certificate_base}" && "${domain_label}" != *.* ]]; then
        certificate_covers_domain=true
        break 2
      fi
    fi
  done
done
if [[ "${certificate_covers_domain}" != true ]]; then
  echo "错误：ALB 的 HTTPS 证书不包含 ${domain_name}。请先给 Listener 添加对应 ACM 证书。" >&2
  exit 1
fi

rds_master_secret_name="/${source_prefix%-prod}/prod/rds-master"
if [[ "${source_prefix}" == 'game-server-prod' ]]; then
  rds_master_secret_name='/game-server/prod/rds-master'
fi
rds_master_secret_name="$(prompt 'RDS 主密码的 Secrets Manager 名称' "${rds_master_secret_name}")"
rds_master_secret_arn="$(aws secretsmanager describe-secret --secret-id "${rds_master_secret_name}" --query ARN --output text)"

if [[ "${stack_exists}" == true ]]; then
  listener_rule_priority="$(existing_parameter ListenerRulePriority 5)"
else
  used_priorities="$(aws elbv2 describe-rules --listener-arn "${https_listener_arn}" --query 'Rules[?Priority!=`default`].Priority' --output text)"
  listener_rule_priority='5'
  while grep -qw "${listener_rule_priority}" <<<"${used_priorities}"; do
    listener_rule_priority="$((listener_rule_priority + 1))"
  done
fi

cleanup_bootstrap_secret() {
  if [[ -n "${BOOTSTRAP_SECRET_NAME}" ]]; then
    aws secretsmanager delete-secret --secret-id "${BOOTSTRAP_SECRET_NAME}" --force-delete-without-recovery >/dev/null 2>&1 || true
  fi
  if [[ -n "${SOURCE_ARCHIVE}" && -f "${SOURCE_ARCHIVE}" ]]; then
    rm -f -- "${SOURCE_ARCHIVE}"
  fi
}
trap cleanup_bootstrap_secret EXIT

echo
echo '部署摘要：'
echo "  AWS 账户：${account_id}"
echo "  区域：${region}"
echo "  CloudFormation：${STACK_NAME}"
echo "  域名：https://${domain_name}"
echo "  EC2：${instance_type} / ${root_volume_size} GB，私有子网"
echo "  PostgreSQL：复用 ${rds_endpoint}，独立数据库 ${postgres_database}"
echo "  入口：复用 ${source_prefix}-alb，不安装 Nginx"
echo

if ! confirm '确认开始创建或更新 AWS 资源' 'n'; then
  echo '已取消。'
  exit 0
fi

RUNTIME_SECRET_NAME="/chatwoot/${environment}/runtime"
if aws secretsmanager describe-secret --secret-id "${RUNTIME_SECRET_NAME}" >/dev/null 2>&1; then
  runtime_secret_arn="$(aws secretsmanager describe-secret --secret-id "${RUNTIME_SECRET_NAME}" --query ARN --output text)"
else
  runtime_secret_json="$(jq -n \
    --arg secret_key_base "$(openssl rand -hex 64)" \
    --arg primary_key "$(openssl rand -hex 32)" \
    --arg deterministic_key "$(openssl rand -hex 32)" \
    --arg salt "$(openssl rand -hex 32)" \
    --arg postgres_password "$(openssl rand -hex 32)" \
    --arg redis_password "$(openssl rand -hex 32)" \
    '{
      SECRET_KEY_BASE: $secret_key_base,
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: $primary_key,
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: $deterministic_key,
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: $salt,
      POSTGRES_PASSWORD: $postgres_password,
      REDIS_PASSWORD: $redis_password
    }')"
  runtime_secret_arn="$(aws secretsmanager create-secret \
    --name "${RUNTIME_SECRET_NAME}" \
    --description "Chatwoot ${environment} runtime secrets" \
    --secret-string file:///dev/stdin \
    --query ARN \
    --output text <<<"${runtime_secret_json}")"
  unset runtime_secret_json
fi

if [[ "${bootstrap_admin}" == true ]]; then
  BOOTSTRAP_SECRET_NAME="/chatwoot/${environment}/bootstrap-$(date +%s)"
  bootstrap_json="$(jq -n \
    --arg account_name "${account_name}" \
    --arg admin_name "${admin_name}" \
    --arg admin_email "${admin_email}" \
    --arg admin_password "${admin_password}" \
    '{account_name: $account_name, admin_name: $admin_name, admin_email: $admin_email, admin_password: $admin_password}')"
  aws secretsmanager create-secret \
    --name "${BOOTSTRAP_SECRET_NAME}" \
    --description "Temporary Chatwoot administrator bootstrap secret" \
    --secret-string file:///dev/stdin \
    >/dev/null <<<"${bootstrap_json}"
  unset bootstrap_json admin_password
fi

echo '正在创建或更新 CloudFormation 资源...'
aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${DEPLOY_DIR}/cloudformation.yml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "Environment=${environment}" \
    "SourceInfrastructurePrefix=${source_prefix}" \
    "DomainName=${domain_name}" \
    "PostgresDatabase=${postgres_database}" \
    "PostgresUsername=${postgres_username}" \
    "VpcId=${vpc_id}" \
    "PrivateSubnetA=${private_subnet_a}" \
    "AlbSecurityGroupId=${alb_security_group_id}" \
    "RdsSecurityGroupId=${rds_security_group_id}" \
    "RdsEndpoint=${rds_endpoint}" \
    "RdsPort=${rds_port}" \
    "RdsMasterSecretArn=${rds_master_secret_arn}" \
    "RuntimeSecretArn=${runtime_secret_arn}" \
    "HttpsListenerArn=${https_listener_arn}" \
    "ListenerRulePriority=${listener_rule_priority}" \
    "InstanceType=${instance_type}" \
    "RootVolumeSize=${root_volume_size}"

stack_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text
}

instance_id="$(stack_output InstanceId)"
ecr_repository_uri="$(stack_output EcrRepositoryUri)"
codebuild_project_name="$(stack_output CodeBuildProjectName)"
uploads_bucket="$(stack_output UploadsBucketName)"
log_group_name="$(stack_output LogGroupName)"
image_tag="$(git rev-parse --short=12 HEAD)"
image_uri="${ecr_repository_uri}:${image_tag}"

SOURCE_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/chatwoot-source.XXXXXX")"
git archive --format=zip --output="${SOURCE_ARCHIVE}" HEAD
aws s3 cp "${SOURCE_ARCHIVE}" "s3://${uploads_bucket}/deploy/source.zip" --sse AES256 >/dev/null
rm -f -- "${SOURCE_ARCHIVE}"
SOURCE_ARCHIVE=''

echo "正在通过 AWS CodeBuild 构建并推送镜像 ${image_uri}..."
build_id="$(aws codebuild start-build \
  --project-name "${codebuild_project_name}" \
  --environment-variables-override "name=IMAGE_TAG,value=${image_tag},type=PLAINTEXT" \
  --query 'build.id' \
  --output text)"

for attempt in {1..180}; do
  build_status="$(aws codebuild batch-get-builds \
    --ids "${build_id}" \
    --query 'builds[0].buildStatus' \
    --output text)"
  case "${build_status}" in
    SUCCEEDED)
      break
      ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      aws codebuild batch-get-builds \
        --ids "${build_id}" \
        --query 'builds[0].{Status:buildStatus,CurrentPhase:currentPhase,Phases:phases[*].{Phase:phaseType,Status:phaseStatus,Message:contexts[0].message},Logs:logs.deepLink}'
      exit 1
      ;;
  esac
  sleep 10
done
if [[ "${build_status:-}" != 'SUCCEEDED' ]]; then
  echo '错误：CodeBuild 镜像构建在 30 分钟内没有完成。' >&2
  exit 1
fi

echo '正在等待 EC2 进入 SSM 在线状态...'
for attempt in {1..60}; do
  ping_status="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || true)"
  [[ "${ping_status}" == 'Online' ]] && break
  sleep 10
done
if [[ "${ping_status:-}" != 'Online' ]]; then
  echo '错误：EC2 未能在 10 分钟内连接到 SSM。请检查私有子网的 NAT 或 VPC Endpoint。' >&2
  exit 1
fi

remote_script_key="deploy/remote-deploy-${image_tag}.sh"
aws s3 cp "${DEPLOY_DIR}/remote-deploy.sh" "s3://${uploads_bucket}/${remote_script_key}" --sse AES256 >/dev/null

shell_quote() {
  printf '%q' "$1"
}

remote_command="aws s3 cp $(shell_quote "s3://${uploads_bucket}/${remote_script_key}") /tmp/chatwoot-remote-deploy.sh >/dev/null && chmod 700 /tmp/chatwoot-remote-deploy.sh && AWS_REGION=$(shell_quote "${region}") IMAGE_URI=$(shell_quote "${image_uri}") RUNTIME_SECRET_ID=$(shell_quote "${RUNTIME_SECRET_NAME}") RDS_MASTER_SECRET_ID=$(shell_quote "${rds_master_secret_name}") RDS_ENDPOINT=$(shell_quote "${rds_endpoint}") RDS_PORT=$(shell_quote "${rds_port}") POSTGRES_DATABASE=$(shell_quote "${postgres_database}") POSTGRES_USERNAME=$(shell_quote "${postgres_username}") S3_BUCKET_NAME=$(shell_quote "${uploads_bucket}") CHATWOOT_DOMAIN=$(shell_quote "${domain_name}") LOG_GROUP_NAME=$(shell_quote "${log_group_name}") BOOTSTRAP_SECRET_ID=$(shell_quote "${BOOTSTRAP_SECRET_NAME}") /tmp/chatwoot-remote-deploy.sh"

echo '正在远程检查数据库并更新 Rails、Sidekiq 和 Redis...'
command_id="$(aws ssm send-command \
  --instance-ids "${instance_id}" \
  --document-name AWS-RunShellScript \
  --comment "Deploy Chatwoot ${image_tag}" \
  --parameters "$(jq -n --arg command "${remote_command}" '{commands: [$command]}')" \
  --query Command.CommandId \
  --output text)"

for attempt in {1..180}; do
  command_status="$(aws ssm get-command-invocation \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query Status \
    --output text 2>/dev/null || true)"
  case "${command_status}" in
    Success)
      break
      ;;
    Failed|Cancelled|TimedOut|Cancelling)
      aws ssm get-command-invocation \
        --command-id "${command_id}" \
        --instance-id "${instance_id}" \
        --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}'
      exit 1
      ;;
  esac
  sleep 10
done
if [[ "${command_status:-}" != 'Success' ]]; then
  echo '错误：远程部署在 30 分钟内没有完成。' >&2
  exit 1
fi

aws ssm get-command-invocation \
  --command-id "${command_id}" \
  --instance-id "${instance_id}" \
  --query StandardOutputContent \
  --output text

aws s3 rm "s3://${uploads_bucket}/${remote_script_key}" >/dev/null
cleanup_bootstrap_secret
BOOTSTRAP_SECRET_NAME=''
trap - EXIT

if confirm '是否现在自动创建或更新 Cloudflare CNAME 记录' 'n'; then
  zone_name="$(prompt 'Cloudflare Zone 名称' "${domain_name#*.}")"
  read -r -s -p 'Cloudflare API Token: ' cloudflare_token
  echo
  cloudflare_api='https://api.cloudflare.com/client/v4'
  zone_response="$(curl --fail --silent --show-error \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${cloudflare_token}") \
    --header 'Content-Type: application/json' \
    "${cloudflare_api}/zones?name=${zone_name}&status=active")"
  zone_id="$(jq -er '.result[0].id' <<<"${zone_response}")"
  record_response="$(curl --fail --silent --show-error \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${cloudflare_token}") \
    --header 'Content-Type: application/json' \
    "${cloudflare_api}/zones/${zone_id}/dns_records?type=CNAME&name=${domain_name}")"
  record_id="$(jq -r '.result[0].id // empty' <<<"${record_response}")"
  record_payload="$(jq -n \
    --arg name "${domain_name}" \
    --arg content "${alb_dns_name}" \
    '{type: "CNAME", name: $name, content: $content, ttl: 1, proxied: true}')"
  if [[ -n "${record_id}" ]]; then
    cloudflare_update_response="$(curl --fail --silent --show-error \
      --request PUT \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${cloudflare_token}") \
      --header 'Content-Type: application/json' \
      --data "${record_payload}" \
      "${cloudflare_api}/zones/${zone_id}/dns_records/${record_id}")"
  else
    cloudflare_update_response="$(curl --fail --silent --show-error \
      --request POST \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${cloudflare_token}") \
      --header 'Content-Type: application/json' \
      --data "${record_payload}" \
      "${cloudflare_api}/zones/${zone_id}/dns_records")"
  fi
  jq -e '.success == true' <<<"${cloudflare_update_response}" >/dev/null
  unset cloudflare_token
  echo 'Cloudflare DNS 已更新。'
else
  echo
  echo '请在 Cloudflare 手动配置：'
  echo "  类型：CNAME"
  echo "  名称：${domain_name}"
  echo "  目标：${alb_dns_name}"
  echo '  代理：开启（橙色云）'
  echo '  SSL/TLS：Full (strict)'
fi

echo
echo '部署完成。'
echo "  Chatwoot：https://${domain_name}"
echo "  EC2 实例：${instance_id}"
echo "  CloudWatch 日志组：${log_group_name}"
echo "  再次更新：bin/deploy-aws"
