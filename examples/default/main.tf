terraform {
  required_version = "~> 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  tags = {
    scenario = "default"
  }
}

## Section to provide a random Azure region for the resource group
# This allows us to randomize the region for the resource group.
module "regions" {
  source  = "Azure/regions/azurerm"
  version = "0.8.2"
}

# This allows us to randomize the region for the resource group.
resource "random_integer" "region_index" {
  max = length(module.regions.regions) - 1
  min = 0
}
## End of section to provide a random Azure region for the resource group

# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}

# This is required for resource modules
resource "azurerm_resource_group" "this" {
  location = module.regions.regions[random_integer.region_index.result].name
  name     = module.naming.resource_group.name_unique
}

# create a virtual network
resource "azurerm_virtual_network" "this" {
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.this.location
  name                = "endppoint-vnet"
  resource_group_name = azurerm_resource_group.this.name
}

# create a subnet for the private endpoint
resource "azurerm_subnet" "endpoint" {
  address_prefixes     = ["10.0.2.0/24"]
  name                 = "endpoint"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
}

resource "azurerm_private_dns_zone" "this" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_log_analytics_workspace" "this_workspace" {
  location            = azurerm_resource_group.this.location
  name                = module.naming.log_analytics_workspace.name_unique
  resource_group_name = azurerm_resource_group.this.name
  retention_in_days   = 30
  sku                 = "PerGB2018"
  tags                = local.tags
}

# This is the module call
module "default" {
  source = "../../"
  # source             = "Azure/avm-res-cache-redis/azurerm"
  # version            = "0.4.0"

  enable_telemetry              = var.enable_telemetry
  name                          = module.naming.redis_cache.name_unique
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  public_network_access_enabled = false
  private_endpoints = {
    endpoint1 = {
      subnet_resource_id            = azurerm_subnet.endpoint.id
      private_dns_zone_group_name   = "private-dns-zone-group"
      private_dns_zone_resource_ids = [azurerm_private_dns_zone.this.id]
    }
  }

  diagnostic_settings = {
    diag_setting_1 = {
      name                           = "diagSetting1"
      log_groups                     = ["allLogs"]
      metric_categories              = ["AllMetrics"]
      log_analytics_destination_type = null
      workspace_resource_id          = azurerm_log_analytics_workspace.this_workspace.id
    }
  }

  redis_configuration = {
    maxmemory_reserved = 1330
    maxmemory_delta    = 1330
    maxmemory_policy   = "allkeys-lru"
  }
  /*
  lock = {
    kind = "CanNotDelete"
    name = "Delete"
  }
  */

  managed_identities = {
    system_assigned = true
  }

  tags = local.tags
}
