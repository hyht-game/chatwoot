# Chatwoot AWS EC2 deployment

Run the interactive deployment from the repository root:

```bash
bin/deploy-aws
```

The command is idempotent. On the first run it creates the Chatwoot-specific
CloudFormation resources, runtime secret, database/user, and initial admin. On
later runs it updates the stack, builds the current Git commit, pushes it to
ECR, backs up the Chatwoot database to S3, runs migrations, and replaces the
application containers.

The deployment reuses the existing VPC, two private subnets, public ALB, and
PostgreSQL RDS instance exported by the game-server CloudFormation stacks. The
Chatwoot EC2 instance has no public IP and no SSH ingress. AWS Systems Manager
is used for deployment and maintenance.

AWS resources owned by this stack:

- one private EC2 instance for Rails, Sidekiq, and a persistent local Redis
  container;
- an ALB target group and host-header listener rule;
- an ECR repository for the customized Chatwoot image;
- a private, encrypted, versioned S3 bucket for uploads and database backups;
- an EC2 IAM role, security group, and CloudWatch log group.

Prerequisites on the deployment computer:

- authenticated AWS CLI access;
- Docker Desktop with buildx;
- `git`, `jq`, `curl`, and `openssl`;
- a clean Git working tree.

After the first deployment, create the displayed CNAME in Cloudflare or let the
script create it with a scoped Cloudflare API token. Use `Full (strict)` SSL/TLS
mode. The existing ALB certificate must cover the Chatwoot hostname.
