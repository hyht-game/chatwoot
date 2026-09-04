# Chatwoot AWS EC2 deployment

Run the interactive deployment from the repository root:

```bash
bin/deploy-aws
```

The command is idempotent. On the first run it creates the Chatwoot-specific
CloudFormation resources, runtime secret, database/user, and initial admin. On
later runs it updates the stack, builds the current Git commit, pushes it to
ECR, and replaces the application containers. A database backup and migration
run only when the new image contains pending database migrations.

The deployment reuses the existing VPC, two private subnets, public ALB, and
PostgreSQL RDS instance exported by the game-server CloudFormation stacks. The
Chatwoot EC2 instance has no public IP and no SSH ingress. AWS Systems Manager
is used for deployment and maintenance.

AWS resources owned by this stack:

- one private EC2 instance for Rails, Sidekiq, and a persistent local Redis
  container;
- one on-demand CodeBuild project for production image builds;
- an ALB target group and host-header listener rule;
- an ECR repository for the customized Chatwoot image;
- a private, encrypted, versioned S3 bucket for uploads and database backups;
- an EC2 IAM role, security group, and CloudWatch log group.

Prerequisites on the deployment computer:

- authenticated AWS CLI access;
- `git`, `jq`, `curl`, and `openssl`;
- a clean Git working tree.

The image is built by AWS CodeBuild, so Docker Desktop is not required on the
deployment computer. Docker remains isolated to the private EC2 instance as the
application runtime.

The interactive command can also configure ZeptoMail for invitation, email
verification, password reset, and notification emails. It stores the SMTP
password in the existing AWS Secrets Manager runtime secret and reuses it on
later deployments. Use the SMTP username and password shown under the
ZeptoMail mail agent's `SMTP/API` page; the sender address must belong to a
verified domain associated with that agent.

After the first deployment, create the displayed CNAME in Cloudflare or let the
script create it with a scoped Cloudflare API token. Use `Full (strict)` SSL/TLS
mode. The existing ALB certificate must cover the Chatwoot hostname.
