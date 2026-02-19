#!/usr/bin/env bash
set -e

step() {
  echo
  echo "▶️  $1"
  echo "----------------------------------------"
}

# -----------------------------
# Start From Step Support
# Usage: ./deploy.sh <step_number>
# -----------------------------
START_STEP=${1:-1}   # default = start from step 1
CURRENT_STEP=0

run_step() {
  CURRENT_STEP=$((CURRENT_STEP+1))

  if [ "$CURRENT_STEP" -lt "$START_STEP" ]; then
    echo "⏭️  Skipping Step $CURRENT_STEP: $1"
    return 1
  fi

  step "Step $CURRENT_STEP: $1"
  return 0
}

############################################################
# CONFIG — EDIT THESE
############################################################

LOCATION="eastus"
SUFFIX="a124"

RESOURCE_GROUP="rg-dotnet-apim${SUFFIX}"
STORAGE_NAME="stor${SUFFIX}"
FUNCAPP_NAME="func-${SUFFIX}"
APIM_NAME="apim-${SUFFIX}"

ORG_NAME="myorg"
ADMIN_EMAIL="admin@example.com"

API_NAME="dotnet-api"
API_DISPLAY_NAME="DotNet Function API"
API_PATH="${APIM_NAME}"

FUNCTION_PROJECT_PATH="dotnet-func-app"

# --- Entra / OAuth config ---
API_APP_NAME="apim-backend-${SUFFIX}"      # Entra app representing your API (audience)
CLIENT_APP_NAME="apim-client-${SUFFIX}"    # Entra app representing the caller
APP_ROLE_VALUE="Api.Access"                # role claim value required in token

############################################################
# GLOBALS populated during run
############################################################

FUNCAPP_HOSTNAME=""
SUBSCRIPTION_ID=""

TENANT_ID=""
API_APPID=""
API_APP_OBJECT_ID=""
API_APP_ID_URI=""
CLIENT_APPID=""
CLIENT_SECRET=""

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
OID_CONF="https://login.microsoftonline.com/${TENANT_ID}/.well-known/openid-configuration"
TOKEN_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/token"

echo $OID_CONF
echo $TOKEN_URL

create_rg() {
  az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION \
    --output none
}

create_storage() {
  az storage account create \
    --name $STORAGE_NAME \
    --location $LOCATION \
    --resource-group $RESOURCE_GROUP \
    --sku Standard_LRS \
    --output none
}

funcapp_create() {
  if ! az functionapp show -n $FUNCAPP_NAME -g $RESOURCE_GROUP >/dev/null 2>&1; then
    az functionapp create \
      --resource-group $RESOURCE_GROUP \
      --consumption-plan-location $LOCATION \
      --name $FUNCAPP_NAME \
      --storage-account $STORAGE_NAME \
      --os-type Windows \
      --functions-version 4 \
      --runtime dotnet \
      --runtime-version 8
  fi
}

publish_func() {
  # Verify function app exists (prevents "Can't find app")
  if ! az functionapp show -n "$FUNCAPP_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "❌ Function App '$FUNCAPP_NAME' not found in resource group '$RESOURCE_GROUP'."
    echo "   Fix: run the script from step 5 to create it:"
    echo "   ./deploy.zsh --from 5"
    exit 1
  fi

  cd "$FUNCTION_PROJECT_PATH"
  dotnet build get-dow-api.csproj
  func azure functionapp publish "$FUNCAPP_NAME" --dotnet-isolated
  cd - >/dev/null

  echo "Restarting Function App after publish..."
  az functionapp restart -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" >/dev/null
  sleep 90
}

get_function_details() {
  FUNCAPP_HOSTNAME=$(az functionapp show \
    -n $FUNCAPP_NAME \
    -g $RESOURCE_GROUP \
    --query defaultHostName -o tsv)

  echo "Function URL: https://$FUNCAPP_HOSTNAME"
}

############################################################
# REMAINING STEPS — VERIFY + TEST (Anonymous HTTP trigger)
############################################################

FUNCTION_NAME="GetDayOfTheWeek"
HTTP_METHOD="GET"        # GET or POST
POST_BODY='{}'           # JSON body if POST

check_state() {
  local state
  state=$(az functionapp show -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" --query "state" -o tsv)
  echo "Function App state: $state"
  if [[ "$state" != "Running" ]]; then
    echo "❌ Function App is not Running (state=$state)."
    exit 1
  fi
}

verify_app_settings() {
  echo "Checking critical app settings..."
  az functionapp config appsettings list \
    -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" \
    --query "[?name=='AzureWebJobsStorage' || name=='FUNCTIONS_EXTENSION_VERSION' || name=='FUNCTIONS_WORKER_RUNTIME'].{name:name,value:value}" \
    -o table

  local storage
  storage=$(az functionapp config appsettings list \
    -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" \
    --query "[?name=='AzureWebJobsStorage'].value | [0]" -o tsv)

  if [[ -z "$storage" || "$storage" == "null" ]]; then
    echo "❌ Missing AzureWebJobsStorage app setting. The function app won't run."
    exit 1
  fi
}

list_functions() {
  echo "Listing deployed functions..."
  az functionapp function list \
    -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" \
    --query "[].name" -o tsv
}

test_function() {
  # Ensure hostname is populated
  if [[ -z "$FUNCAPP_HOSTNAME" ]]; then
    get_function_details
  fi

  local url="https://${FUNCAPP_HOSTNAME}/api/${FUNCTION_NAME}"
  echo "Testing function endpoint:"
  echo "$url"
  echo

  if [[ "$HTTP_METHOD" == "POST" ]]; then
    echo "HTTP_METHOD=POST"
    echo "POST_BODY=$POST_BODY"
    curl -i \
      -X POST \
      -H "Content-Type: application/json" \
      --data "$POST_BODY" \
      "$url"
  else
    echo "HTTP_METHOD=GET"
    curl -i "$url"
  fi
}

tail_logs() {
  echo "Tailing logs (Ctrl+C to stop)..."
  az functionapp log tail -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME"
}


restart_funcapp() {
  echo "Restarting Function App..."
  az functionapp restart -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" >/dev/null
}

show_worker_runtime() {
  echo "Checking FUNCTIONS_WORKER_RUNTIME..."
  az functionapp config appsettings list \
    -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" \
    --query "[?name=='FUNCTIONS_WORKER_RUNTIME' || name=='FUNCTIONS_EXTENSION_VERSION'].{name:name,value:value}" \
    -o table
}

ensure_worker_runtime() {
  echo "Ensuring FUNCTIONS_WORKER_RUNTIME=dotnet-isolated..."
  az functionapp config appsettings set \
    -g "$RESOURCE_GROUP" -n "$FUNCAPP_NAME" \
    --settings FUNCTIONS_WORKER_RUNTIME=dotnet-isolated FUNCTIONS_EXTENSION_VERSION=~4 \
    >/dev/null
}



APIM_GATEWAY_HOSTNAME=""
APIM_API_URL=""
APIM_TEST_URL=""

create_apim() {
  if az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" >/dev/null 2>&1; then
    echo "APIM instance '$APIM_NAME' already exists."
    return 0
  fi

  echo "Creating APIM instance (Consumption SKU)..."
  az apim create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APIM_NAME" \
    --location "$LOCATION" \
    --publisher-email "$ADMIN_EMAIL" \
    --publisher-name "$ORG_NAME" \
    --sku-name Consumption \
    --output none
}

wait_for_apim() {
  echo "Waiting for APIM provisioning to complete..."
  while true; do
    local state
    state=$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query "provisioningState" -o tsv 2>/dev/null || echo "")
    if [[ "$state" == "Succeeded" ]]; then
      echo "APIM provisioningState: Succeeded"
      break
    fi
    echo "APIM provisioningState: ${state:-unknown} (waiting...)"
    sleep 20
  done
}

get_apim_details() {
  APIM_GATEWAY_HOSTNAME=$(az apim show \
    -g "$RESOURCE_GROUP" -n "$APIM_NAME" \
    --query "gatewayUrl" -o tsv)

  # gatewayUrl is a full URL like https://<name>.azure-api.net
  echo "APIM Gateway URL: $APIM_GATEWAY_HOSTNAME"
}

create_apim_api() {
  # Ensure function hostname is populated
  if [[ -z "$FUNCAPP_HOSTNAME" ]]; then
    get_function_details
  fi

  local service_url="https://${FUNCAPP_HOSTNAME}"

  echo "Creating/Updating APIM API '$API_NAME' with serviceUrl=$service_url ..."
  # Creates or updates the API shell
  az apim api create \
    --resource-group "$RESOURCE_GROUP" \
    --service-name "$APIM_NAME" \
    --api-id "$API_NAME" \
    --display-name "$API_DISPLAY_NAME" \
    --path "$API_PATH" \
    --protocols https \
    --service-url "$service_url" \
    --subscription-required false \
    --output none
}

xml_to_policy_json() {
  # Reads XML from stdin and outputs APIM policy JSON payload
  python3 - <<'PY'
import sys, json
xml = sys.stdin.read()
print(json.dumps({"properties": {"format": "xml", "value": xml}}))
PY
}

make_policy_json_file() {
  local xml_file="$1"
  local json_file="$2"

  python3 - <<PY
import json, pathlib
xml = pathlib.Path("${xml_file}").read_text()
if not xml.strip():
    raise SystemExit("Policy XML is empty")
payload = {"properties": {"format": "xml", "value": xml}}
pathlib.Path("${json_file}").write_text(json.dumps(payload))
PY
}


create_apim_operation() {
  local op_id="get-day-of-week"
  local op_url_template="/dayofweek"
  local backend_path="/api/${FUNCTION_NAME}"

  echo "Creating/Updating operation GET ${op_url_template} -> ${backend_path}"

  # Try create; if it already exists, update it
  az apim api operation create \
    --resource-group "$RESOURCE_GROUP" \
    --service-name "$APIM_NAME" \
    --api-id "$API_NAME" \
    --operation-id "$op_id" \
    --display-name "Get Day Of The Week" \
    --method GET \
    --url-template "$op_url_template" \
    --output none \
  || az apim api operation update \
    --resource-group "$RESOURCE_GROUP" \
    --service-name "$APIM_NAME" \
    --api-id "$API_NAME" \
    --operation-id "$op_id" \
    --display-name "Get Day Of The Week" \
    --method GET \
    --url-template "$op_url_template" \
    --output none


  local uri="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_NAME}/operations/${op_id}/policies/policy?api-version=2022-08-01"

  echo "Applying APIM operation policy via az rest..."
  az rest \
    --method put \
    --uri "$uri" \
    --headers "Content-Type=application/json" \
    --body @/tmp/apim-operation-policy.json \
    --output none
}



test_apim() {
  # Ensure APIM gateway URL is known
  if [[ -z "$APIM_GATEWAY_HOSTNAME" ]]; then
    get_apim_details
  fi

  # APIM gatewayUrl is like https://apimxxxx.azure-api.net
  APIM_TEST_URL="${APIM_GATEWAY_HOSTNAME}/${API_PATH}/dayofweek"

  echo "Testing APIM endpoint:"
  echo "$APIM_TEST_URL"
  echo

  curl -i "$APIM_TEST_URL"
}



API_SP_OBJECT_ID=""
CLIENT_SP_OBJECT_ID=""
APP_ROLE_ID=""

graph_put() {
  local method="$1"
  local uri="$2"
  local body_file="$3"

  if [[ -n "$body_file" ]]; then
    az rest --method "$method" --uri "$uri" --resource "https://graph.microsoft.com" \
      --headers "Content-Type=application/json" --body @"$body_file"
  else
    az rest --method "$method" --uri "$uri" --resource "https://graph.microsoft.com"
  fi
}

graph_get() {
  local uri="$1"
  az rest --method get --uri "$uri" --resource "https://graph.microsoft.com"
}

register_api_app() {
  echo "Registering API app in Entra (App Role for client credentials)..."

  # Create app (or reuse if already exists)
  API_APPID=$(az ad app list --display-name "$API_APP_NAME" --query "[0].appId" -o tsv)
  if [[ -z "$API_APPID" || "$API_APPID" == "null" ]]; then
    API_APPID=$(az ad app create --display-name "$API_APP_NAME" --query appId -o tsv)
  fi

  API_APP_OBJECT_ID=$(az ad app show --id "$API_APPID" --query id -o tsv)
  API_APP_ID_URI="api://${API_APPID}"

  # Define an application role (for client_credentials)
  APP_ROLE_ID="${APP_ROLE_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"

  cat > /tmp/api-app-update.json <<EOF
{
  "identifierUris": ["${API_APP_ID_URI}"],
  "appRoles": [
    {
      "allowedMemberTypes": [ "Application" ],
      "description": "Access the API as an application",
      "displayName": "API Access",
      "id": "${APP_ROLE_ID}",
      "isEnabled": true,
      "value": "${APP_ROLE_VALUE}",
      "origin": "Application"
    }
  ]
}
EOF

  echo "Updating API app via Microsoft Graph (identifierUris + appRoles)..."
  graph_put patch "https://graph.microsoft.com/v1.0/applications/${API_APP_OBJECT_ID}" /tmp/api-app-update.json >/dev/null

  echo "API App registered:"
  #echo "  API_APPID: $API_APPID"
  #echo "  API_APP_OBJECT_ID: $API_APP_OBJECT_ID"
  echo "  API_APP_ID_URI (audience): $API_APP_ID_URI"
  #echo "  APP_ROLE_VALUE: $APP_ROLE_VALUE"
}

register_client_app() {
  echo "Registering Client app in Entra..."

  CLIENT_APPID=$(az ad app list --display-name "$CLIENT_APP_NAME" --query "[0].appId" -o tsv)
  if [[ -z "$CLIENT_APPID" || "$CLIENT_APPID" == "null" ]]; then
    CLIENT_APPID=$(az ad app create --display-name "$CLIENT_APP_NAME" --query appId -o tsv)
  fi

  # Create/reset secret (store it somewhere secure!)
  CLIENT_SECRET=$(az ad app credential reset --id "$CLIENT_APPID" --query password -o tsv)

  echo "Ensuring service principals exist..."
  # Service principal for API app
  az ad sp create --id "$API_APPID" >/dev/null 2>&1 || true
  API_SP_OBJECT_ID=$(az ad sp show --id "$API_APPID" --query id -o tsv)

  # Service principal for Client app
  az ad sp create --id "$CLIENT_APPID" >/dev/null 2>&1 || true
  CLIENT_SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_APPID" --query id -o tsv)

  echo "Assigning app role to client (Graph appRoleAssignments)..."
  cat > /tmp/app-role-assignment.json <<EOF
{
  "principalId": "${CLIENT_SP_OBJECT_ID}",
  "resourceId": "${API_SP_OBJECT_ID}",
  "appRoleId": "${APP_ROLE_ID}"
}
EOF

  # POST to /servicePrincipals/{clientSpId}/appRoleAssignments
  graph_put post "https://graph.microsoft.com/v1.0/servicePrincipals/${CLIENT_SP_OBJECT_ID}/appRoleAssignments" /tmp/app-role-assignment.json >/dev/null || true

  echo "Client App registered:"
  echo "  CLIENT_APPID: $CLIENT_APPID"
  echo "  CLIENT_SECRET: $CLIENT_SECRET"
}

apply_apim_api_policy() {
  local xml_file="$1"
  local json_file="/tmp/apim-api-policy.json"

  make_policy_json_file "$xml_file" "$json_file"

  local uri="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_NAME}/policies/policy?api-version=2022-08-01"

  az rest \
    --method put \
    --uri "$uri" \
    --headers "Content-Type=application/json" \
    --body @"$json_file" \
    --output none
}


configure_apim_jwt_validation() {
  echo "Configuring APIM JWT validation (aud + roles)..."

  # Use v2.0 OIDC configuration endpoint
  local OIDC_V2="https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration"

  cat > /tmp/apim-jwt-policy.xml <<EOF
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Valid JWT token is required" require-scheme="Bearer">
      <openid-config url="${OIDC_V2}" />
      <required-claims>
        <claim name="aud" match="any">
          <value>${API_APP_ID_URI}</value>
        </claim>
        <claim name="roles">
          <value>${APP_ROLE_VALUE}</value>
        </claim>
      </required-claims>
    </validate-jwt>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
EOF

  apply_apim_api_policy /tmp/apim-jwt-policy.xml
}

token_and_test_apim() {
  # 1) Get token (v2 endpoint recommended)
  local token_url="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

  echo "Requesting Bearer token from Entra..."
  local token_json
  token_json=$(curl -s -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=${CLIENT_APPID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "scope=${API_APP_ID_URI}/.default" \
    -d "grant_type=client_credentials")

  # 2) Extract token (python is already used elsewhere in your script)
  local access_token
  access_token=$(printf '%s' "$token_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

  if [[ -z "$access_token" ]]; then
    echo "❌ Failed to obtain access token."
    echo "Token response:"
    echo "$token_json"
    exit 1
  fi

  echo "✅ Bearer token acquired."

  # 3) Call APIM with token
  if [[ -z "$APIM_GATEWAY_HOSTNAME" ]]; then
    get_apim_details
  fi

  local url="${APIM_GATEWAY_HOSTNAME}/${API_PATH}/dayofweek"
  echo "Testing secured APIM endpoint:"
  echo "$url"

  local http_code
  http_code=$(curl -s -o /tmp/apim-secure-response.txt -w "%{http_code}" \
    -H "Authorization: Bearer ${access_token}" \
    "$url")

  echo "APIM HTTP status: $http_code"
  if [[ "$http_code" != "200" ]]; then
    echo "❌ APIM secured call failed."
    echo "Response body:"
    cat /tmp/apim-secure-response.txt
    exit 1
  fi

  echo "✅ APIM secured call succeeded."
  cat /tmp/apim-secure-response.txt
}

# Step 1
if run_step "Creating resource group"; then
  create_rg
fi

# Step 2
if run_step "Creating storage account"; then
  create_storage
fi

# Step 3
if run_step "Creating Function App"; then
  funcapp_create
fi

# Step 4
if run_step "Ensure worker/runtime settings"; then
  ensure_worker_runtime
fi

# Step 5
if run_step "Publishing Function App"; then
  publish_func
fi

# Step 6
if run_step "Retrieve Function App Details"; then
  get_function_details
fi

# Step 7
if run_step "Check Function App state"; then
  check_state
fi

# Step 8
if run_step "Show worker/runtime settings"; then
  show_worker_runtime
fi

# Step 9
if run_step "Verify Function App settings"; then
  verify_app_settings
fi

# Step 10
if run_step "Restart Function App"; then
  restart_funcapp
fi

# Step 11
if run_step "List deployed functions"; then
  list_functions
fi

# Step 12
if run_step "Test function with curl"; then
  test_function
fi


# Step 13
if run_step "Create API Management instance"; then
  create_apim
fi

# Step 14
if run_step "Wait for APIM provisioning"; then
  wait_for_apim
fi

# Step 15
if run_step "Get APIM gateway details"; then
  get_apim_details
fi

# Step 16
if run_step "Create API in APIM"; then
  create_apim_api
fi

# Step 17
if run_step "Create APIM operation + policy"; then
  create_apim_operation
fi

sleep 20

# Step 18
if run_step "Test APIM endpoint with curl"; then
  test_apim
fi


## Step 19
##if run_step "Tail function logs"; then
##  tail_logs
##fi

# Step 20
if run_step "Register API App (Entra)"; then
  register_api_app
fi

# Step 21
if run_step "Register Client App (Entra)"; then
  register_client_app
fi

# Step 22
if run_step "Configure APIM JWT validation"; then
  configure_apim_jwt_validation
fi

# Step 23
if run_step "Get Bearer token and test secured APIM endpoint"; then
  token_and_test_apim
fi
