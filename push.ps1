#!/usr/bin/env pwsh
# Push script for ContosoERP Azure DevSecOps repository

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "ContosoERP - GitHub Push Script" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Check if repository exists on GitHub
Write-Host "Checking GitHub repository..." -ForegroundColor Yellow
$repoUrl = "https://github.com/Sauravambuskar/contosoerp-azure-devsecops"

Write-Host ""
Write-Host "IMPORTANT: Before pushing, create the repository on GitHub:" -ForegroundColor Red
Write-Host "1. Go to: https://github.com/new" -ForegroundColor White
Write-Host "2. Repository name: contosoerp-azure-devsecops" -ForegroundColor White
Write-Host "3. Description: Complete Azure DevSecOps platform with ERP application" -ForegroundColor White
Write-Host "4. Choose Public or Private" -ForegroundColor White
Write-Host "5. DO NOT initialize with README, .gitignore, or license" -ForegroundColor White
Write-Host "6. Click 'Create repository'" -ForegroundColor White
Write-Host ""

$confirm = Read-Host "Have you created the repository on GitHub? (y/n)"

if ($confirm -ne 'y') {
    Write-Host "Please create the repository first, then run this script again." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Pushing to GitHub..." -ForegroundColor Green

try {
    # Push to GitHub
    git push -u origin main
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "=========================================" -ForegroundColor Green
        Write-Host "✓ Successfully pushed to GitHub!" -ForegroundColor Green
        Write-Host "=========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Your repository is now available at:" -ForegroundColor Cyan
        Write-Host $repoUrl -ForegroundColor White
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Yellow
        Write-Host "1. Add repository topics (azure, devsecops, terraform, kubernetes, etc.)" -ForegroundColor White
        Write-Host "2. Enable Dependabot alerts in Security settings" -ForegroundColor White
        Write-Host "3. Configure branch protection rules if needed" -ForegroundColor White
        Write-Host "4. Share your repository with others!" -ForegroundColor White
        Write-Host ""
    } else {
        throw "Git push failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "✗ Push failed!" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible reasons:" -ForegroundColor Yellow
    Write-Host "1. Repository doesn't exist on GitHub yet" -ForegroundColor White
    Write-Host "2. You don't have permission to push to this repository" -ForegroundColor White
    Write-Host "3. Authentication failed - you may need to set up a personal access token" -ForegroundColor White
    Write-Host ""
    Write-Host "To set up authentication:" -ForegroundColor Yellow
    Write-Host "1. Generate a personal access token at: https://github.com/settings/tokens" -ForegroundColor White
    Write-Host "2. Use the token as your password when prompted" -ForegroundColor White
    Write-Host ""
    exit 1
}
