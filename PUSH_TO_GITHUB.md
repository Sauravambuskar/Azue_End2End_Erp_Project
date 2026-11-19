# How to Push to GitHub

## Step 1: Create the Repository

1. Go to https://github.com/new
2. Repository name: **contosoerp-azure-devsecops**
3. Description: **Complete Azure DevSecOps platform with ERP application - AKS, Terraform, CI/CD pipelines, and comprehensive security scanning**
4. Choose Public or Private
5. **DO NOT** check "Initialize this repository with a README"
6. Click "Create repository"

## Step 2: Push Your Code

After creating the repository, run these commands:

```powershell
# Add the remote repository (replace YOUR-USERNAME with your GitHub username)
git remote add origin https://github.com/YOUR-USERNAME/contosoerp-azure-devsecops.git

# Verify the remote
git remote -v

# Push to GitHub
git push -u origin master
```

Alternatively, if you prefer to push to 'main' branch:

```powershell
# Rename master to main
git branch -M main

# Add the remote
git remote add origin https://github.com/YOUR-USERNAME/contosoerp-azure-devsecops.git

# Push to GitHub
git push -u origin main
```

## Step 3: Add Repository Topics

On your GitHub repository page:

1. Click "About" settings (gear icon)
2. Add these topics:
   - azure
   - devsecops
   - terraform
   - kubernetes
   - aks
   - azure-devops
   - cicd
   - security
   - infrastructure-as-code
   - helm
   - docker
   - postgresql
   - fastapi
   - devops
   - interview-prep

## Step 4: Enable GitHub Actions (Optional)

If you want to enable the validation workflow:

1. Go to the "Actions" tab
2. Enable workflows if prompted
3. The validation workflow will run on pull requests

## Step 5: Customize Repository Settings

Consider these settings:

1. **Security → Dependabot**: Enable Dependabot alerts and security updates
2. **Settings → Branches**: Add branch protection rules for main/master
3. **Settings → Actions**: Configure Actions permissions if using workflows
4. **Settings → General**: Enable issues, discussions, wiki as needed

## Verification

After pushing, verify:

```powershell
# Check remote status
git remote -v

# Check branch tracking
git branch -vv

# Verify everything is pushed
git status
```

Your repository should now be live at:
`https://github.com/YOUR-USERNAME/contosoerp-azure-devsecops`

## Quick Command Reference

```powershell
# If you already know your GitHub username, run this:
$githubUser = "YOUR-USERNAME"
git remote add origin "https://github.com/$githubUser/contosoerp-azure-devsecops.git"
git branch -M main
git push -u origin main
```
