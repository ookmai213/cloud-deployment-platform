
# Linux Web Infrastructure

A hands-on Linux infrastructure project built on Ubuntu using WSL2.

The project demonstrates Linux administration, web server configuration,
application deployment, systemd service management, deployment validation,
and recovery from application deployment failures.

## Project Status

**Completed:** Local Linux web server, FastAPI application, systemd service,
and repeatable Ubuntu deployment script.

**In progress:** HTTPS/TLS, configuration management, infrastructure
automation, monitoring, and operational reliability.

## Architecture

```text
                 Browser / curl
                       |
                       v
                Nginx (port 8080)
                       |
             +---------+---------+
             |                   |
             v                   v
        Static website       /api/ reverse proxy
                                  |
                                  v
                        FastAPI (127.0.0.1:8000)
                                  |
                                  v
                              Uvicorn
                                  |
                                  v
                          systemd service
                           linux-web user
```

## Implemented Components

### Nginx

- Static website served on port 8080.
- Dedicated Nginx server configuration.
- HTTP security headers.
- Custom 404 page.
- Favicon handling.
- Separate access and error logs.
- Reverse proxy for backend API requests.

### FastAPI

- FastAPI backend with health and information endpoints.
- Uvicorn application server.
- Backend bound to `127.0.0.1:8000`.
- Nginx reverse proxy maps `/api/` requests to the backend.

### Linux Service Management

- systemd-managed FastAPI service.
- Dedicated non-login service account: `linux-web`.
- Application deployed under `/opt/linux-web-infrastructure`.
- Production Python virtual environment.
- Application files owned by root and readable by the service group.
- Automatic service restart on failure.

### Deployment Automation

The Ubuntu deployment script is located at:

` scripts/deploy-ubuntu.sh `

It performs the following operations:

- Checks deployment prerequisites and source files.
- Validates the service account.
- Prepares application and website directories.
- Deploys application files.
- Prepares the production Python virtual environment.
- Installs Python dependencies when required.
- Validates application imports using the service account.
- Deploys static website files.
- Installs systemd and Nginx configuration.
- Validates Nginx configuration.
- Starts or reloads services as needed.
- Checks service status and API health endpoints.
- Retains deployment backups for recovery.

The deployment was tested for repeatability and for an application import
failure. The tested rollback restored the previous application files.

Rollback is best-effort; this implementation does not use atomic
versioned releases.

## API Endpoints

| Endpoint | Description |
|---|---|
| `GET /api/health` | Checks backend health through Nginx |
| `GET /api/info` | Returns service information and a UTC timestamp |

The backend also exposes the corresponding direct endpoints on port 8000.

## Repository Structure

```text
linux-web-infrastructure/
├── app/
│   ├── main.py
│   └── requirements.txt
├── deploy/
│   ├── nginx/
│   │   └── linux-web-infrastructure.conf
│   └── systemd/
│       └── linux-web-api.service
├── docs/
│   └── challenges/
│       └── 01-deployment-validation-and-rollback.md
├── scripts/
│   └── deploy-ubuntu.sh
├── site/
│   ├── index.html
│   ├── 404.html
│   └── favicon.svg
├── .gitignore
└── README.md
```

## Deployment

Run the deployment script from the repository root:

```bash
sudo bash scripts/deploy-ubuntu.sh
```

The script creates a backup under:

`/var/backups/linux-web-deploy.*`

Review the deployment output and verify both services after deployment.

## Validation

Check service status:

```bash
sudo systemctl is-active nginx linux-web-api
```

Check the application service identity:

```bash
sudo systemctl show linux-web-api -p User -p Group -p MainPID
```

Validate Nginx:

```bash
sudo nginx -t
```

Test the static website:

```bash
curl -i http://127.0.0.1:8080/
```

Test the backend directly:

```bash
curl -i http://127.0.0.1:8000/health
```

Test the API through Nginx:

```bash
curl -i http://127.0.0.1:8080/api/health
curl -i http://127.0.0.1:8080/api/info
```

Inspect application logs:

```bash
sudo journalctl -u linux-web-api -n 30 --no-pager
```

Inspect Nginx logs:

```bash
sudo tail -n 20 /var/log/nginx/linux-web-infrastructure.access.log
sudo tail -n 20 /var/log/nginx/linux-web-infrastructure.error.log
```

## Technologies

- Ubuntu Linux on WSL2
- Bash
- Nginx
- Python
- FastAPI
- Uvicorn
- systemd
- Git
- curl
- ShellCheck

## Operational Challenges

The first documented challenge is:

**Challenge 01: Deployment Validation and Rollback**

It simulates an invalid Python application deployment and verifies that
the deployment process detects the error and restores the previous
application files.

Evidence and details are documented in:

`docs/challenges/01-deployment-validation-and-rollback.md`

## Planned Milestones

1. HTTPS/TLS and certificate management.
2. Ansible configuration management.
3. Terraform infrastructure provisioning.
4. Prometheus monitoring and alerting.
5. Backup and recovery testing.
6. Additional operational incident simulations.

## Environment and Scope

The current implementation runs locally in WSL2 Ubuntu.

It is a learning and infrastructure engineering lab, not a production
deployment. Cloud deployment will be considered after security,
account access, and cost requirements are reviewed.
