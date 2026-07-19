<#
.SYNOPSIS
  Creates a local kind (Kubernetes-in-Docker) cluster if one doesn't already
  exist, then installs Headlamp via its Helm chart and prints instructions
  for logging in.

.DESCRIPTION
  Windows PowerShell equivalent of deploy-k8s-dashboard.sh.

  NOTE: The original "Kubernetes Dashboard" project (kubernetes/dashboard)
  is now archived/unmaintained, and its Helm repo is offline (404). The
  Kubernetes SIG-UI team's official recommendation is to use Headlamp
  instead - see https://github.com/kubernetes/dashboard#important

.REQUIREMENTS
  - Docker Desktop must already be installed and running (with the WSL2
    or Hyper-V backend). https://docs.docker.com/desktop/install/windows-install/
  - winget (ships with Windows 11 / recent Windows 10). If missing, this
    script will fall back to Chocolatey if that's installed, and otherwise
    ask you to install kind/kubectl/helm manually.

.USAGE
  Open PowerShell (does not need to be Administrator for normal use) and run:
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
      .\deploy-k8s-dashboard.ps1 -ClusterName dashboard-demo
#>

param(
  [string]$ClusterName = "dashboard-demo"
)

$ErrorActionPreference = "Stop"
$Namespace = "kube-system"

function Write-Step($msg) {
  Write-Host ""
  Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-ErrorMsg($msg) {
  Write-Host ""
  Write-Host "ERROR: $msg" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# 0. Preflight checks
# ---------------------------------------------------------------------------
Write-Step "Checking for Docker..."
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
  Write-ErrorMsg "Docker is not installed or not on PATH. Install Docker Desktop first: https://docs.docker.com/desktop/install/windows-install/"
  exit 1
}
try {
  docker info | Out-Null
} catch {
  Write-ErrorMsg "Docker is installed but not running. Start Docker Desktop and re-run this script."
  exit 1
}
Write-Host "Docker OK."

function Install-Tool($name, $wingetId, $chocoId) {
  Write-Step "Installing $name..."
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  $choco  = Get-Command choco  -ErrorAction SilentlyContinue
  if ($winget) {
    winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements
  } elseif ($choco) {
    choco install $chocoId -y
  } else {
    Write-ErrorMsg "Neither winget nor choco is available. Install $name manually and re-run this script."
    exit 1
  }
}

if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
  Install-Tool -name "kind" -wingetId "Kubernetes.kind" -chocoId "kind"
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Install-Tool -name "kubectl" -wingetId "Kubernetes.kubectl" -chocoId "kubernetes-cli"
}
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
  Install-Tool -name "helm" -wingetId "Helm.Helm" -chocoId "kubernetes-helm"
}

# Refresh PATH in case a tool was just installed in this same session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

Write-Step "Versions in use:"
kind version
kubectl version --client
helm version

# ---------------------------------------------------------------------------
# 1. Create the kind cluster (idempotent)
# ---------------------------------------------------------------------------
$existingClusters = kind get clusters 2>$null
if ($existingClusters -contains $ClusterName) {
  Write-Step "kind cluster '$ClusterName' already exists, reusing it."
} else {
  Write-Step "Creating kind cluster '$ClusterName'..."
  kind create cluster --name $ClusterName
}

kubectl cluster-info --context "kind-$ClusterName"

# ---------------------------------------------------------------------------
# 2. Install Headlamp via its Helm chart
# ---------------------------------------------------------------------------
Write-Step "Adding headlamp Helm repo..."
helm repo add --force-update headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update | Out-Null

Write-Step "Installing/upgrading the Headlamp release..."
helm upgrade --install my-headlamp headlamp/headlamp `
  --namespace $Namespace `
  --kube-context "kind-$ClusterName"

Write-Step "Waiting for Headlamp pod to become ready..."
try {
  kubectl --context "kind-$ClusterName" -n $Namespace wait `
    --for=condition=available --timeout=180s deployment/my-headlamp
} catch {
  Write-Host "(Timed out waiting - check 'kubectl get pods -n $Namespace' manually.)"
}

# ---------------------------------------------------------------------------
# 3. Create an admin ServiceAccount + token for logging in
# ---------------------------------------------------------------------------
Write-Step "Applying admin-user.yaml (ServiceAccount + ClusterRoleBinding)..."
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
kubectl --context "kind-$ClusterName" apply -f (Join-Path $ScriptDir "admin-user.yaml")

Write-Step "Headlamp install complete."
Write-Host ""
Write-Host "Cluster:    kind-$ClusterName"
Write-Host "Namespace:  $Namespace"
Write-Host ""
Write-Host "To view Headlamp:"
Write-Host "  1) In a separate PowerShell window, start the port-forward:"
Write-Host "       kubectl --context kind-$ClusterName -n $Namespace port-forward service/my-headlamp 8080:80"
Write-Host "  2) Open:  http://localhost:8080"
Write-Host "  3) Get a login token:"
Write-Host "       kubectl --context kind-$ClusterName -n $Namespace create token headlamp-admin"
Write-Host "     Paste that token into Headlamp's login field."
Write-Host ""
Write-Host "To tear down the cluster later:"
Write-Host "  kind delete cluster --name $ClusterName"
