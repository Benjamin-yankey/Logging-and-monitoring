pipeline {
    agent any
    
    tools {
        nodejs 'nodejs-20'
        terraform 'terraform-1.7'
    }

    parameters {
        booleanParam(name: 'AUTO_DEPLOY_INFRA', defaultValue: false, description: 'Automatically deploy AWS infrastructure with Terraform before app deployment')
        booleanParam(name: 'AUTO_DISCOVER_PARAMS', defaultValue: true, description: 'Automatically discover EC2 IPs from Terraform state')
        string(name: 'EC2_HOST', description: 'Address of the app server EC2 instance. Use Private IP (app_server_private_ip) for reliable inter-VPC deployment. Leave empty if AUTO_DISCOVER_PARAMS is true.', defaultValue: '')
        string(name: 'MONITORING_IP', description: 'Private IP of the monitoring server (from Terraform output: monitoring_server_private_ip). Leave empty if AUTO_DISCOVER_PARAMS is true.', defaultValue: '')
        string(name: 'TERRAFORM_STATE_BUCKET', description: 'S3 bucket name for Terraform state (optional - uses local state if empty)', defaultValue: '')
        choice(name: 'TERRAFORM_ACTION', choices: ['apply', 'plan', 'destroy'], description: 'Terraform action to perform')
        
        // Operational automation parameters
        booleanParam(name: 'DEPLOY_MONITORING', defaultValue: false, description: 'Deploy monitoring stack (Prometheus, Grafana, Jaeger)')
        string(name: 'MONITORING_SERVER_IP', description: 'Public IP of monitoring server (auto-discovered if empty)', defaultValue: '')
        booleanParam(name: 'RUN_BACKUP', defaultValue: false, description: 'Run application backup')
        string(name: 'S3_BACKUP_BUCKET', description: 'S3 bucket for backup storage (optional)', defaultValue: '')
        booleanParam(name: 'RUN_LOG_ROTATE', defaultValue: false, description: 'Run log rotation and cleanup')
        string(name: 'MAX_LOG_SIZE', description: 'Maximum log size in MB before rotation', defaultValue: '100')
        string(name: 'KEEP_IMAGES', description: 'Number of old Docker images to keep', defaultValue: '3')
    }

    environment {
        DOCKER_IMAGE = "cicd-node-app"
        DOCKER_TAG = "${BUILD_NUMBER}"
        REGISTRY = "docker.io"
        REGISTRY_CREDS = credentials('registry_creds')
        CONTAINER_NAME = "node-app"
        EC2_HOST = "${params.EC2_HOST}"
        MONITORING_IP = "${params.MONITORING_IP}"
        TF_STATE_BUCKET = "${params.TERRAFORM_STATE_BUCKET}"
    }
    
    stages {
        stage('Checkout') {
            steps {
                echo 'Checking out code from repository...'
                checkout scm
            }
        }
        
        stage('Discover Infrastructure') {
            when {
                expression { params.AUTO_DISCOVER_PARAMS }
            }
            steps {
                script {
                    echo 'Auto-discovering infrastructure from Terraform...'
                    def tfOutput = sh(script: 'cd terraform && terraform output -json 2>/dev/null || echo "{}"', returnStdout: true).trim()
                    
                    if (tfOutput != '{}' && tfOutput.contains('app_server_private_ip')) {
                        def outputJson = readJSON(text: tfOutput)
                        env.EC2_HOST = outputJson.app_server_private_ip.value
                        env.MONITORING_IP = outputJson.monitoring_server_private_ip.value
                        echo "Discovered EC2_HOST: ${env.EC2_HOST}"
                        echo "Discovered MONITORING_IP: ${env.MONITORING_IP}"
                    } else {
                        echo 'WARNING: Could not discover infrastructure. Terraform state not found or not initialized.'
                        echo 'Set AUTO_DEPLOY_INFRA to true or provide EC2_HOST and MONITORING_IP manually.'
                    }
                }
            }
        }
        
        stage('Deploy Infrastructure') {
            when {
                expression { params.AUTO_DEPLOY_INFRA }
            }
            steps {
                script {
                    echo 'Deploying AWS infrastructure with Terraform...'
                    
                    dir('terraform') {
                        // Initialize Terraform
                        sh '''
                            terraform init -upgrade
                        '''
                        
                        // Run Terraform plan
                        sh '''
                            terraform plan -out=tfplan -var-file=terraform.tfvars
                        '''
                        
                        // Apply or destroy based on parameter
                        if (params.TERRAFORM_ACTION == 'apply') {
                            sh '''
                                terraform apply -auto-approve tfplan
                            '''
                        } else if (params.TERRAFORM_ACTION == 'destroy') {
                            sh '''
                                terraform destroy -auto-approve -var-file=terraform.tfvars
                            '''
                        }
                        
                        // Output the applied state
                        sh '''
                            terraform output -json > ../terraform-output.json
                        '''
                    }
                    
                    // Read and set environment variables from Terraform output
                    def tfOutput = readJSON(file: 'terraform-output.json')
                    env.EC2_HOST = tfOutput.app_server_private_ip.value
                    env.MONITORING_IP = tfOutput.monitoring_server_private_ip.value
                    
                    echo "Infrastructure deployed successfully"
                    echo "App Server Private IP: ${env.EC2_HOST}"
                    echo "Monitoring Server Private IP: ${env.MONITORING_IP}"
                }
            }
        }
        
        stage('Install/Build') {
            steps {
                echo 'Installing dependencies...'
                sh '''
                    npm ci
                '''
            }
        }
        
        stage('Test') {
            steps {
                echo 'Running unit tests...'
                sh '''
                    npm test
                '''
            }
        }
        
        stage('Security Scan - Dependencies') {
            steps {
                echo 'Scanning dependencies for vulnerabilities...'
                sh '''
                    npm audit --audit-level=moderate || true
                    npm audit --json > npm-audit-report.json || true
                '''
                archiveArtifacts artifacts: 'npm-audit-report.json', allowEmptyArchive: true
            }
        }
        
        stage('Docker Build') {
            steps {
                echo 'Building Docker image...'
                sh '''
                    docker build -t ${DOCKER_IMAGE}:${DOCKER_TAG} .
                    docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:latest
                '''
            }
        }
        
        stage('Security Scan - Docker Image') {
            steps {
                echo 'Scanning Docker image for vulnerabilities...'
                sh '''
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                        aquasec/trivy:latest image \
                        --severity HIGH,CRITICAL \
                        --no-progress \
                        --format json \
                        --output trivy-report.json \
                        ${DOCKER_IMAGE}:${DOCKER_TAG} || true
                    
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                        aquasec/trivy:latest image \
                        --severity HIGH,CRITICAL \
                        --no-progress \
                        ${DOCKER_IMAGE}:${DOCKER_TAG} || true
                '''
                archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true
            }
        }
        
        stage('Push Image') {
            steps {
                echo 'Pushing image to registry...'
                sh '''
                    set +x
                    echo "$REGISTRY_CREDS_PSW" | docker login -u "$REGISTRY_CREDS_USR" --password-stdin 2>&1 | grep -v "WARNING"
                    set -x
                    docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:${DOCKER_TAG}
                    docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:latest
                    docker push $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:${DOCKER_TAG}
                    docker push $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:latest
                '''
            }
        }
        
        stage('Deploy') {
            when {
                expression { params.EC2_HOST?.trim() || params.AUTO_DISCOVER_PARAMS }
            }
            steps {
                script {
                    // Validate that we have the required IP addresses
                    if (!env.EC2_HOST?.trim()) {
                        error('EC2_HOST is not set. Either enable AUTO_DISCOVER_PARAMS or provide EC2_HOST parameter.')
                    }
                    if (!env.MONITORING_IP?.trim()) {
                        echo 'WARNING: MONITORING_IP not set. OpenTelemetry tracing will be disabled.'
                    }
                }
                
                echo "Deploying to EC2 host: ${env.EC2_HOST}..."
                withCredentials([sshUserPrivateKey(credentialsId: 'ec2_ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh '''
                        set +x
                        echo "Deploying to EC2 host: $EC2_HOST..."
                        
                        # Verify the key file exists (path provided by Jenkins)
                        if [ ! -f "$SSH_KEY" ]; then
                            echo "ERROR: SSH key file not found at $SSH_KEY"
                            exit 1
                        fi
                        
                        echo "Connecting as user: $SSH_USER"

                        # Fast preflight so failures are explicit and fail early.
                        if ! ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=accept-new \
                            -o UserKnownHostsFile=/dev/null \
                            -o LogLevel=ERROR \
                            -o ConnectTimeout=15 \
                            -o ConnectionAttempts=2 \
                            "$SSH_USER@$EC2_HOST" "echo 'SSH connectivity check passed'"; then
                            echo "ERROR: Unable to reach $EC2_HOST:22 from Jenkins."
                            echo "Hint: verify EC2_HOST and confirm app SG allows SSH from Jenkins SG."
                            exit 1
                        fi

                        # Optional registry login on the remote host (safe stdin, no Groovy interpolation).
                        printf '%s' "$REGISTRY_CREDS_PSW" | ssh -i "$SSH_KEY" \
                            -o StrictHostKeyChecking=accept-new \
                            -o UserKnownHostsFile=/dev/null \
                            -o LogLevel=ERROR \
                            "$SSH_USER@$EC2_HOST" "docker login -u '$REGISTRY_CREDS_USR' --password-stdin >/dev/null 2>&1 || true"
                        
                        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$SSH_USER@$EC2_HOST" << EOF
                            set +x
                            echo "Successfully connected to remote host!"
                            docker stop ${CONTAINER_NAME} || true
                            docker rm ${CONTAINER_NAME} || true
                            docker pull ${REGISTRY_CREDS_USR}/${DOCKER_IMAGE}:latest
                            docker run -d --name ${CONTAINER_NAME} \
                                -p 5000:5000 \
                                -e APP_VERSION=${DOCKER_TAG} \
                                -e OTEL_EXPORTER_OTLP_ENDPOINT=http://${MONITORING_IP}:4318/v1/traces \
                                ${REGISTRY_CREDS_USR}/${DOCKER_IMAGE}:latest
                            docker ps
                            echo "Deployment complete"
EOF
                    '''
                }
            }
        }
    }
    
    // Operational Automation Stages - Run independently via separate jobs or with parameters
    stage('Deploy Monitoring Stack') {
        when {
            expression { params.DEPLOY_MONITORING == true }
        }
        steps {
            script {
                echo 'Deploying monitoring stack...'
                
                // Discover monitoring server IP if not provided
                def monitoringIP = params.MONITORING_SERVER_IP
                if (!monitoringIP && params.AUTO_DISCOVER_PARAMS) {
                    def tfOutput = sh(script: 'cd terraform && terraform output -json 2>/dev/null || echo "{}"', returnStdout: true).trim()
                    if (tfOutput != '{}') {
                        def outputJson = readJSON(text: tfOutput)
                        monitoringIP = outputJson.monitoring_server_public_ip.value
                    }
                }
                
                if (!monitoringIP) {
                    error('MONITORING_SERVER_IP is required. Set DEPLOY_MONITORING to false or provide the IP.')
                }
                
                withCredentials([sshUserPrivateKey(credentialsId: 'ec2_ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh """
                        # Make deployment script executable
                        chmod +x terraform/scripts/monitoring-deploy.sh
                        
                        # Run monitoring deployment
                        ./terraform/scripts/monitoring-deploy.sh \
                            -i ${monitoringIP} \
                            -k ${SSH_KEY} \
                            -u ${SSH_USER}
                    """
                }
            }
        }
    }
    
    stage('Backup') {
        when {
            expression { params.RUN_BACKUP == true }
        }
        steps {
            script {
                echo 'Running application backup...'
                
                // Get app server IP
                def appIP = env.EC2_HOST
                if (!appIP && params.AUTO_DISCOVER_PARAMS) {
                    def tfOutput = sh(script: 'cd terraform && terraform output -json 2>/dev/null || echo "{}"', returnStdout: true).trim()
                    if (tfOutput != '{}') {
                        def outputJson = readJSON(text: tfOutput)
                        appIP = outputJson.app_server_public_ip.value
                    }
                }
                
                if (!appIP) {
                    error('App server IP not available. Cannot perform backup.')
                }
                
                withCredentials([sshUserPrivateKey(credentialsId: 'ec2_ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh """
                        chmod +x scripts/backup.sh
                        ./scripts/backup.sh \
                            --app-server ${appIP} \
                            --ssh-key ${SSH_KEY} \
                            --s3-bucket "${params.S3_BACKUP_BUCKET}" \
                            --keep-local
                    """
                }
            }
        }
    }
    
    stage('Log Rotation') {
        when {
            expression { params.RUN_LOG_ROTATE == true }
        }
        steps {
            script {
                echo 'Running log rotation and cleanup...'
                
                // Get app server IP
                def appIP = env.EC2_HOST
                if (!appIP && params.AUTO_DISCOVER_PARAMS) {
                    def tfOutput = sh(script: 'cd terraform && terraform output -json 2>/dev/null || echo "{}"', returnStdout: true).trim()
                    if (tfOutput != '{}') {
                        def outputJson = readJSON(text: tfOutput)
                        appIP = outputJson.app_server_public_ip.value
                    }
                }
                
                if (!appIP) {
                    error('App server IP not available. Cannot run log rotation.')
                }
                
                withCredentials([sshUserPrivateKey(credentialsId: 'ec2_ssh', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh """
                        chmod +x scripts/log-rotate.sh
                        ./scripts/log-rotate.sh \
                            --app-server ${appIP} \
                            --ssh-key ${SSH_KEY} \
                            --max-log-size ${params.MAX_LOG_SIZE} \
                            --keep-images ${params.KEEP_IMAGES}
                    """
                }
            }
        }
    }
    
    post {
        always {
            echo 'Cleaning up local Docker images...'
            sh '''
                docker rmi ${DOCKER_IMAGE}:${DOCKER_TAG} || true
                docker rmi ${DOCKER_IMAGE}:latest || true
                docker rmi $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:${DOCKER_TAG} || true
                docker rmi $REGISTRY_CREDS_USR/${DOCKER_IMAGE}:latest || true
            '''
        }
        success {
            script {
                sendSlackNotification('SUCCESS')
            }
        }
        failure {
            script {
                sendSlackNotification('FAILURE')
            }
        }
    }
}

def sendSlackNotification(String buildStatus) {
    def color = buildStatus == 'SUCCESS' ? '#36a64f' : '#eb4034'
    def headline = buildStatus == 'SUCCESS' ? "Build Successful" : "Build Failed"
    def channel = "#yram" // Update this to your Slack channel name
    
    // Get Git details
    def commitShort = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
    def commitAuthor = sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()
    
    // Prepare security scan summary
    def scanResults = "Trivy: High/Critical Scan Completed\nNPM Audit: Moderate/Above Scan Completed"
    def errorBlock = buildStatus == 'FAILURE' ? "\n*Error:* Build or deployment failed. Please check the logs.\n" : ""
    def imagePath = "${env.REGISTRY_CREDS_USR}/${env.DOCKER_IMAGE}:${env.DOCKER_TAG}"
    
    // Infrastructure info
    def infraInfo = env.EC2_HOST ? "\n*App Server:* ${env.EC2_HOST}" : ""
    infraInfo += env.MONITORING_IP ? "\n*Monitoring:* ${env.MONITORING_IP}" : ""
    
    // Automation summary
    def autoSummary = ""
    if (params.AUTO_DEPLOY_INFRA) autoSummary += "\n• Terraform: ${params.TERRAFORM_ACTION}"
    if (params.DEPLOY_MONITORING) autoSummary += "\n• Monitoring: Deploying"
    if (params.RUN_BACKUP) autoSummary += "\n• Backup: Running"
    if (params.RUN_LOG_ROTATE) autoSummary += "\n• Log Rotation: Running"
    def autoBlock = autoSummary ? "\n─────────────────────────────────────\nAutomation${autoSummary}" : ""

    slackSend(
        channel: channel,
        color: color,
        tokenCredentialId: 'slack-tokens',
        message: """
${headline}

Build:      #${env.BUILD_NUMBER}
Branch:     ${env.GIT_BRANCH ?: 'main'}
Commit:     ${commitShort} by ${commitAuthor}
Image:      ${imagePath}
Duration:   ${currentBuild.durationString}

─────────────────────────────────────
Security Scan Results
─────────────────────────────────────
${scanResults}
${errorBlock}
─────────────────────────────────────
Reports
─────────────────────────────────────
npm audit: ${env.BUILD_URL}artifact/npm-audit-report.json
Trivy    : ${env.BUILD_URL}artifact/trivy-report.json

Build    : ${env.BUILD_URL}
Logs     : ${env.BUILD_URL}console
        """.stripIndent()
    )
}
