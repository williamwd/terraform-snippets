# NOT READY TO USE:
# This code is not ready to use, read the comments and change accordingly

locals {
  #
  #
  # Ideally we define these values outside this module and pass them as variables
  # This is why we refer to them below as variables :)
  #
  #
  azure_vnet_cidr = ["172.30.0.0/16"]
  # The name "GatewaySubnet" is mandatory for the VPN
  # Only one "GatewaySubnet" is allowed per vNet
  azure_private_subnet_cidr = {
    "some_subnet" = {
      "subnet"                                         = ["172.30.40.0/24"]
      "enforce_private_link_endpoint_network_policies" = true
      "network_security_group"                         = "some_nsg"
    }
    "GatewaySubnet" = {
      "subnet"                                         = ["172.30.2.0/24"]
      "enforce_private_link_endpoint_network_policies" = false
    }
  }
  # Define Network security groups and their subnet associations
  # ref. https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule
  # 
  azure_nsgs = {
    "some_nsg" = { #<=== This will be the name of the NSG
      "ssh_inbound" = {
        "source_port"      = "*"
        "source_cidr"      = "VirtualNetwork"
        "destination_port" = "22"
        "destination_cidr" = "VirtualNetwork"
        "protocol"         = "Tcp"
        "direction"        = "Inbound"
        "access"           = "Allow"
        "priority"         = 4000
      }
      "https" = {
        "source_port"      = "*"
        "source_cidr"      = "VirtualNetwork"
        "destination_port" = "443"
        "destination_cidr" = "VirtualNetwork"
        "protocol"         = "Tcp"
        "direction"        = "Inbound"
        "access"           = "Allow"
        "priority"         = 4001
      }
    }
  }
  #
  #
  # The values above should be defined outside the module for better management
  #
  #


  # flatten ensures that this local value is a flat list of objects, rather
  # than a list of lists of objects.
  nsg_rules = flatten([
    for nsg_name, nsg_rule in var.azure_nsgs : [
      for rule_name, rule_attributes in nsg_rule : {
        "nsg_name"         = nsg_name
        "rule_name"        = rule_name
        "source_port"      = rule_attributes.source_port
        "source_cidr"      = rule_attributes.source_cidr
        "destination_port" = rule_attributes.destination_port
        "destination_cidr" = rule_attributes.destination_cidr
        "protocol"         = rule_attributes.protocol
        "direction"        = rule_attributes.direction
        "access"           = rule_attributes.access
        "priority"         = rule_attributes.priority
      }
    ]
  ])
  # We cannot assign NSGs to GatewaySubnet
  subnet_nsg = [
    for subnet_name, subnet_attributes in var.azure_private_subnet_cidr : {
      "subnet_name" = subnet_name
      "subnet_id"   = azurerm_subnet.subnet[subnet_name].id
      "nsg_name"    = subnet_attributes.network_security_group
      "nsg_id"      = azurerm_network_security_group.nsg[subnet_attributes.network_security_group].id
    } if subnet_name != "GatewaySubnet"
  ]
}

# Map the correct Resource group
data "azurerm_resource_group" "resource_group" {
  name = "RG_NAME"
}


resource "azurerm_virtual_network" "vnet" {
  name                = "${data.azurerm_resource_group.resource_group.name}_vnet"
  location            = data.azurerm_resource_group.resource_group.location
  resource_group_name = data.azurerm_resource_group.resource_group.name
  address_space       = var.azure_vnet_cidr
}

# The name "GatewaySubnet" is mandatory for the VPN
# Only one "GatewaySubnet" is allowed per vNet
resource "azurerm_subnet" "subnet" {
  for_each                                       = var.azure_private_subnet_cidr
  name                                           = each.key
  resource_group_name                            = data.azurerm_resource_group.resource_group.name
  virtual_network_name                           = azurerm_virtual_network.vnet.name
  address_prefixes                               = each.value["subnet"]
  enforce_private_link_endpoint_network_policies = each.value["enforce_private_link_endpoint_network_policies"]
}

resource "azurerm_network_security_group" "nsg" {
  for_each            = var.azure_nsgs
  name                = each.key
  location            = data.azurerm_resource_group.resource_group.location
  resource_group_name = data.azurerm_resource_group.resource_group.name
}

resource "azurerm_network_security_rule" "rule_nsg" {
  for_each = {
    for rule in local.nsg_rules : "${rule.nsg_name}.${rule.rule_name}" => rule
  }

  name                        = each.value.rule_name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = each.value.source_port
  destination_port_range      = each.value.destination_port
  source_address_prefix       = each.value.source_cidr
  destination_address_prefix  = each.value.destination_cidr
  resource_group_name         = data.azurerm_resource_group.resource_group.name
  network_security_group_name = each.value.nsg_name
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg_association" {
  for_each = {
    for association in local.subnet_nsg : "${association.subnet_name}_${association.nsg_name}" => association
  }
  subnet_id                 = each.value.subnet_id
  network_security_group_id = each.value.nsg_id
}
