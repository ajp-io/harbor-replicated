# Harbor for Replicated

A Harbor deployment package for [Replicated](https://replicated.com), enabling easy installation and management of Harbor through the Replicated platform.

Harbor is an open source registry that secures artifacts with policies and role-based access control, ensures images are scanned and free from vulnerabilities, and signs images as trusted.

[Overview of Harbor](https://goharbor.io/)

## Overview

This package provides a complete Harbor deployment for Kubernetes environments using Replicated's application distribution platform. It includes:

- Pre-configured Harbor deployment with PostgreSQL database and Redis
- Integrated configuration management through KOTS
- Support for airgap installations with image proxying
- Embedded cluster compatibility

## Installation

This application is designed to be installed through Replicated's distribution platform:

1. **Embedded Cluster**: Deploy as a complete Kubernetes cluster with Harbor included
2. **Existing Cluster**: Install into an existing Kubernetes cluster using KOTS
3. **Helm**: Install directly using Helm charts in supported environments

## Configuration

Configuration is managed through the Replicated Admin Console, which provides a web-based interface for:

### Harbor Settings
- **Admin Password**: Set the initial Harbor administrator password

### Database Configuration
- **Database Type**: Choose between embedded PostgreSQL or external database
- **Embedded PostgreSQL**: Configure password for the built-in database
- **External PostgreSQL**: Connect to an existing PostgreSQL server with host, port, database, credentials, and SSL settings

## Components

This package includes:

- **Harbor Core**: The main container registry application
- **Harbor Portal**: Web UI for Harbor management
- **Harbor Registry**: Docker registry implementation
- **Harbor Jobservice**: Background job processing
- **Trivy**: Vulnerability scanner for container images
- **PostgreSQL**: Database backend for Harbor
- **Redis**: Cache and session storage
- **KOTS Configuration**: Replicated-specific configuration management
- **Embedded Cluster Support**: Complete Kubernetes distribution option

## Requirements

### For Existing Kubernetes Clusters
- Kubernetes 1.30+ (1.31+ recommended)
- Sufficient storage for container images and database

### For Embedded Cluster
- Minimum system requirements as defined in embedded cluster configuration

## Support

This Harbor package is distributed through Replicated. For support:

- Contact your Replicated administrator
- Refer to [Harbor documentation](https://goharbor.io/docs/) for application-specific questions
- Check [Replicated documentation](https://docs.replicated.com/) for platform-specific issues

## License

This Harbor package is subject to Harbor's Apache 2.0 license and Replicated's terms of service.