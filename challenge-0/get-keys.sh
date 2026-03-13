#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_OUT="$SCRIPT_DIR/../.env"
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""

usage() {
  cat <<'EOF'
Usage:
  get-keys.sh --resource-group <name> [--subscription <id>] [--output <path>]
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      RESOURCE_GROUP="${2:-}"
      shift 2
      ;;
    --subscription)
      SUBSCRIPTION_ID="${2:-}"
      shift 2
      ;;
    --output)
      ENV_OUT="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown parameter passed: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd az
require_cmd curl

if ! az account show >/dev/null 2>&1; then
  echo "User not signed in to Azure. Sign in with 'az login' first." >&2
  exit 1
fi

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Enter the resource group name where the resources are deployed:"
  read -r RESOURCE_GROUP
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "A resource group name is required." >&2
  exit 1
fi

if ! az group exists --name "$RESOURCE_GROUP" | grep -q true; then
  echo "Resource group '$RESOURCE_GROUP' was not found." >&2
  exit 1
fi

echo "Discovering resources in '$RESOURCE_GROUP'..."

subscriptionId="$(az account show --query id -o tsv)"

storageAccountName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.Storage/storageAccounts'].name | [0]" -o tsv)"
logAnalyticsWorkspaceName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.OperationalInsights/workspaces'].name | [0]" -o tsv)"
cosmosDbAccountName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.DocumentDB/databaseAccounts'].name | [0]" -o tsv)"
apiManagementName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.ApiManagement/service'].name | [0]" -o tsv)"
applicationInsightsName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.Insights/components'].name | [0]" -o tsv)"
containerRegistryName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.ContainerRegistry/registries'].name | [0]" -o tsv)"

aiFoundryHubId="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.CognitiveServices/accounts' && kind=='AIServices'].id | [0]" -o tsv)"
aiFoundryHubName="${aiFoundryHubId##*/}"

aiFoundryProjectResourceId="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.CognitiveServices/accounts/projects'].id | [0]" -o tsv)"
aiFoundryProjectResourceName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.CognitiveServices/accounts/projects'].name | [0]" -o tsv)"
aiFoundryProjectName="${aiFoundryProjectResourceName#*/}"

searchConnectionId=""
searchServiceName=""
searchServiceEndpoint=""

if [[ -n "$aiFoundryHubName" ]]; then
  searchConnectionId="$(
    az rest \
      --method get \
      --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${aiFoundryHubName}/connections?api-version=2025-04-01-preview" \
      --query "value[?properties.category=='CognitiveSearch'] | [0].id" \
      -o tsv 2>/dev/null || true
  )"
  searchServiceEndpoint="$(
    az rest \
      --method get \
      --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${aiFoundryHubName}/connections?api-version=2025-04-01-preview" \
      --query "value[?properties.category=='CognitiveSearch'] | [0].properties.target" \
      -o tsv 2>/dev/null || true
  )"
  searchServiceResourceId="$(
    az rest \
      --method get \
      --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${aiFoundryHubName}/connections?api-version=2025-04-01-preview" \
      --query "value[?properties.category=='CognitiveSearch'] | [0].properties.metadata.ResourceId" \
      -o tsv 2>/dev/null || true
  )"
  if [[ -n "$searchServiceResourceId" ]]; then
    searchServiceName="${searchServiceResourceId##*/}"
  fi
fi

if [[ -z "$searchServiceName" ]]; then
  searchServiceName="$(az resource list --resource-group "$RESOURCE_GROUP" --query "[?type=='Microsoft.Search/searchServices'].name | [0]" -o tsv)"
fi

if [[ -z "$searchServiceEndpoint" && -n "$searchServiceName" ]]; then
  searchServiceEndpoint="https://${searchServiceName}.search.windows.net"
fi

chatDeploymentName=""
modelDeploymentName=""
embeddingDeploymentName=""

if [[ -n "$aiFoundryHubName" ]]; then
  deployment_names="$(
    az cognitiveservices account deployment list \
      --resource-group "$RESOURCE_GROUP" \
      --name "$aiFoundryHubName" \
      --query "[].name" \
      -o tsv 2>/dev/null || true
  )"

  choose_deployment() {
    local candidate
    for candidate in "$@"; do
      if printf '%s\n' "$deployment_names" | grep -Fxq "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    return 1
  }

  chatDeploymentName="$(choose_deployment "gpt-4.1-mini" "gpt-4o-mini" "gpt-4.1" || true)"
  modelDeploymentName="$(choose_deployment "gpt-4.1" "gpt-4o" "gpt-4o-mini" || true)"
  embeddingDeploymentName="$(choose_deployment "text-embedding-3-large" "text-embedding-3-small" "text-embedding-ada-002" || true)"
fi

logAnalyticsWorkspaceId=""
if [[ -n "$logAnalyticsWorkspaceName" ]]; then
  logAnalyticsWorkspaceId="$(
    az monitor log-analytics workspace show \
      --resource-group "$RESOURCE_GROUP" \
      --workspace-name "$logAnalyticsWorkspaceName" \
      --query customerId \
      -o tsv 2>/dev/null || true
  )"
fi

storageAccountKey=""
storageAccountConnectionString=""
if [[ -n "$storageAccountName" ]]; then
  storageAccountKey="$(
    az storage account keys list \
      --account-name "$storageAccountName" \
      --resource-group "$RESOURCE_GROUP" \
      --query "[0].value" \
      -o tsv 2>/dev/null || true
  )"
  if [[ -n "$storageAccountKey" ]]; then
    storageAccountConnectionString="DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccountKey};EndpointSuffix=core.windows.net"
  fi
fi

cosmosDbEndpoint=""
cosmosDbKey=""
cosmosDbConnectionString=""
if [[ -n "$cosmosDbAccountName" ]]; then
  cosmosDbEndpoint="$(
    az cosmosdb show \
      --name "$cosmosDbAccountName" \
      --resource-group "$RESOURCE_GROUP" \
      --query documentEndpoint \
      -o tsv 2>/dev/null || true
  )"
  cosmosDbKey="$(
    az cosmosdb keys list \
      --name "$cosmosDbAccountName" \
      --resource-group "$RESOURCE_GROUP" \
      --query primaryMasterKey \
      -o tsv 2>/dev/null || true
  )"
  if [[ -n "$cosmosDbEndpoint" && -n "$cosmosDbKey" ]]; then
    cosmosDbConnectionString="AccountEndpoint=${cosmosDbEndpoint};AccountKey=${cosmosDbKey};"
  fi
fi

aiFoundryEndpoint=""
aiFoundryKey=""
aiFoundryHubEndpoint=""
aiFoundryProjectEndpoint=""

if [[ -n "$aiFoundryHubName" ]]; then
  aiFoundryEndpoint="$(
    az cognitiveservices account show \
      --name "$aiFoundryHubName" \
      --resource-group "$RESOURCE_GROUP" \
      --query properties.endpoint \
      -o tsv 2>/dev/null || true
  )"
  aiFoundryKey="$(
    az cognitiveservices account keys list \
      --name "$aiFoundryHubName" \
      --resource-group "$RESOURCE_GROUP" \
      --query key1 \
      -o tsv 2>/dev/null || true
  )"
  aiFoundryHubEndpoint="https://ml.azure.com/home?wsid=${aiFoundryHubId}"
fi

if [[ -n "$aiFoundryProjectResourceId" ]]; then
  aiFoundryProjectEndpoint="$(
    az rest \
      --method get \
      --uri "https://management.azure.com${aiFoundryProjectResourceId}?api-version=2025-04-01-preview" \
      --query 'properties.endpoints."AI Foundry API"' \
      -o tsv 2>/dev/null || true
  )"
fi

searchServiceKey=""
if [[ -n "$searchServiceName" ]]; then
  searchServiceKey="$(
    az search admin-key show \
      --resource-group "$RESOURCE_GROUP" \
      --service-name "$searchServiceName" \
      --query primaryKey \
      -o tsv 2>/dev/null || true
  )"
fi

appInsightsInstrumentationKey=""
appInsightsConnectionString=""
if [[ -n "$applicationInsightsName" ]]; then
  appInsightsInstrumentationKey="$(
    az resource show \
      --resource-group "$RESOURCE_GROUP" \
      --resource-type "Microsoft.Insights/components" \
      --name "$applicationInsightsName" \
      --query properties.InstrumentationKey \
      -o tsv 2>/dev/null || true
  )"
  appInsightsConnectionString="$(
    az resource show \
      --resource-group "$RESOURCE_GROUP" \
      --resource-type "Microsoft.Insights/components" \
      --name "$applicationInsightsName" \
      --query properties.ConnectionString \
      -o tsv 2>/dev/null || true
  )"
fi

apimGatewayUrl=""
apimSubscriptionKey=""
if [[ -n "$apiManagementName" ]]; then
  apimGatewayUrl="$(
    az apim show \
      --name "$apiManagementName" \
      --resource-group "$RESOURCE_GROUP" \
      --query gatewayUrl \
      -o tsv 2>/dev/null || true
  )"
  apimSubscriptionKey="$(
    az rest \
      --method post \
      --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${apiManagementName}/subscriptions/master/listSecrets?api-version=2024-05-01" \
      --body '{}' \
      --query primaryKey \
      -o tsv 2>/dev/null || true
  )"
fi

acrName="$containerRegistryName"
acrUsername=""
acrPassword=""
acrLoginServer=""
if [[ -n "$acrName" ]]; then
  acrLoginServer="$(
    az acr show \
      --name "$acrName" \
      --resource-group "$RESOURCE_GROUP" \
      --query loginServer \
      -o tsv 2>/dev/null || true
  )"
  acrUsername="$(
    az acr credential show \
      --name "$acrName" \
      --resource-group "$RESOURCE_GROUP" \
      --query username \
      -o tsv 2>/dev/null || true
  )"
  acrPassword="$(
    az acr credential show \
      --name "$acrName" \
      --resource-group "$RESOURCE_GROUP" \
      --query "passwords[0].value" \
      -o tsv 2>/dev/null || true
  )"
fi

azureOpenAIEndpoint=""
if [[ -n "$aiFoundryHubName" ]]; then
  azureOpenAIEndpoint="https://${aiFoundryHubName}.openai.azure.com/"
fi

aiChatEndpoint=""
if [[ -n "$aiFoundryEndpoint" && -n "$chatDeploymentName" ]]; then
  aiChatEndpoint="${aiFoundryEndpoint%/}/openai/deployments/${chatDeploymentName}"
fi

rm -f "$ENV_OUT"

echo "Writing environment file to '$ENV_OUT'..."

write_env() {
  printf '%s="%s"\n' "$1" "$2" >> "$ENV_OUT"
}

write_env "RESOURCE_GROUP" "$RESOURCE_GROUP"
write_env "AZURE_SUBSCRIPTION_ID" "$subscriptionId"

write_env "AZURE_STORAGE_ACCOUNT_NAME" "$storageAccountName"
write_env "AZURE_STORAGE_ACCOUNT_KEY" "$storageAccountKey"
write_env "AZURE_STORAGE_CONNECTION_STRING" "$storageAccountConnectionString"

write_env "LOG_ANALYTICS_WORKSPACE_NAME" "$logAnalyticsWorkspaceName"
write_env "LOG_ANALYTICS_WORKSPACE_ID" "$logAnalyticsWorkspaceId"

write_env "SEARCH_SERVICE_NAME" "$searchServiceName"
write_env "SEARCH_SERVICE_ENDPOINT" "$searchServiceEndpoint"
write_env "SEARCH_ADMIN_KEY" "$searchServiceKey"
write_env "AZURE_SEARCH_ENDPOINT" "$searchServiceEndpoint"
write_env "AZURE_SEARCH_API_KEY" "$searchServiceKey"

write_env "AI_FOUNDRY_HUB_NAME" "$aiFoundryHubName"
write_env "AI_FOUNDRY_PROJECT_NAME" "$aiFoundryProjectName"
write_env "AI_FOUNDRY_ENDPOINT" "$aiFoundryEndpoint"
write_env "AI_FOUNDRY_KEY" "$aiFoundryKey"
write_env "AI_FOUNDRY_HUB_ENDPOINT" "$aiFoundryHubEndpoint"
write_env "AI_FOUNDRY_PROJECT_ENDPOINT" "$aiFoundryProjectEndpoint"

write_env "AZURE_AI_CHAT_KEY" "$aiFoundryKey"
write_env "AZURE_AI_CHAT_ENDPOINT" "$aiChatEndpoint"
write_env "AZURE_AI_CHAT_MODEL_DEPLOYMENT_NAME" "$chatDeploymentName"
write_env "AZURE_AI_PROJECT_ENDPOINT" "$aiFoundryProjectEndpoint"
write_env "AZURE_AI_PROJECT_RESOURCE_ID" "$aiFoundryProjectResourceId"
write_env "AZURE_AI_CONNECTION_ID" "$searchConnectionId"
write_env "AZURE_AI_MODEL_DEPLOYMENT_NAME" "$modelDeploymentName"
write_env "EMBEDDING_MODEL_DEPLOYMENT_NAME" "$embeddingDeploymentName"

write_env "COSMOS_NAME" "$cosmosDbAccountName"
write_env "COSMOS_DATABASE_NAME" "FactoryOpsDB"
write_env "COSMOS_ENDPOINT" "$cosmosDbEndpoint"
write_env "COSMOS_KEY" "$cosmosDbKey"
write_env "COSMOS_CONNECTION_STRING" "$cosmosDbConnectionString"

write_env "APIM_NAME" "$apiManagementName"
write_env "APIM_GATEWAY_URL" "$apimGatewayUrl"
write_env "APIM_SUBSCRIPTION_KEY" "$apimSubscriptionKey"

write_env "ACR_NAME" "$acrName"
write_env "ACR_USERNAME" "$acrUsername"
write_env "ACR_PASSWORD" "$acrPassword"
write_env "ACR_LOGIN_SERVER" "$acrLoginServer"

write_env "APPLICATION_INSIGHTS_INSTRUMENTATION_KEY" "$appInsightsInstrumentationKey"
write_env "APPLICATION_INSIGHTS_CONNECTION_STRING" "$appInsightsConnectionString"
write_env "APPLICATIONINSIGHTS_CONNECTION_STRING" "$appInsightsConnectionString"

write_env "AZURE_OPENAI_SERVICE_NAME" "$aiFoundryHubName"
write_env "AZURE_OPENAI_ENDPOINT" "$azureOpenAIEndpoint"
write_env "AZURE_OPENAI_KEY" "$aiFoundryKey"
write_env "AZURE_OPENAI_DEPLOYMENT_NAME" "$modelDeploymentName"
write_env "MODEL_DEPLOYMENT_NAME" "$modelDeploymentName"

echo "Keys and properties are stored in '$ENV_OUT' successfully."
echo ""
echo "=== Configuration Summary ==="
echo "Storage Account: $storageAccountName"
echo "Log Analytics Workspace: $logAnalyticsWorkspaceName"
echo "Search Service: $searchServiceName"
echo "API Management: $apiManagementName"
echo "AI Foundry Hub: $aiFoundryHubName"
echo "AI Foundry Project: $aiFoundryProjectName"
echo "AI Search Connection: $searchConnectionId"
echo "Chat Deployment: $chatDeploymentName"
echo "Primary Model Deployment: $modelDeploymentName"
echo "Embedding Deployment: $embeddingDeploymentName"
echo "Container Registry: $acrName"
echo "Application Insights: $applicationInsightsName"
echo "Cosmos DB: $cosmosDbAccountName"
echo "Environment file created: $ENV_OUT"
