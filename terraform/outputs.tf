output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "acr_login_server" {
  description = "ACR login server URL — set as ACR_LOGIN_SERVER in GitHub Secrets"
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "ACR short name — set as ACR_NAME in GitHub Secrets"
  value       = azurerm_container_registry.acr.name
}

output "storage_account_name" {
  value = azurerm_storage_account.models.name
}

output "storage_account_key" {
  description = "Primary access key for the models storage account (sensitive)"
  value       = azurerm_storage_account.models.primary_access_key
  sensitive   = true
}

output "kube_config" {
  description = "Raw kubeconfig — use: terraform output -raw kube_config > ~/.kube/config"
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}
