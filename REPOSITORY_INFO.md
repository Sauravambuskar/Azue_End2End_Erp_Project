# Repository Information

## Repository Details

- **Name**: contosoerp-azure-devsecops
- **URL**: https://github.com/Sauravambuskar/contosoerp-azure-devsecops
- **Description**: Complete Azure DevSecOps platform with ERP application - AKS, Terraform, CI/CD pipelines, and comprehensive security scanning
- **Owner**: Saurav Ambuskar (@Sauravambuskar)

## Repository Statistics

- **Total Files**: 202+
- **Lines of Code**: 30,000+
- **Languages**: 
  - Python (FastAPI, SQLAlchemy)
  - JavaScript/Node.js (Express)
  - HCL (Terraform)
  - Bicep
  - YAML (Kubernetes, Helm, Pipelines)
  - Shell scripts

## What's Included

### Infrastructure (IaC)
- ✅ 11 Terraform modules (networking, AKS, PostgreSQL, Key Vault, etc.)
- ✅ Bicep alternative implementation
- ✅ Hub-spoke network topology
- ✅ VNet-injected PostgreSQL
- ✅ Workload identity federation
- ✅ Azure Firewall and App Gateway configurations

### Application
- ✅ FastAPI backend (10 tests, all passing)
- ✅ Node.js/Express frontend (19 tests, all passing)
- ✅ Python worker with CronJob (18 tests, all passing)
- ✅ PostgreSQL with 3 migration versions
- ✅ Passwordless authentication everywhere
- ✅ Complete ERP domain (products, orders, inventory, ledger)

### Kubernetes
- ✅ Helm chart with 22 rendered objects
- ✅ NetworkPolicy (default-deny + IMDS block)
- ✅ HPA and PDB
- ✅ CSI Secret Store integration
- ✅ Service accounts with workload identity
- ✅ Pod Security Admission (restricted)

### CI/CD & DevSecOps
- ✅ Azure Pipelines YAML
- ✅ 9 reusable pipeline templates
- ✅ Security gates: gitleaks, semgrep, checkov, bandit
- ✅ Build, scan, and push workflow
- ✅ Atomic deployment with rollback
- ✅ Approval gates for production

### Documentation
- ✅ 16 guidance chapters
- ✅ 5 cheat sheets (az, kubectl, terraform, KQL, troubleshooting)
- ✅ 3 checklists (JD coverage, daily practice, pre-interview)
- ✅ Comprehensive README with architecture diagrams

### Security
- ✅ Custom gitleaks rules for Azure
- ✅ 9 custom semgrep rules
- ✅ OWASP ZAP configuration
- ✅ checkov IaC scanning (132 checks passed)
- ✅ Non-root container images
- ✅ No hardcoded secrets

### Governance
- ✅ 4 custom Azure Policy definitions
- ✅ Landing zone baseline initiative
- ✅ Mandatory tagging enforcement
- ✅ Regional and SKU restrictions

## Repository Topics

Add these topics to improve discoverability:

```
azure, devsecops, terraform, kubernetes, aks, azure-devops, cicd, 
security, infrastructure-as-code, helm, docker, postgresql, fastapi, 
devops, interview-prep, azure-security, cloud-native, gitops, 
devsecops-pipeline, azure-kubernetes-service
```

## Local Validation Status

All checks passing:
- ✅ 47 tests (10 API + 18 worker + 19 web)
- ✅ Terraform validate & fmt
- ✅ Bicep build
- ✅ Helm lint & template
- ✅ Python linting (ruff, bandit)
- ✅ JavaScript linting (eslint)
- ✅ Security scanning (gitleaks, semgrep, checkov)
- ✅ YAML validation
- ✅ Markdown link checking
- ✅ Shell script validation

## Cost Information

- **Running**: ~$4-6/day (2 AKS nodes, B1ms PostgreSQL)
- **Stopped**: ~$0.30/day (AKS stopped, PostgreSQL stopped)
- **Azure Free Credit**: $200/30 days covers the entire project

## License

MIT License - See [LICENSE](./LICENSE) file

## Getting Started

```bash
# Clone the repository
git clone https://github.com/Sauravambuskar/contosoerp-azure-devsecops.git
cd contosoerp-azure-devsecops

# Start locally with Docker
docker compose up -d

# Run all validation checks
./scripts/validate-local.sh
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

## Support

- 📖 [Documentation](./guidance/00-START-HERE.md)
- 🐛 [Report Bug](https://github.com/Sauravambuskar/contosoerp-azure-devsecops/issues/new?template=bug_report.md)
- 💡 [Request Feature](https://github.com/Sauravambuskar/contosoerp-azure-devsecops/issues/new?template=feature_request.md)

---

**Built for interview preparation and hands-on Azure DevSecOps learning.**
