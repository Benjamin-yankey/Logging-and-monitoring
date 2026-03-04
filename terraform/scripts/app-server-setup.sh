#!/bin/bash
set -e

# Log all output
exec > >(tee /var/log/app-server-setup.log) 2>&1
echo "Starting app server setup at $(date)"

yum update -y
yum install -y docker git

# Start Docker service
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create application directory
mkdir -p /opt/app
chown -R ec2-user:ec2-user /opt/app

# Create a startup script that uses AWS CloudWatch logs for the container
cat > /opt/app/start-app.sh << 'APPSTART'
#!/bin/bash
# Template variables: project_name=${project_name}, environment=${environment}, aws_region=${aws_region}

REGISTRY_CREDS_USR="${1:-}"
REGISTRY_CREDS_PSW="${2:-}"
CONTAINER_NAME="node-app"
DOCKER_IMAGE="cicd-node-app"
LOG_GROUP="/${project_name}/${environment}/app"

# Login to registry if credentials provided
if [ -n "$REGISTRY_CREDS_USR" ]; then
    echo "$REGISTRY_CREDS_PSW" | docker login -u "$REGISTRY_CREDS_USR" --password-stdin
    docker pull "$REGISTRY_CREDS_USR/$DOCKER_IMAGE:latest"
    IMAGE_NAME="$REGISTRY_CREDS_USR/$DOCKER_IMAGE:latest"
else
    # Fallback for local testing or pre-pulled image
    IMAGE_NAME="$DOCKER_IMAGE:latest"
fi

# Stop and remove existing container
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true

# Run the container with CloudWatch logs streaming
docker run -d \
  --name $CONTAINER_NAME \
  -p 5000:5000 \
  --log-driver=awslogs \
  --log-opt awslogs-region=${aws_region} \
  --log-opt awslogs-group=$LOG_GROUP \
  --log-opt awslogs-stream=$CONTAINER_NAME \
  $IMAGE_NAME

echo "Application deployed successfully on port 5000 with CloudWatch logs streaming"
APPSTART

chmod +x /opt/app/start-app.sh
chown ec2-user:ec2-user /opt/app/start-app.sh

# Run Node Exporter for Prometheus scraping
docker run -d \
  --name node-exporter \
  --restart=unless-stopped \
  --network="host" \
  --pid="host" \
  -v "/:/host:ro,rslave" \
  prom/node-exporter:latest \
  --path.rootfs=/host \
  --web.listen-address=0.0.0.0:9100

echo "Node Exporter running on port 9100"
echo "App server setup completed at $(date)"
