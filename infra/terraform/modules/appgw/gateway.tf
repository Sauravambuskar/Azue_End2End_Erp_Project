# ---------------------------------------------------------------------------
# The gateway itself.
#
# NOTE: when AGIC (the AKS add-on) manages this gateway it rewrites the
# backend pools, listeners and rules at runtime. That is why the lifecycle
# block ignores them - otherwise every `terraform plan` would show drift and
# every apply would fight the ingress controller. This exact trap is a common
# interview question.
# ---------------------------------------------------------------------------
locals {
  backend_pool        = "bap-erp-default"
  http_setting        = "bhs-erp-default"
  frontend_port_https = "feport-443"
  frontend_port_http  = "feport-80"
  frontend_ip         = "feip-public"
  listener_http       = "lsnr-http"
  probe_name          = "probe-erp-health"
}

resource "azurerm_application_gateway" "this" {
  # Checkov inline suppressions MUST be inside the resource block,
  # not above it. Each names the variable or control that makes the
  # finding acceptable, so a reviewer can verify it.
  # checkov:skip=CKV_AZURE_217:The HTTP listener exists ONLY so the gateway can return a 301 to HTTPS. AGIC owns the listeners and redirect configuration at runtime (see the lifecycle ignore_changes block), and the chart sets appgw.ingress.kubernetes.io/ssl-redirect: "true". Removing the port-80 listener would mean a plain-HTTP request times out instead of being redirected.
  name                = var.name
  resource_group_name = var.rg_name
  location            = var.location
  zones               = var.availability_zones
  firewall_policy_id  = azurerm_web_application_firewall_policy.this.id
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  gateway_ip_configuration {
    name      = "gwip"
    subnet_id = var.subnet_id
  }

  frontend_port {
    name = local.frontend_port_http
    port = 80
  }

  frontend_port {
    name = local.frontend_port_https
    port = 443
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Placeholder backend. AGIC replaces this with the real pod IPs.
  backend_address_pool {
    name = local.backend_pool
  }

  backend_http_settings {
    name                  = local.http_setting
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    probe_name            = local.probe_name
  }

  probe {
    name                                      = local.probe_name
    protocol                                  = "Http"
    path                                      = "/healthz/ready"
    interval                                  = 15
    timeout                                   = 10
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399"]
    }
  }

  http_listener {
    name                           = local.listener_http
    frontend_ip_configuration_name = local.frontend_ip
    frontend_port_name             = local.frontend_port_http
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule-default"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = local.listener_http
    backend_address_pool_name  = local.backend_pool
    backend_http_settings_name = local.http_setting
  }

  # Security headers injected at the edge, so even a misbehaving backend
  # cannot serve a page without them.
  rewrite_rule_set {
    name = "rrs-security-headers"

    rewrite_rule {
      name          = "add-security-headers"
      rule_sequence = 100

      response_header_configuration {
        header_name  = "Strict-Transport-Security"
        header_value = "max-age=31536000; includeSubDomains"
      }
      response_header_configuration {
        header_name  = "X-Content-Type-Options"
        header_value = "nosniff"
      }
      response_header_configuration {
        header_name  = "X-Frame-Options"
        header_value = "DENY"
      }
      # Strip anything that advertises the backend stack.
      response_header_configuration {
        header_name  = "Server"
        header_value = ""
      }
      response_header_configuration {
        header_name  = "X-Powered-By"
        header_value = ""
      }
    }
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S" # TLS 1.2+ only
  }

  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_port,
      http_listener,
      probe,
      request_routing_rule,
      redirect_configuration,
      url_path_map,
      ssl_certificate,
      tags["managed-by-k8s-ingress"],
    ]
  }
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  count                      = var.log_analytics_workspace_id == null ? 0 : 1
  name                       = "diag-to-law"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayPerformanceLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }

  enabled_metric {
    category = "AllMetrics"
  }
}
