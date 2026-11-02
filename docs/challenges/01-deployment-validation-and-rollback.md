# Challenge 01: Deployment Validation and Rollback

## Scenario

A new application deployment contains invalid Python code.
The deployment must detect the problem before restarting the running
application and restore the previous deployment files.

This is a simulated laboratory incident, not a production incident.

## Environment

- OS: Ubuntu on WSL2
- Web server: Nginx
- Backend: FastAPI
- Application server: Uvicorn
- Process manager: systemd
- Service account: linux-web
- Deployment method: Bash deployment script

## Failure injection

A deliberate syntax error was added to app/main.py:

    printf '\nif:\n' >> app/main.py

The deployment script detected the changed application file and copied
it into the deployment directory.

## Symptoms

Python import validation failed with:

    SyntaxError: invalid syntax

The deployment stopped before restarting FastAPI.

## Root cause

The application source contained invalid Python syntax.

## Resolution

1. The deployment script detected the changed application file.
2. Python import validation detected the syntax error.
3. The ERR trap invoked the rollback function.
4. The previous production application files were restored.
5. The repository's original app/main.py was manually restored from the temporary backup.
6. The rollback backup was retained for investigation.

## Validation

- Python compilation succeeded.
- Nginx remained active.
- FastAPI remained active.
- FastAPI PID remained 29788.
- API health endpoint returned HTTP 200.
- Repository application source matched the deployed source.

## Prevention

- Validate application imports before restarting services.
- Run Python syntax checks before deployment.
- Keep deployment backups.
- Verify service health after deployment.
- Preserve deployment logs and rollback evidence.

## Remaining limitations

This test covered an application import failure.

Failures during Nginx reload, systemd restart, and other recovery
operations have not yet been tested.

The deployment script still uses best-effort rollback rather than
an atomic versioned-release deployment.
