variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "weather-ml-rg"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "weather-ml-aks"
}

variable "acr_name" {
  description = "Azure Container Registry name (globally unique, 5-50 alphanumeric chars)"
  type        = string
  default     = "weathermlacr"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS"
  type        = string
  default     = "1.29"
}

variable "storage_account_name" {
  description = "Storage account for Azure Files PVC that holds model.pkl (globally unique)"
  type        = string
  default     = "weathermlmodels"
}
