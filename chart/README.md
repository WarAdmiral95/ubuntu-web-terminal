# ubuntu-web-terminal Helm chart

Browser-based Ubuntu 24.04 terminal (ttyd), one pod per release, with optional ALB + Cognito (OIDC) login on EKS.

See the [main README](../README.md) for the image, local KIND setup, deployment modes, Cognito setup, values reference and troubleshooting.

```bash
helm upgrade --install ubuntu1 . -n web-terminal --create-namespace
```
