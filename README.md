
# Getting Started with Azure Development Using CLI

This guide will help you set up your local environment for Azure development using the Azure CLI and Azure Developer CLI (azd).


## Prerequisites

- An [Azure account](https://azure.microsoft.com/en-us/free/)

### For macOS
- [Homebrew](https://brew.sh/) installed on your system

### For Windows
- [Chocolatey](https://chocolatey.org/install) package manager (recommended)
- [wget](https://eternallybored.org/misc/wget/) (if you prefer manual downloads)

To install Chocolatey, open an **Administrator** PowerShell and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; \
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; \
  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```


## 1. Install Azure CLI

### On macOS (Homebrew)
Update Homebrew and install the Azure CLI:

```sh
brew update
brew install azure-cli
```

### On Windows (Chocolatey)
Install Azure CLI using Chocolatey:

```powershell
choco install azure-cli -y
```

Verify the installation (both platforms):

```sh
az --version
```

## 2. Sign in to Azure

Log in to your Azure account:

```sh
az login
```

Check your account details:

```sh
az account show
```


## 3. Install Azure Developer CLI (azd)

### On macOS (Homebrew)
Install the Azure Developer CLI:

```sh
brew install azure/azd/azd
```

### On Windows (Chocolatey)
Install Azure Developer CLI using Chocolatey:

```powershell
choco install azure-dev
```

Verify the installation (both platforms):

```sh
azd version
```

## 4. Authenticate with Azure Developer CLI

Log in with azd:

```sh
azd auth login
```

Check authentication status:

```sh
azd auth status
```

---

az group create \
  --name rg-weather-app \
  --location eastus

You are now ready to start developing and deploying applications to Azure using the CLI tools!

---

## Create a Resource Group

Create a new resource group for your Azure resources:

```sh
az group create \
  --name rg-weather-app \
  --location eastus
```

## Set Up the Project Directory

Create and navigate to your project directory:

```sh
mkdir weather-api
cd weather-api
```


## Install Azure Functions Core Tools

### On macOS (Homebrew)
```sh
brew tap azure/functions
brew install azure-functions-core-tools@4
```

### On Windows (Chocolatey)
```powershell
choco install azure-functions-core-tools-4
```

## Installation Health Check

Check that all required tools are installed:

```sh
node --version
npm --version
func --version
az version
azd version
```

## Initialize and Create the Function

Initialize a new dotnet Azure Functions project and create the HTTP trigger:

```sh
func init get-dow-api \
  --worker-runtime dotnet-isolated \
  --target-framework net8.0

func new \
  --name GetDayOfTheWeek \
  --template "HTTP trigger" \
  --authlevel "Anonymous"
```
cd get-dow-api

## Build and Run Locally

Build the project and start the local Azure Functions runtime:

```sh
dotnet build

func start
```

## Test the Function Locally

Replace the port number if different (default is 7071):

```sh
curl "http://localhost:7071/api/GetDayOfTheWeek?name=Azure"
curl -X POST "http://localhost:7071/api/GetDayOfTheWeek" -d "Azure"
```

## Prepare for Deployment

First, gather the resource group and storage account info:

List storage accounts:

```sh
az storage account list --output table
```

List resource groups:

```sh
az group list --output table
```

List currently deployed functions:

```sh
az functionapp list \
  --resource-group rg-dow-app \
  --output table
```

Get the subscription id to use in the next command:

```sh
az account show --output json
```

## Create the Storage Account

Check if your desired storage account name is available:

```sh
az storage account check-name --name weatherapp95674
```

If available, you should see:

```json
{
  "message": null,
  "nameAvailable": true,
  "reason": null
}
```

If not available, you will see:

```json
{
  "message": "The storage account named weatherapp95674 is already taken.",
  "nameAvailable": false,
  "reason": "AlreadyExists"
}
```

If the account is already taken, you may also see:

```
(SubscriptionNotFound) Subscription <subscription_id> was not found.
```

Create the storage account (replace placeholders as needed):

```sh
az storage account create \
  --name weatherapp95674 \                # make sure this name is globally unique
  --resource-group rg-weather-app \       # replace with your resource group name
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2 \
  --subscription <subscription_id>        # use your subscription id here
```

## Create the Function App

Pick a name for your function app. Before that, check if the app name is already taken (e.g., weather-func-10090):

```sh
az functionapp list --resource-group rg-weather-app --query "[].name" --output table
```

Create the function app:

```sh
az functionapp create \
  --resource-group rg-weather-app \       # replace with your resource group name
  --consumption-plan-location eastus \
  --runtime node \
  --functions-version 4 \
  --name weather-func-10090 \             # pick a name for your app
  --storage-account weatherapp95674       # use the account name you selected above
```

## Register Required Namespaces (if needed)

If you get namespace-related errors, register the namespaces the function uses:

```sh
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Resources
az provider register --namespace Microsoft.OperationalInsights
az provider show --namespace Microsoft.Web --output table
```

Wait until the status shows "registered" before proceeding.

If needed, re-run the function app creation command:

```sh
az functionapp create \
  --resource-group rg-weather-app \
  --consumption-plan-location eastus \
  --runtime node \
  --functions-version 4 \
  --name weather-func-10090 \
  --storage-account weatherapp95674
```

## Deploy the Function App

Publish your function app to Azure:

```sh
func azure functionapp publish weather-func-10090
```

You should see output similar to the following:

```
'local.settings.json' found in root directory (/Users/user_name/Documents/azure/weather-app/weather-api).
Resolving worker runtime to 'node'.
Setting Functions site property 'netFrameworkVersion' to 'v8.0'
Getting site publishing info...
[2026-01-19T22:26:38.824Z] Starting the function app deployment...
Creating archive for current directory...
Uploading 1.34 MB [###############################################################################]
Upload completed successfully.
Deployment completed successfully.
[2026-01-19T22:27:05.826Z] Syncing triggers...
Functions in weather-func-10090:
    GetWeather - [httpTrigger]
        Invoke url: https://weather-func-10090.azurewebsites.net/api/getweather
```

When you are done, remember to wipe it all out

Deleting a resource group will remove all associated components tied to the RG

```
az group delete --name <resource-group-name>
```