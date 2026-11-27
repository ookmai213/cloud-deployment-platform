# Operations, validation, and recovery

## Local application checks

Install the pinned development dependencies, run focused tests and lint, and
check shell syntax:

```bash
python -m pip install -r requirements-dev.txt
python -m pytest -q
ruff check app tests
bash -n scripts/deploy-ubuntu.sh scripts/deploy-container.sh
shellcheck scripts/deploy-ubuntu.sh scripts/deploy-container.sh
```

The existing systemd rollback integration test and container deployment
helper test replace host service commands/Docker with mocks. They verify the
rollback logic but do not emulate a full Linux host, Nginx, network, Docker
daemon, or AWS:

```bash
bash scripts/test-full-rollback-isolated.sh scripts/deploy-ubuntu.sh
bash tests/test_deploy_container.sh
```

For the local Compose stack, copy `.env.example` to `.env`, choose a unique
Grafana password, and run `bash scripts/validate-compose.sh` before startup.
The script requires a working Docker Engine and validates four Compose
profiles/configurations. The local app listens on `127.0.0.1:8080`.

## Cloud host verification

Use Systems Manager Session Manager; do not open SSH ingress. Useful read-only
checks on the host:

```bash
sudo docker compose --env-file /opt/linux-web-infrastructure/.env \
  -f /opt/linux-web-infrastructure/compose.yaml \
  -f /opt/linux-web-infrastructure/compose.cloud.yaml ps
sudo docker compose --env-file /opt/linux-web-infrastructure/.env \
  -f /opt/linux-web-infrastructure/compose.yaml \
  -f /opt/linux-web-infrastructure/compose.cloud.yaml logs --tail=100
sudo curl --fail --silent --show-error https://app.example.com/api/health
```

Replace the example host name. Check public health, certificate validity,
CloudWatch container logs, EC2 status checks, and SSM managed-node status.
Do not expose Grafana, Prometheus, Alertmanager, Node Exporter, or FastAPI
directly to the Internet.

## Container release procedure

Deploy only a full digest reference:

```bash
sudo /opt/linux-web-infrastructure/scripts/deploy-container.sh \
  ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com/linux-web-infrastructure@sha256:REPLACE_WITH_64_HEX_DIGEST \
  REPLACE_WITH_COMMIT_SHA
```

The helper validates inputs, authenticates to ECR using a temporary Docker
config, records the previous `.env`, pulls the new image, restarts the API,
checks API and Nginx container health plus the proxied `/api/health`, and
restores/verifies the previous release on failure. Keep the environment file
root-owned and mode `0600`. If rollback validation itself fails, the helper
preserves the backup file and reports its path; investigate before another
deployment.

On the first deployment, no old image exists to restore. If it fails, inspect
the SSM output and container logs, correct the root cause, and re-run with a
known-good digest. Do not assume a rollback occurred.

## Monitoring operations

The optional monitoring Compose profile collects API request counters and
latencies, host metrics, and evaluates Prometheus rules. Grafana listens only
on host loopback. Use an SSH/SSM port-forward or another approved private
access path to reach it remotely.

Docker Desktop/WSL does not support the `rslave` propagation mode for the
Node Exporter root mount when `/` is not a shared mount. The Compose
configuration uses a read-only root mount without propagation instead; host
metrics were verified locally, but nested mount changes do not propagate.

Alertmanager currently routes to a discard receiver: alerts are not delivered
to email/chat/on-call. Configure and test an approved receiver (with secrets
outside the repository) before relying on notifications. CloudWatch has EC2
CPU and instance status-check alarms; no notification action/SNS topic is
created.

## Checks and present validation evidence

Run Terraform format/validation without account credentials:

```bash
terraform fmt -check -recursive terraform
for root in terraform/bootstrap terraform/infrastructure; do
  terraform -chdir="$root" init -backend=false -input=false
  terraform -chdir="$root" validate
done
```

Run Ansible syntax validation:

```bash
cd ansible
ansible-playbook --syntax-check -i inventory.example.ini site.yml
```

Local validation passed for the Docker image build, API tests (5 passed), Ruff,
Compose configuration/runtime, website rendering, API routes and security
headers, private API networking, two-replica load balancing, Prometheus
scraping, Grafana dashboard provisioning, Alertmanager alert ingestion, Node
Exporter metrics, and API process-crash recovery. Before merge commit
`bc08db4`, GitHub CI, Trivy, Terraform validation, Ansible validation, and
Kubernetes schema validation passed. Systemd and container deployment rollback
tests use mocks.

Kubernetes cluster runtime, Jenkins, AWS deployment, OIDC, SSM, DNS/TLS,
external alert delivery, and real deployment rollback remain unverified. No
AWS resources were created.

## Troubleshooting

| Symptom | First checks |
|---|---|
| SSM host is offline | Instance profile, SSM Agent, IAM permissions, outbound DNS/HTTPS, and EC2 status checks |
| Image pull is denied | EC2 role ECR permissions, region, repository URL, digest, and host ECR login |
| Nginx is unhealthy | Runtime config path, TLS certificate/key mounts, ports 8080/8443 inside Compose, and `docker compose logs nginx` |
| API is unhealthy | Image digest, `APP_VERSION`, `/readyz`, container logs, and memory/CPU constraints |
| ACME validation fails | Public DNS A record, inbound TCP/80, correct webroot mount, and no conflicting DNS proxy |
| Deployment or rollback fails | Read SSM stdout/stderr and the helper's backup path; preserve logs and avoid deleting the old ECR digest |
| Metrics are unavailable | Confirm monitoring profile, private network membership, Prometheus target health, and API `/metrics` from inside the network |

The optional Kubernetes and Jenkins examples are not part of initial host
recovery; validate them separately before use.
