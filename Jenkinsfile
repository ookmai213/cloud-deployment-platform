pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        IMAGE_NAME = 'linux-web-api'
        RELEASE_TAG = ''
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.RELEASE_TAG = sh(
                        returnStdout: true,
                        script: 'git rev-parse HEAD'
                    ).trim()
                }
            }
        }

        stage('Python tests') {
            steps {
                sh '''
                    python3 -m venv .jenkins-venv
                    . .jenkins-venv/bin/activate
                    python -m pip install --disable-pip-version-check -r requirements-dev.txt
                    python -m pytest -q
                '''
            }
        }

        stage('Shell validation') {
            steps {
                sh '''
                    bash -n scripts/deploy-ubuntu.sh scripts/deploy-container.sh
                    bash -n scripts/test-full-rollback-isolated.sh tests/test_deploy_container.sh
                    shellcheck scripts/deploy-ubuntu.sh scripts/deploy-container.sh
                    bash scripts/test-full-rollback-isolated.sh scripts/deploy-ubuntu.sh
                    bash tests/test_deploy_container.sh
                '''
            }
        }

        stage('Build container image') {
            steps {
                sh '''
                    docker build \
                      --file deploy/docker/Dockerfile \
                      --build-arg APP_VERSION="${RELEASE_TAG}" \
                      --tag "${IMAGE_NAME}:${RELEASE_TAG}" \
                      .
                '''
            }
        }

        stage('Publish image (opt-in)') {
            when {
                expression { return env.JENKINS_PUBLISH_IMAGE == 'true' }
            }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'container-registry',
                    usernameVariable: 'REGISTRY_USER',
                    passwordVariable: 'REGISTRY_TOKEN'
                )]) {
                    sh '''
                        set +x
                        printf '%s' "$REGISTRY_TOKEN" |
                          docker login "$CONTAINER_REGISTRY" --username "$REGISTRY_USER" --password-stdin
                        docker tag "${IMAGE_NAME}:${RELEASE_TAG}" \
                          "${CONTAINER_REGISTRY}/${IMAGE_NAME}:${RELEASE_TAG}"
                        docker push "${CONTAINER_REGISTRY}/${IMAGE_NAME}:${RELEASE_TAG}"
                        docker logout "$CONTAINER_REGISTRY"
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'docker logout "${CONTAINER_REGISTRY:-localhost}" >/dev/null 2>&1 || true'
            deleteDir()
        }
    }
}
