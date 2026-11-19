# ---------------------------------------------------------------------------
# Remote state in Azure Storage.
#
# Chicken-and-egg: the storage account must exist BEFORE the first init.
# Create it once with scripts/bootstrap-tfstate.sh, then run:
#
#   terraform init -backend-config=backend.hcl
#
# Why remote state matters (classic interview question):
#   * the pipeline and your laptop must agree on one source of truth
#   * blob lease gives you state LOCKING, so two applies cannot race
#   * state contains secrets, so it needs encryption + RBAC + versioning
#   * use_azuread_auth avoids storing a storage account key anywhere
# ---------------------------------------------------------------------------
terraform {
  backend "azurerm" {
    use_azuread_auth = true
    # Remaining values come from backend.hcl so this file holds no
    # environment-specific data and can be shared across envs.
  }
}
