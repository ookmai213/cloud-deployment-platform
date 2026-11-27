# AWS deployment and GitHub publication

This is an operator procedure, not an automated provisioning step. It has not
been run against an AWS account. Do not proceed unless you have authorization
to create the listed resources and incur their charges. Never run `terraform
apply` or `destroy` as part of routine local validation.

## Prerequisites

- A dedicated AWS account or authorized account and an operator identity with
  least-privilege rights to create the listed infrastructure.
- AWS CLI v2, Terraform 1.10+, Python 3.11+, Ansible, Docker Engine with
  Compose plugin, and Git installed on the controller.
- A GitHub repository and a DNS name you control.
- An AWS IAM OIDC provider for `https://token.actions.githubusercontent.com`
  with audience `sts.amazonaws.com`. Create it once per account using the
  current AWS/GitHub documentation; do not copy credentials or trust settings
  from another project.
- A globally unique S3 bucket name for this project's Terraform state.

Use the AWS region `ap-south-1`. The Terraform roots are independent:
`terraform/bootstrap` creates the state bucket; `terraform/infrastructure`
creates the application VPC, subnet, EC2 instance, IAM, ECR, logs, alarms, and
optional GitHub roles. Review all Terraform files and the plan before any
apply.

## 1. Initialize the independent state bucket

Copy the example files and set a globally unique bucket name. These working
files are ignored by Git:

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
cp terraform/bootstrap/backend.hcl.example terraform/bootstrap/backend.hcl
```

First initialize the bootstrap root with local state because the remote bucket
does not exist yet:

```bash
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/bootstrap plan
```

After an authorized review, create the state bucket with the bootstrap root.
Then migrate its local state to the new encrypted, versioned S3 backend using
the configured key and native S3 lockfile:

```bash
terraform -chdir=terraform/bootstrap apply
terraform -chdir=terraform/bootstrap init -migrate-state -force-copy \
  -backend-config=backend.hcl
terraform -chdir=terraform/bootstrap plan
```

The bootstrap bucket has public access blocked, server-side encryption,
versioning, a TLS-only bucket policy, and `prevent_destroy`. Secure and back up
any local state created during bootstrap, and remove it only after confirming
the remote state is present and correct. State may contain sensitive values.

## 2. Review and provision the application infrastructure

Prepare the backend config and variables using the examples:

```bash
cp terraform/infrastructure/backend.hcl.example terraform/infrastructure/backend.hcl
cp terraform/infrastructure/terraform.tfvars.example terraform/infrastructure/terraform.tfvars
```

Set the same state bucket name and the separate
`linux-web-infrastructure/infrastructure/terraform.tfstate` key. If GitHub
OIDC roles are desired, set `github_oidc_provider_arn` and
`github_repository` in the ignored variables file. Review instance size,
ingress CIDRs, Elastic IP, data retention and tags. If Ansible will be used,
create an EC2 key pair in `ap-south-1` outside this repository and set
`ec2_key_pair_name`; keep the private key in a protected local path. Ansible
uses SSH authentication through an SSM tunnel, while the instance security
group remains closed to inbound SSH. Then:

```bash
terraform -chdir=terraform/infrastructure init \
  -backend-config=backend.hcl
terraform -chdir=terraform/infrastructure validate
terraform -chdir=terraform/infrastructure plan
```

Only an authorized operator should review and run `apply`. Save the output
values securely: `instance_id`, `public_ip`, `ecr_repository_url`, and the
optional publish/deploy role ARNs. No SSH rule is created. Ensure the instance
registers as an SSM managed node and can reach SSM/ECR/AWS APIs through outbound
Internet access before continuing.

## 3. Publish source and configure GitHub

After reviewing `git status` and the final diff:

1. Use the `origin` remote configured for
   `https://github.com/ookmai213/cloud-deployment-platform.git`.
2. Review for secrets/state and confirm the ignored backend/variable files
   are not staged. Do not publish credentials or Terraform state.
3. Push the reviewed branch and create/protect `main`; require CI checks and
   review according to your repository policy.
4. Configure a GitHub Environment named `staging`, restrict deployment
   branches, and enable required reviewers before enabling the deploy role.
5. Add repository **variables** (not long-lived AWS secrets):
   - `AWS_PUBLISH_ROLE_ARN`: Terraform `github_publish_role_arn`
   - `AWS_DEPLOY_ROLE_ARN`: Terraform `github_deploy_role_arn`
   - `ECR_REPOSITORY_URL`: Terraform `ecr_repository_url`
   - `EC2_INSTANCE_ID`: Terraform `instance_id`
6. Confirm the AWS OIDC trust policy's repository and subject conditions
   match the exact owner/repository, `main`, and `staging` environment.

The `Publish immutable image` workflow is manually dispatched on `main` after
successful CI for the exact commit, and only when the required AWS variables
exist. It builds and scans an image and reports an ECR digest. The manual `Deploy staging image` workflow requires that digest
and a safe release label. It runs only in the protected `staging` environment.
The initial CI run exposed a scanner reference and Ansible lint failures; see the repository Actions tab for current validation results. AWS workflows remain untested.

## 4. Configure DNS, TLS, and the first release

1. Create an A record for the chosen hostname pointing to Terraform's
   `public_ip` (the default allocates an Elastic IP).
2. Wait for DNS to resolve from outside the VPC.
3. Build and publish the application image; retain its full ECR digest.
4. Install Ansible dependencies in a dedicated Python environment:

   ```bash
   python3 -m venv .venv-ansible
   . .venv-ansible/bin/activate
   python -m pip install -r ansible/requirements-dev.txt
   ```

5. Copy `ansible/inventory.example.ini` to the ignored `ansible/inventory.ini`
   and replace the example instance ID and private-key path. Ensure the
   controller's AWS CLI identity can start an SSM session, the matching EC2
   key pair was configured on the instance, and the host is online in Systems
   Manager. The example accepts and records the instance's SSH host key on
   first use (`StrictHostKeyChecking=accept-new`); verify the target instance
   ID before the initial connection.
6. Deploy with a real DNS name, contact email, immutable image digest, and
   commit/version label:

   ```bash
   cd ansible
   ansible-playbook -i inventory.ini site.yml \
     -e "platform_domain=app.example.com" \
     -e "acme_email=ops@example.com" \
     -e "release_image=ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:REPLACE_WITH_64_HEX_DIGEST" \
     -e "release_version=REPLACE_WITH_COMMIT_SHA"
   ```

   Replace every placeholder before running. The playbook hardens Ubuntu,
   installs Docker, configures Compose, obtains a Let's Encrypt HTTP-01
   certificate, and deploys the immutable release. Certificate issuance
   requires public DNS and inbound port 80; renewal uses Certbot's timer.

7. Verify HTTPS and health from an external client. Only after a successful
   first deployment and a reviewed recovery path should you enable the
   protected GitHub deployment workflow.

## Rollback and cleanup

The container helper rolls back to the prior recorded image digest if
deployment checks fail. First deployment cannot automatically roll back.
Investigate SSM command output and the host Compose logs before retrying.
Terraform `destroy` removes billable resources but is intentionally not
provided as an automatic cleanup command. Review dependencies, ECR images,
CloudWatch logs, Elastic IP allocation, DNS, and both Terraform states before
an authorized cleanup. Do not destroy the protected state bucket as part of
normal application teardown.
