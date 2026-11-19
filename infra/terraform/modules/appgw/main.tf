# ---------------------------------------------------------------------------
# Application Gateway WAF v2 - the public entry point.
#
# Traffic path:
#   Internet -> Public IP -> AppGW (TLS terminate + OWASP WAF)
#            -> AKS ingress controller (ClusterIP via internal LB)
#            -> erp-web pod -> erp-api pod -> PostgreSQL private endpoint
#
# WAF config to be able to explain:
#   firewall_mode = Prevention   blocks, does not just log
#   OWASP 3.2 ruleset            the managed CRS
#   exclusions                   how you stop false positives without
#                                disabling a whole rule group
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.name}"
  resource_group_name = var.rg_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones
  domain_name_label   = var.dns_label
  tags                = var.tags
}

# ------------------------------------------------------------- WAF policy
resource "azurerm_web_application_firewall_policy" "this" {
  name                = "wafpol-${var.name}"
  resource_group_name = var.rg_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = true
    file_upload_limit_in_mb     = 10
    max_request_body_size_in_kb = 128

    # Return a custom page rather than leaking the WAF's identity.
    log_scrubbing {
      enabled = true
      rule {
        enabled                 = true
        match_variable          = "RequestHeaderNames"
        selector                = "authorization"
        selector_match_operator = "Equals"
      }
    }
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"

      # ---------------------------------------------------------------
      # Real-world tuning. The ERP API posts JSON with decimal strings
      # and long product descriptions, which trips a couple of CRS rules.
      # The right fix is a narrow override, NEVER disabling the group.
      # ---------------------------------------------------------------
      rule_group_override {
        rule_group_name = "REQUEST-920-PROTOCOL-ENFORCEMENT"
        rule {
          id      = "920300" # Request missing an Accept header
          enabled = true
          action  = "Log" # log-only: API clients legitimately omit it
        }
      }

      rule_group_override {
        rule_group_name = "REQUEST-942-APPLICATION-ATTACK-SQLI"
        rule {
          id      = "942430" # Restricted SQL character anomaly (args)
          enabled = true
          action  = "Log"
        }
      }
    }

    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }

    # Scope the exclusion as tightly as possible: one field only.
    # Valid match_variable values are the RequestArg*/RequestCookie*/
    # RequestHeader* families - there is no JSON-body variable here, so
    # body-field tuning is done with rule_group_override above instead.
    exclusion {
      match_variable          = "RequestArgNames"
      selector                = "unit_price"
      selector_match_operator = "Equals"
    }
  }

  # ------------------------------------------------------- custom rules
  custom_rules {
    name      = "RateLimitPerIp"
    priority  = 10
    rule_type = "RateLimitRule"
    action    = "Block"

    rate_limit_duration  = "OneMin"
    rate_limit_threshold = var.rate_limit_per_minute
    group_rate_limit_by  = "ClientAddr"

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "IPMatch"
      negation_condition = false
      match_values       = ["0.0.0.0/0"]
    }
  }

  custom_rules {
    name      = "BlockNonBusinessGeos"
    priority  = 20
    rule_type = "MatchRule"
    action    = var.geo_block_enabled ? "Block" : "Log"

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "GeoMatch"
      negation_condition = true
      match_values       = var.allowed_countries
    }
  }

  # Block direct access to the API docs from the internet.
  custom_rules {
    name      = "BlockApiDocsFromInternet"
    priority  = 30
    rule_type = "MatchRule"
    action    = "Block"

    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator           = "Contains"
      negation_condition = false
      match_values       = ["/openapi.json", "/docs", "/redoc", "/metrics"]
      transforms         = ["Lowercase", "UrlDecode"]
    }
  }
}
