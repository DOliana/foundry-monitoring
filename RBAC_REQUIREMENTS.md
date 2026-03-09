# RBAC Requirements & Permissions for AI Foundry Monitoring Code

## Overview
This document maps each operation in the monitoring code to minimum required Azure roles and permissions, following the least-privilege principle.

---

## Query Log Analytics Workspace

**Operations:**
- Query `AzureMetrics` table for token metrics
- Query `AzureDiagnostics` table for per-request details
- Execute KQL queries against workspace

**Required Role:** `Log Analytics Data Reader`

**Permissions:**
| Action | Description |
|--------|-------------|
| `Microsoft.OperationalInsights/workspaces/read` | Read workspace metadata |
| `Microsoft.OperationalInsights/workspaces/query/read` | Run queries in workspace |
| `Microsoft.OperationalInsights/workspaces/tables/data/read` (DataAction) | Read data from tables |

**Scope:** Log Analytics workspace resource

**Documentation:**
- [Manage access to Log Analytics workspaces](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access?tabs=portal)
- [Log Analytics Data Reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor#log-analytics-data-reader)

---

## Query Azure Monitor Metrics API

**Operations:**
- Call `MetricsQueryClient` to retrieve `TotalTokens`, `ProcessedPromptTokens`, `GeneratedTokens`
- Query metrics with per-deployment splitting
- Access regional metrics endpoint (`https://{region}.metrics.monitor.azure.com`)

**Required Role:** `Monitoring Reader` (or custom role for strict least-privilege) on each foundry instance

**Permissions:**
| Action | Description |
|--------|-------------|
| `*/read` | Read control plane info for all Azure resources |
| `Microsoft.Insights/metrics/read` | Read metrics for resources |

**Scope:** foundry instance (cognitive service account)

**Documentation:**
- [Monitoring Reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor#monitoring-reader)
- [Metrics troubleshooting - access rights](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/metrics-troubleshoot#you-dont-have-sufficient-access-rights-to-your-resource)

---

## Query ARM APIs for Quota & Deployments

**Operations:**
- List Cognitive Services accounts in subscription: `az cognitiveservices account list --subscription`
- List deployments per account: `az cognitiveservices account deployment list`
- Query regional usages endpoint: `https://management.azure.com/subscriptions/{sub}/providers/Microsoft.CognitiveServices/locations/{location}/usages`
- Query deployment quotas and TPM allocation via REST API

**Required Roles (combination):**

| Role | Why | Scope |
|------|-----|-------|
| `Cognitive Services Usages Reader` | Required for `/usages` endpoint (quota data) | **Subscription** |
| `Cognitive Services User` OR `Reader` | Required for account/deployment enumeration | **Subscription** |

**Permissions:**
| Action | Description |
|--------|-------------|
| `Microsoft.CognitiveServices/locations/usages/read` | Read quota/usage data per region |
| `Microsoft.CognitiveServices/accounts/read` | List all Cognitive Services accounts |
| `Microsoft.CognitiveServices/accounts/deployments/read` | Read deployment configuration |

**Scope (Both roles assigned at):** `/subscriptions/{subscription-id}`

**Why subscription scope:**
- We look at **all** Cognitive Services accounts in a subscription (via `az cognitiveservices account list`)
- The ARM usages endpoint is subscription-level: `/subscriptions/{sub}/providers/Microsoft.CognitiveServices/locations/{location}/usages`
- Cannot be scoped to a single account because enumeration must work across multiple accounts

**Documentation:**
- [Cognitive Services Usages Reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-usages-reader)
- [Cognitive Services Contributor role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-contributor)


## Summary: Role Assignment Matrix

| Component | Role | Resource Scope | Notes |
|-----------|------|-----------------|-------|
| **Notebook (Query Logs)** | Log Analytics Data Reader | `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{ws-name}` | Scoped to the **specific workspace** |
| **Notebook (Query Metrics)** | `Monitoring Reader` (or custom) | Option 1: Subscription<br>Option 2: Individual Cognitive Services account | See Part 1B for least-privilege (Option 2 recommended) |
| **Notebook (Query ARM)** | `Cognitive Services Usages Reader` + `Cognitive Services User` | `/subscriptions/{subscription-id}` | **Must be subscription-level** (for account enumeration + usages endpoint) |

## References

### General RBAC Documentation
- [Azure role-based access control (RBAC) overview](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)
- [Assign Azure roles using Azure CLI](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-cli)
- [Custom roles in Azure RBAC](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles)

### Azure Monitor & Log Analytics
- [Manage Log Analytics workspace access](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access?tabs=portal)
- [Azure Monitor built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor)
- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)

### Cognitive Services & AI Services
- [Cognitive Services RBAC](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/role-based-access-control)
- [AI + Machine Learning built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning)
- [Azure AI Foundry RBAC](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry)

