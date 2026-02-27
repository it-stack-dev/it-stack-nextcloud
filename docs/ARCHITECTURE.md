# Architecture — IT-Stack NEXTCLOUD

## Overview

Nextcloud provides file storage, WebDAV, CalDAV, CardDAV, and collaborative office document editing for the entire organization.

## Role in IT-Stack

- **Category:** collaboration
- **Phase:** 2
- **Server:** lab-app1 (10.0.50.13)
- **Ports:** 80 (HTTP), 443 (HTTPS)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → nextcloud → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
