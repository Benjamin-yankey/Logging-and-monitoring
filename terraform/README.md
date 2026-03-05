# Terraform Infrastructure

This directory contains the Infrastructure as Code (IaC) configuration using Terraform to provision and manage AWS resources.

## Structure

- `main.tf`: The primary entry point for the Terraform configuration, orchestrating the modules.
- `variables.tf`: Input variable definitions for the infrastructure.
- `outputs.tf`: Output value definitions.
- `terraform.tfvars`: Project-specific variable values.
- `modules/`: Reusable Terraform modules for various infrastructure components.
- `scripts/`: Initialization and setup scripts for provisioned instances.
