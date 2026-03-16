# Architecture Guide

This document provides a detailed explanation of the architecture diagrams for the CI/CD pipeline and the Observability stack.

## 1. CI/CD Pipeline Architecture
**File:** `architecture-diagram.png`

The CI/CD pipeline automates the process of building, testing, and deploying the Node.js application to AWS infrastructure.

### Workflow Stages:
1.  **Source Control (GitHub):** Developers push code changes to the GitHub repository.
2.  **CI Server (Jenkins on EC2):** 
    *   Jenkins is triggered by GitHub webhooks.
    *   Runs inside a Docker container on an AWS EC2 instance.
    *   **Checkout:** Clones the latest code from GitHub.
    *   **Install:** Runs `npm ci` to install dependencies.
    *   **Test:** Executes unit tests using Jest (`npm test`).
    *   **Security Scan (SCA):** Runs `npm audit` to check for dependency vulnerabilities.
3.  **Containerization (Docker):**
    *   **Build:** Creates a Docker image of the application.
    *   **Scan:** Uses **Trivy** to scan the Docker image for OS-level and library vulnerabilities.
    *   **Push:** Tags and pushes the verified image to **Docker Hub**.
4.  **Deployment (App Server on EC2):**
    *   Jenkins uses SSH to connect to the Application Server.
    *   It pulls the latest image from Docker Hub and restarts the containerized application.

---

## 2. Observability & Monitoring Architecture
**File:** `architecture-observability.png`

The observability stack provides deep insights into the application's health, performance (RED metrics), and distributed tracing.

### Core Components:
1.  **Application (Node.js):**
    *   Instrumented with **OpenTelemetry (OTEL)** for tracing.
    *   Exposes a `/metrics` endpoint for Prometheus.
    *   Generates structured JSON logs with correlated Trace IDs.
2.  **Metrics (Prometheus):**
    *   Scrapes metrics from the App Server (port 5000) and Node Exporter (port 9100).
    *   Tracks **RED Metrics**: Rate (requests/sec), Errors (5xx/4xx), and Duration (latency).
    *   Evaluates **Alert Rules** (e.g., High Error Rate > 5%).
3.  **Tracing (Jaeger):**
    *   Receives OTLP (OpenTelemetry Protocol) spans from the application.
    *   Visualizes request paths and identifies latency bottlenecks across services.
4.  **Visualization (Grafana):**
    *   Connects to Prometheus as a data source.
    *   Provides a centralized dashboard for real-time monitoring of system health and application performance.
5.  **Alerting (Alertmanager):**
    *   Receives alerts from Prometheus and routes them to notification channels (e.g., Email, Slack).
6.  **Infrastructure Security (AWS GuardDuty):**
    *   Monitors CloudTrail logs and VPC Flow Logs for malicious activity or unauthorized access.

---

## 3. Infrastructure Overview
The entire environment is provisioned using **Terraform**, ensuring a consistent and reproducible setup:

*   **Network:** VPC with public/private subnets, Internet Gateway, and Route Tables.
*   **Security:** Least-privilege Security Groups restricting access to specific IPs and ports.
*   **Compute:** EC2 instances for Jenkins, Application, and Monitoring servers.
*   **Secrets:** AWS Secrets Manager for managing sensitive credentials.
