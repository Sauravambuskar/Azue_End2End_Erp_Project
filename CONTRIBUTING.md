# Contributing to ContosoERP

Thank you for your interest in contributing! This project is primarily a learning platform for Azure DevSecOps, but contributions are welcome.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR-USERNAME/contosoerp-azure-devsecops.git`
3. Create a feature branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Run validation: `./scripts/validate-local.sh`
6. Commit your changes with a descriptive message
7. Push to your fork: `git push origin feature/your-feature-name`
8. Open a Pull Request

## Development Workflow

### Local Testing

Before submitting a PR, ensure all local checks pass:

```bash
# Run the complete validation suite
./scripts/validate-local.sh

# Run specific checks
pytest src/erp-api/tests/
pytest src/erp-worker/tests/
npm test --prefix src/erp-web
```

### Code Style

- **Python**: Follow PEP 8. Use `ruff` for linting and formatting.
- **JavaScript**: Follow the project's ESLint configuration.
- **Terraform**: Use `terraform fmt` for consistent formatting.
- **Shell scripts**: Use ShellCheck for validation.

### Commit Messages

Write clear, descriptive commit messages:

```
Short summary (50 chars or less)

Longer explanation if needed. Wrap at 72 characters.
Explain what and why, not how.

- Bullet points are okay
- Use present tense: "Add feature" not "Added feature"
```

## Pull Request Guidelines

1. **Keep PRs focused**: One feature or fix per PR
2. **Update documentation**: If your changes affect usage, update the docs
3. **Add tests**: New features should include tests
4. **Security**: Run security scans and address findings
5. **No secrets**: Never commit secrets, tokens, or credentials

## Security

If you discover a security vulnerability, please email the maintainer privately rather than opening a public issue.

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Focus on the code, not the person
- Help others learn

## Questions?

Open an issue with the `question` label if you need help or clarification.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
