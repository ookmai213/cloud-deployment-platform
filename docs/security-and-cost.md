# Security assumptions and cloud cost

## Security controls in the implementation

- FastAPI runs as a non-root UID in a read-only container filesystem with
  dropped Linux capabilities, `no-new-privileges`, resource limits, and an
  internal Compose network.
- Nginx uses an unprivileged image, a read-only root filesystem, a constrained
  temporary filesystem, TLS 1.2/1.3, security headers, API rate limiting, and
  explicit denials for public metrics/OpenAPI paths.
- Application settings and versions are validated; information endpoints do
  not expose hostnames, instance metadata, or unrestricted diagnostics.
- Container deployment requires an immutable SHA-256 image digest. It does
  not accept mutable tags as a release identifier.
- Terraform requires IMDSv2, encrypts the gp3 root disk, enables private ECR
  image scanning on push, blocks SSH ingress, and assigns a scoped instance
  role. The initial network intentionally uses public-subnet egress instead
  of a NAT Gateway.
- Terraform state bucket uses S3 encryption, versioning, public access blocks,
  TLS-only bucket policy, and native state lockfiles. It is protected from
  accidental Terraform destruction.
- GitHub uses short-lived OIDC roles, scoped to the main branch for image
  publishing and the protected `staging` environment for deployment. No static
  AWS keys are required in GitHub.
- Ansible disables password/root SSH access, enables unattended security
  updates, applies baseline sysctl hardening, bounds persistent journald
  storage, and configures Docker from its signed upstream repository.

These are source-level controls; deployment-specific IAM, DNS, security
groups, identity policies, GitHub protections, actual TLS, and runtime
behavior must still be reviewed and verified in the target account.

## Important limitations and risks

- A single EC2 instance and one AZ are not highly available. Instance or AZ
  failure interrupts service until recovery.
- The public subnet and outbound `0.0.0.0/0` egress increase exposure relative
  to private-subnet designs. No NAT Gateway is used to avoid its baseline
  hourly and data-processing charges.
- The instance's Docker daemon is a privileged host component. Limit host
  administrative access and do not add untrusted users to the Docker group.
- ECR image vulnerability scanning and Trivy CI scans are configured, but
  scan results have not been produced. Review base-image updates and high/
  critical findings before release.
- Let's Encrypt issuance/renewal, SSM sessions, GitHub OIDC conditions,
  Ansible idempotency on a real Ubuntu host, and cloud rollback have not been
  exercised.
- Alertmanager currently discards notifications; CloudWatch alarms have no
  SNS action. Monitoring is not an on-call solution until receivers and
  notification paths are configured and tested.
- Prometheus/Grafana/Node Exporter are optional. Running them increases host
  CPU, memory, disk, and image/log storage; choose a larger instance or omit
  the monitoring profile if resource pressure occurs.
- GitHub Actions tags actions by major version in the workflow; review and
  pin actions to verified commit SHAs according to repository supply-chain
  policy before production use.
- CI validates infrastructure configuration only. It does not prove that the
  target AWS account has quota, service access, a valid domain, or successful
  cloud resources.

## Cost drivers and controls

No cost estimate is guaranteed: AWS pricing changes and varies by account,
region, usage, discounts, and public IPv4 status. The initial resources likely
to incur charges are:

| Resource | Cost driver / control |
|---|---|
| EC2 `t3.small` | Runs continuously; stop/terminate when unused, noting stopped hosts are not serving traffic |
| 20 GiB encrypted gp3 EBS | Provisioned storage while the volume exists |
| Elastic IP | Needed for stable DNS; AWS may charge for public IPv4 addresses. Release it only after DNS/host teardown |
| ECR | Stored image layers and scan activity; remove obsolete digests under an approved retention policy |
| CloudWatch Logs | Ingested bytes and 30-day retention; reduce verbosity/retention if cost requires |
| CloudWatch alarms | Alarm-month charges; two alarms are configured |
| S3 Terraform state | Low but nonzero storage/request charges; object versions accumulate |
| Data transfer | Public egress and package/image traffic; monitor actual usage |
| Let's Encrypt | No certificate fee, but the service depends on public DNS and port 80 |

The design avoids initial NAT Gateway, ALB, bastion, EKS, and managed database
costs. Adding multi-AZ failover, managed load balancing, private endpoints,
high-volume monitoring, or a larger instance changes the cost profile and
should be separately reviewed. The state bootstrap bucket uses
`prevent_destroy`; keep the state backend until all dependent state is
intentionally retired.

## State and secret handling

- Keep `terraform.tfvars`, `backend.hcl`, state files, `.env`, private keys,
  credentials, and generated plan files out of version control.
- Use an authorized role/profile for local Terraform and AWS CLI use. Do not
  place AWS access keys in Ansible inventory, playbooks, Compose files, or
  GitHub variables.
- GitHub repository variables contain role ARNs, repository URL, and instance
  ID only; OIDC supplies short-lived credentials.
- Grafana password belongs in the ignored `.env` file or an approved secret
  manager. Replace the example value before starting monitoring.
- Terraform state is sensitive even when the configuration contains no
  explicit secret. Restrict its IAM access, secure any temporary local state,
  and protect versioned state objects.
