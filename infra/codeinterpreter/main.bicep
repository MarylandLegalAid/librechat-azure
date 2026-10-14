// =============================================================================
// The code interpreter machine. OPTIONAL — see docs/modules/code-interpreter.md.
// =============================================================================
// Deploy into its own resource group, so retiring it later is one group delete:
//
//   az group create --name rg-codeinterpreter-prod --location eastus2
//   az deployment group create \
//     --resource-group rg-codeinterpreter-prod \
//     --template-file infra/codeinterpreter/main.bicep \
//     --parameters @infra/codeinterpreter/main.parameters.json
//
// It creates a VM that can run micro-VMs (nested virtualization), a firewall
// that admits HTTPS and administrator SSH only, a key vault, health monitoring
// and alerts. Like the chat VM's template, it does NOT start the stack:
// cloud-init prepares the host and stops, because the vault is still empty.
// Seed it with scripts/codeinterpreter-seed-secrets.sh, then run the first
// deploy by hand.
//
// There is no data disk and no backup on purpose. Nothing here outlives a day:
// workspaces are removed after an hour and session files after 24 hours. A
// rebuilt machine starting empty is correct behaviour, not data loss.
// =============================================================================

targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Parameters you MUST supply
// -----------------------------------------------------------------------------

@description('Public half of the break-glass SSH key pair. Day-to-day access is Entra ID ("az ssh vm").')
param adminSshPublicKey string

@description('Source addresses allowed to reach SSH (port 22), in CIDR form. See the chat VM template for the lock-out warning; it applies here too.')
param adminSourceAddressPrefixes array

@description('Resource ID of an existing action group to notify, normally the chat deployment\'s (ag-<prefix>-<env> in its resource group). Leave empty to create one here from alertEmail.')
param actionGroupId string = ''

@description('Address for alerts when actionGroupId is empty. Ignored otherwise.')
param alertEmail string = ''

// -----------------------------------------------------------------------------
// Parameters with sensible defaults
// -----------------------------------------------------------------------------

@description('Prefix for resource names: vm-<prefix>-<env>, nsg-<prefix>-<env>, and so on.')
@minLength(3)
@maxLength(20)
param namePrefix string = 'codeinterpreter'

@description('Environment suffix, used in resource names.')
@maxLength(10)
param environment string = 'prod'

@description('Azure region. Defaults to the resource group\'s region.')
param location string = resourceGroup().location

@description('Availability zone for the VM and its public IP.')
@allowed(['1', '2', '3'])
param availabilityZone string = '1'

@description('VM size. It MUST support nested virtualization, or /dev/kvm does not exist and nothing runs: the Dv5/Dsv5 and Ev5/Esv5 families do. D2s_v5 gives two concurrent executions; see docs/modules/code-interpreter.md before resizing.')
param vmSize string = 'Standard_D2s_v5'

@description('OS disk size in GB. Images, the sandbox root filesystems and the 24-hour file store live here.')
@minValue(64)
@maxValue(1024)
param osDiskSizeGb int = 128

@description('Encrypt the VM\'s temporary disk and caches at the host. Needs the EncryptionAtHost feature registered on the subscription (az feature register --namespace Microsoft.Compute --name EncryptionAtHost). Client files pass through this machine, so leave it on if you can.')
param encryptionAtHost bool = true

@description('Local administrator account name.')
param adminUsername string = 'azureuser'

@description('Repository this machine deploys from. Public, or the VM will need credentials it does not have.')
param repoUrl string = 'https://github.com/MarylandLegalAid/librechat-azure.git'

@description('Branch to deploy.')
param repoBranch string = 'main'

@description('Run the five-minute deploy timer.')
param enableDeployTimer bool = true

@description('Optional DNS label for the public IP, giving <label>.<region>.cloudapp.azure.com. Useful for testing a new machine before your own hostname points at it. Leave empty for none.')
param dnsLabel string = ''

@description('Resource ID of an existing Log Analytics workspace for the health snapshot. Leave empty to create a small one here.')
param logAnalyticsWorkspaceId string = ''

@description('Tags applied to every resource.')
param tags object = {
  application: 'librechat-codeinterpreter'
  environment: environment
  'managed-by': 'bicep'
}

// -----------------------------------------------------------------------------
// Names
// -----------------------------------------------------------------------------

var vmName = 'vm-${namePrefix}-${environment}'
var nicName = 'nic-${namePrefix}-${environment}'
var nsgName = 'nsg-${namePrefix}-${environment}'
var pipName = 'pip-${namePrefix}-${environment}'
var vnetName = 'vnet-${namePrefix}-${environment}'
// Globally unique and at most 24 characters; see the chat VM template for why
// the suffix. "ci" rather than the prefix, which would not fit.
var keyVaultName = 'kv-ci-${environment}-${substring(uniqueString(resourceGroup().id), 0, 6)}'
var workspaceName = 'log-${namePrefix}-${environment}'
var dcrName = 'dcr-${namePrefix}-${environment}-health'
var createdActionGroupName = 'ag-${namePrefix}-${environment}'

// -----------------------------------------------------------------------------
// Networking
// -----------------------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // The API, authenticated per request by a short-lived token that only
        // the chat VM can mint. Certificates are issued over this port too
        // (TLS-ALPN), which is why 80 is not open.
        name: 'allow-https'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'HTTPS from the internet.'
        }
      }
      {
        name: 'allow-ssh-admin'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: adminSourceAddressPrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'SSH from named administrator addresses only.'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.30.0.0/16']
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.30.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: [availabilityZone]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: empty(dnsLabel) ? null : {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// The virtual machine
// -----------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  zones: [availabilityZone]
  identity: {
    // Reads its own secrets from the vault; no credential on disk.
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
      // Immutable once the machine exists, as on the chat VM: change
      // /etc/codeinterpreter-deploy.conf on a live machine instead.
      customData: base64(replace(replace(replace(replace(loadTextContent('cloud-init.yaml'), '__KEY_VAULT_NAME__', keyVaultName), '__REPO_URL__', repoUrl), '__REPO_BRANCH__', repoBranch), '__DEPLOY_TIMER_ENABLED__', toLower(string(enableDeployTimer))))
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      encryptionAtHost: encryptionAtHost
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource aadSshExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Ships the health snapshot (syslog local0) to Log Analytics; see the data
// collection rule below.
resource monitorExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// -----------------------------------------------------------------------------
// Key Vault
// -----------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// In a module for the reason infra/roles.bicep gives: the assignment is named
// from the VM's principal, which is only known once the VM exists.
module roleAssignments 'roles.bicep' = {
  name: 'codeinterpreter-role-assignments'
  params: {
    principalId: vm.identity.principalId
    keyVaultName: keyVault.name
  }
}

// -----------------------------------------------------------------------------
// Monitoring
// -----------------------------------------------------------------------------
// Two layers. Host metrics (CPU, memory, disk) catch a machine in trouble. The
// health snapshot — one syslog line a minute from
// scripts/codeinterpreter-health.sh — catches a stack in trouble while the
// machine looks fine: no worker, a backed-up queue, cleanup not running.

resource createdActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (empty(actionGroupId)) {
  name: createdActionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(namePrefix, 12)
    enabled: true
    emailReceivers: [
      {
        name: 'operator'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

var alertActionGroupId = empty(actionGroupId) ? createdActionGroup.id : actionGroupId

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(logAnalyticsWorkspaceId)) {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

var workspaceId = empty(logAnalyticsWorkspaceId) ? workspace.id : logAnalyticsWorkspaceId

resource healthDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'codeInterpreterHealthSyslog'
          streams: ['Microsoft-Syslog']
          // local0 carries only the health snapshot on this machine.
          facilityNames: ['local0']
          logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'healthWorkspace'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Syslog']
        destinations: ['healthWorkspace']
      }
    ]
  }
}

resource healthDcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'health'
  scope: vm
  properties: {
    dataCollectionRuleId: healthDcr.id
  }
}

var metricAlerts = [
  {
    name: 'cpu-high'
    description: 'Sustained high CPU. Executions are queuing behind each other, or one is stuck.'
    metric: 'Percentage CPU'
    operator: 'GreaterThan'
    threshold: 85
  }
  {
    name: 'memory-low'
    description: 'Under 15% memory available. Each execution is a 2 GiB micro-VM; the next one may not start.'
    metric: 'Available Memory Percentage'
    operator: 'LessThan'
    threshold: 15
  }
  {
    name: 'vm-unavailable'
    description: 'Azure reports the virtual machine itself as unavailable.'
    metric: 'VmAvailabilityMetric'
    operator: 'LessThan'
    threshold: 1
  }
  {
    name: 'os-disk-iops-high'
    description: 'The OS disk is at its IOPS limit. Sandbox starts slow down.'
    metric: 'OS Disk IOPS Consumed Percentage'
    operator: 'GreaterThan'
    threshold: 95
  }
  {
    name: 'os-disk-bandwidth-high'
    description: 'The OS disk is at its bandwidth limit. Sandbox starts slow down.'
    metric: 'OS Disk Bandwidth Consumed Percentage'
    operator: 'GreaterThan'
    threshold: 95
  }
]

resource vmMetricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for alert in metricAlerts: {
    name: '${namePrefix}-${environment}-${alert.name}'
    location: 'global'
    tags: tags
    properties: {
      description: alert.description
      severity: 2
      enabled: true
      scopes: [vm.id]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            name: 'criterion'
            metricName: alert.metric
            metricNamespace: 'Microsoft.Compute/virtualMachines'
            operator: alert.operator
            threshold: alert.threshold
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
      }
      actions: [
        {
          actionGroupId: alertActionGroupId
        }
      ]
    }
  }
]

// Parses the snapshot line. ⚠️ Field names and order must match
// scripts/codeinterpreter-health.sh exactly; a mismatch parses as nulls and
// the alerts below go quiet rather than loud. The heartbeat alert is the
// backstop for that.
var snapshot = '''
Syslog
| where ProcessName == "codeinterpreter-health"
| parse SyslogMessage with "worker_running=" worker_running:int " queue_waiting=" queue_waiting:int " cleanup_success=" cleanup_success:int " cleanup_age_seconds=" cleanup_age_seconds:int " overdue_objects=" overdue_objects:int " missing_containers=" missing_containers:int " restart_count=" restart_count:int " root_used_percent=" root_used_percent:int
'''

var logAlerts = [
  {
    name: 'monitor-heartbeat-missing'
    description: 'No health snapshot for 10 minutes. The timer, the agent or the machine has stopped; every other alert here is blind until this clears.'
    query: 'Syslog | where TimeGenerated > ago(30m) | where ProcessName == "codeinterpreter-health" | summarize LastSnapshot = max(TimeGenerated) | where isnull(LastSnapshot) or LastSnapshot < ago(10m)'
  }
  {
    name: 'worker-unavailable'
    description: 'No execution worker is running. Run Code fails for everyone.'
    query: '${snapshot}| where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | where worker_running < 1'
  }
  {
    name: 'waiting-queue-high'
    description: 'More than two executions have been waiting for ten minutes. Capacity is short or the sandbox is stuck.'
    query: '${snapshot}| where TimeGenerated > ago(10m) | summarize Samples = count(), MinimumWaiting = min(queue_waiting) | where Samples >= 3 and MinimumWaiting > 2'
  }
  {
    name: 'file-cleanup-failed-or-stale'
    description: 'Session-file cleanup failed or has not run for two hours. The 24-hour retention promise in the terms of service is at risk.'
    query: '${snapshot}| where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | where cleanup_success != 1 or cleanup_age_seconds < 0 or cleanup_age_seconds > 7200'
  }
  {
    name: 'file-objects-overdue'
    description: 'A session file has outlived 26 hours. The 24-hour retention promise in the terms of service is broken.'
    query: '${snapshot}| where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | where overdue_objects != 0'
  }
  {
    name: 'container-unexpected'
    description: 'An expected container is missing, or one has restarted. Check docker ps on the machine.'
    query: '${snapshot}| where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | where missing_containers > 0 or restart_count > 0'
  }
  {
    name: 'root-disk-high'
    description: 'The OS disk is over 90% full. Images, sandboxes and the file store all live there.'
    query: '${snapshot}| where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | where root_used_percent > 90 or root_used_percent < 0'
  }
]

resource healthAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for alert in logAlerts: {
    name: '${namePrefix}-${environment}-${alert.name}'
    location: location
    kind: 'LogAlert'
    tags: tags
    properties: {
      displayName: '${namePrefix}-${environment}-${alert.name}'
      description: alert.description
      severity: 2
      enabled: true
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      scopes: [vm.id]
      autoMitigate: true
      criteria: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroups: [alertActionGroupId]
      }
    }
    dependsOn: [healthDcrAssociation]
  }
]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

@description('Point the interpreter hostname\'s DNS A record here.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('The Azure-provided hostname, if dnsLabel was set.')
output azureFqdn string = empty(dnsLabel) ? '' : publicIp.properties.dnsSettings.fqdn

@description('Seed this vault with scripts/codeinterpreter-seed-secrets.sh before the first deploy.')
output keyVaultName string = keyVault.name

@description('For: az ssh vm -g <rg> -n <name>')
output vmName string = vm.name
