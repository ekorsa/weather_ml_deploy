terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Uncomment to store state in Azure Blob Storage
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstateweatherml"
  #   container_name       = "tfstate"
  #   key                  = "weather-ml.tfstate"
  # }
}

provider "azurerm" {
  features {}
}
