// =============================================================================
// Everything this deployment needs, in one template.
// =============================================================================
// Deploy it from the Azure Portal with the "Deploy to Azure" button in the
// README, or from a terminal:
//
//   az group create --name rg-librechat-prod --location eastus2
//   az deployment group create \
//     --resource-group rg-librechat-prod \
//     --template-file infra/main.bicep \
//     --parameters @infra/main.parameters.json
//
// It creates a virtual machine, a network with a firewall, a data disk, a key
// vault for your secrets, a storage account for database backups, daily
// whole-machine backups, and monitoring alerts. It does NOT start the
// application: cloud-init installs the deploy script and leaves it to be run
// once your secrets are in the vault. That ordering is deliberate — a stack
// that starts before its secrets exist comes up misconfigured and then has to
// be un-misconfigured.
//
// Re-running this template is safe. It is the same declaration every time.
// =============================================================================

targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Parameters you MUST supply
// -----------------------------------------------------------------------------

@description('Public half of the SSH key pair used for the break-glass local administrator. Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/librechat -C librechat-admin. Day-to-day access should use Entra ID instead ("az ssh vm"); this key is what gets you in when that is broken.')
param adminSshPublicKey string

@description('Source addresses allowed to reach SSH (port 22), in CIDR form, e.g. ["203.0.113.4/32"]. Find yours with: curl -fsS https://api.ipify.org. ⚠️ A home broadband address usually changes without warning. If it changes you are locked out — recovery is Azure Portal > this NSG > edit the ssh rule, which takes about a minute and needs no SSH. Read docs/troubleshooting.md#locked-out-of-ssh BEFORE you need it.')
param adminSourceAddressPrefixes array

@description('Address that receives every monitoring alert. Use one a person actually reads.')
param alertEmail string

// -----------------------------------------------------------------------------
// Parameters with sensible defaults
// -----------------------------------------------------------------------------

@description('Prefix for every resource name. "librechat" produces vm-librechat-prod, nsg-librechat-prod, and so on. (The key vault and storage account additionally carry a uniqueness suffix, because their names are globally unique across all of Azure.)')
@minLength(3)
@maxLength(11)
param namePrefix string = 'librechat'

@description('Environment suffix, used in resource names.')
param environment string = 'prod'

@description('Azure region. Defaults to the resource group\'s region.')
param location string = resourceGroup().location

@description('Availability zone. Pinning the VM and its disks to one zone is required for them to be attachable to each other.')
@allowed(['1', '2', '3'])
param availabilityZone string = '2'

@description('Virtual machine size. 4 vCPU / 16 GB comfortably runs the whole stack for a few hundred users. See docs/cost-model.md before changing it.')
param vmSize string = 'Standard_D4s_v5'

@description('Local administrator account name for the virtual machine.')
param adminUsername string = 'azureuser'

@description('Size of the data disk in GB. Everything that must survive an OS rebuild lives here: databases, uploaded files, letterheads, backups.')
@minValue(32)
@maxValue(4096)
param dataDiskSizeGb int = 128

@description('Data disk performance tier.')
@allowed(['Premium_LRS', 'PremiumV2_LRS', 'StandardSSD_LRS'])
param dataDiskSku string = 'Premium_LRS'

@description('Repository that this machine deploys from. It must be public, or the VM will need credentials it does not have.')
param repoUrl string = 'https://github.com/MarylandLegalAid/librechat-azure.git'

@description('Branch to deploy.')
param repoBranch string = 'main'

@description('Create daily whole-machine backups with 30-day retention. The only thing that restores uploaded files.')
param enableBackup bool = true

@description('Public URL of the health endpoint to monitor, e.g. https://chat.example.org/health. Leave empty until DNS points at this machine; the availability test is skipped while it is empty.')
param healthCheckUrl string = ''

@description('Run the five-minute deploy timer on this machine. Set false where deploys are triggered by a pipeline instead, so a timer run cannot race it.')
param enableDeployTimer bool = true

@description('Where the data disk is mounted. ⚠️ This must match DATA_DIR in env.defaults — cloud-init mounts the disk here and the containers bind-mount from there. .github/workflows/validate.yml asserts the two agree.')
param dataDir string = '/srv/librechat/data'

@description('Tags applied to every resource.')
param tags object = {
  application: 'librechat'
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
var dataDiskName = 'disk-${namePrefix}-${environment}-data'
// ⚠️ Key Vault names are globally unique across ALL of Azure, not just your
// subscription or your tenant. A fixed name in a published blueprint therefore
// works exactly once, for whoever deploys it first — everybody after that gets
// VaultAlreadyExists and no obvious way to interpret it. ('kv-librechat-prod'
// is already taken by somebody, which is how we found this out.)
//
// So the name carries a suffix derived from the resource group ID: stable
// across redeploys of the same deployment, different for everyone else. Read
// the actual name from this template's keyVaultName output, or with:
//     az keyvault list -g <resource-group> --query "[0].name" -o tsv
//
// The 24-character limit is the reason for take(): 17 for the base, 1 for the
// separator, 6 for the suffix. namePrefix is capped at 11 above, which
// guarantees the truncation can never land on the separator and produce a
// double hyphen — a name Key Vault rejects.
var keyVaultName = '${take('kv-${namePrefix}-${environment}', 17)}-${substring(uniqueString(resourceGroup().id), 0, 6)}'
var vaultName = 'rsv-${namePrefix}-${environment}'
var actionGroupName = 'ag-${namePrefix}-${environment}'
var workspaceName = 'appi-${namePrefix}-${environment}'
var webTestName = 'webtest-${namePrefix}-${environment}-health'

// Storage account names are globally unique, lower case, and at most 24
// characters, so they cannot follow the same pattern as everything else.
var backupStorageName = toLower('st${namePrefix}${environment}${substring(uniqueString(resourceGroup().id), 0, 6)}')
var backupContainerName = 'mongo-backups'

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
        // Everything a user does arrives here.
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
        // Open only so Let's Encrypt can complete the HTTP-01 challenge that
        // issues and renews certificates. Caddy redirects all real traffic to
        // HTTPS. Closing this port does not improve security meaningfully and
        // does break certificate renewal roughly 60 days later, which is a
        // memorably annoying way to find out.
        name: 'allow-http-acme'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
          description: 'HTTP, for ACME certificate challenges and the redirect to HTTPS.'
        }
      }
      {
        // NOT open to the internet. The previous deployment allowed SSH from
        // anywhere, which meant the only thing between the world and the
        // database administration interface was the absence of a rule.
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
      addressPrefixes: ['10.20.0.0/16']
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.20.1.0/24'
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
    // Static, because the address goes in DNS. A dynamic address would change
    // every time the machine was deallocated and silently break the site.
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
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
// Data disk
// -----------------------------------------------------------------------------
// Declared as its own resource rather than inline on the VM so that deleting or
// rebuilding the VM does not delete the data with it. This is the single most
// important line in the file.

resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: dataDiskName
  location: location
  tags: tags
  sku: {
    name: dataDiskSku
  }
  zones: [availabilityZone]
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: dataDiskSizeGb
    publicNetworkAccess: 'Disabled'
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
    // A system-assigned identity is what lets this machine read its own secrets
    // from Key Vault without any credential existing on disk. Its lifetime is
    // tied to the VM: delete the machine and the identity is gone, with nothing
    // left behind to clean up or forget about.
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
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
          // Explicitly detach rather than delete when the VM goes away.
          deleteOption: 'Detach'
          caching: 'None'
        }
      ]
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
      // cloud-init.yaml is loaded verbatim from disk, so the handful of values
      // that differ between deployments are written there as __PLACEHOLDERS__
      // and substituted here. Keeping that file free of template syntax means
      // it can be read, linted and reviewed as ordinary cloud-config.
      //
      // ⚠️ customData is IMMUTABLE once the machine exists. Changing anything
      // that feeds into it — namePrefix, environment, repoUrl, repoBranch,
      // dataDir, enableDeployTimer — and redeploying fails with
      // PropertyChangeNotAllowed rather than being quietly ignored.
      //
      // On a new machine, delete the VM and let this template recreate it: the
      // data disk is a separate resource with deleteOption Detach and survives.
      // On a live one, edit /etc/librechat-deploy.conf on the machine instead —
      // that file is all cloud-init produced from these values anyway.
      // See docs/troubleshooting.md#redeploying-the-template-fails-with-propertychangenotallowed
      customData: base64(replace(replace(replace(replace(replace(loadTextContent('cloud-init.yaml'), '__KEY_VAULT_NAME__', keyVaultName), '__REPO_URL__', repoUrl), '__REPO_BRANCH__', repoBranch), '__DATA_DIR__', dataDir), '__DEPLOY_TIMER_ENABLED__', toLower(string(enableDeployTimer))))
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
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        // Managed boot diagnostics: a serial console and screenshot when the
        // machine will not come up. Costs nothing and is the only thing that
        // helps when SSH is not answering.
        enabled: true
      }
    }
  }
}

// Sign in over SSH with an Entra ID account instead of managing key files.
// This is the documented access path:  az ssh vm -g <rg> -n <vm>
// Each administrator additionally needs the "Virtual Machine Administrator
// Login" role — Bicep cannot grant that here because it does not know who they
// are. See docs/modules/entra-ssh.md.
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

// Ships guest metrics — memory, disk, filesystem — that the host cannot see on
// its own. Several of the alerts below depend on it.
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
    // Role-based access control rather than the older vault access policies:
    // one permission model for the whole subscription instead of two.
    enableRbacAuthorization: true
    // Both of these protect against the failure where someone deletes the vault
    // and takes CREDS_KEY with it — which would make every user's stored API
    // key permanently undecryptable. Purge protection cannot be turned off once
    // enabled, which is the point.
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

// The machine may read secret values. It may not list, write, or delete
// anything else in the vault. This is the whole of its standing access.
// -----------------------------------------------------------------------------
// Backup storage (for the nightly database dump)
// -----------------------------------------------------------------------------

resource backupStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: backupStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Force every caller to use an Entra identity. With this false there is no
    // account key for anyone to paste into a config file and later commit —
    // which is exactly how the previous deployment ended up with a live key in
    // cleartext in its .env.
    allowSharedKeyAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: backupStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: backupContainerName
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// What the machine is allowed to do
// -----------------------------------------------------------------------------
// In a module because a role assignment's name must be computable before the
// deployment starts, and it needs to be derived from the VM's principal — which
// is not known until the VM exists. infra/roles.bicep explains why naming it
// from vm.id instead is a trap that makes VM recreation unrecoverable.
module roleAssignments 'roles.bicep' = {
  name: 'librechat-role-assignments'
  params: {
    principalId: vm.identity.principalId
    keyVaultName: keyVault.name
    backupStorageName: backupStorage.name
  }
}

// -----------------------------------------------------------------------------
// Azure Backup — the whole machine, including the data disk
// -----------------------------------------------------------------------------
// This is the backup that restores uploaded FILES. The nightly dump covers the
// database only; now that files live on the data disk rather than in an object
// store, nothing else brings them back.

resource recoveryVault 'Microsoft.RecoveryServices/vaults@2024-04-01' = if (enableBackup) {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (enableBackup) {
  parent: recoveryVault
  name: 'policy-daily-30day'
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    instantRpRetentionRangeInDays: 2
    timeZone: 'UTC'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: ['2026-01-01T07:00:00Z']
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: ['2026-01-01T07:00:00Z']
        retentionDuration: {
          count: 30
          durationType: 'Days'
        }
      }
    }
  }
}

// Enrolling the VM in that policy. The name is a fixed Azure Backup convention;
// it is not free-form, and getting it wrong produces a deployment error that
// does not explain itself.
resource protectedItem 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = if (enableBackup) {
  name: '${vaultName}/Azure/iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vmName}/vm;iaasvmcontainerv2;${resourceGroup().name};${vmName}'
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    policyId: backupPolicy.id
    sourceResourceId: vm.id
  }
}

// -----------------------------------------------------------------------------
// Monitoring
// -----------------------------------------------------------------------------

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
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

// The seven host metric alerts. Each one is a symptom that has a plausible
// cause worth waking up for; none of them can tell you the application is
// broken, which is what the availability test below is for.
var metricAlerts = [
  {
    name: 'cpu-high'
    description: 'Sustained high CPU. Usually a runaway container or genuine load growth.'
    metric: 'Percentage CPU'
    operator: 'GreaterThan'
    threshold: 90
    aggregation: 'Average'
  }
  {
    name: 'memory-low'
    description: 'Available memory is nearly exhausted. The kernel will start killing containers.'
    metric: 'Available Memory Bytes'
    operator: 'LessThan'
    threshold: 1073741824
    aggregation: 'Average'
  }
  {
    name: 'network-in-high'
    description: 'Unusual inbound traffic.'
    metric: 'Network In Total'
    operator: 'GreaterThan'
    threshold: 10737418240
    aggregation: 'Total'
  }
  {
    name: 'network-out-high'
    description: 'Unusual outbound traffic. Worth a look — this is what data exfiltration looks like.'
    metric: 'Network Out Total'
    operator: 'GreaterThan'
    threshold: 10737418240
    aggregation: 'Total'
  }
  {
    name: 'os-disk-iops-high'
    description: 'The OS disk is at its throughput limit and everything on it is now slow.'
    metric: 'OS Disk IOPS Consumed Percentage'
    operator: 'GreaterThan'
    threshold: 95
    aggregation: 'Average'
  }
  {
    name: 'data-disk-iops-high'
    description: 'The data disk is at its throughput limit. The databases live here.'
    metric: 'Data Disk IOPS Consumed Percentage'
    operator: 'GreaterThan'
    threshold: 95
    aggregation: 'Average'
  }
  {
    name: 'vm-unavailable'
    description: 'Azure reports the virtual machine itself as unavailable.'
    metric: 'VmAvailabilityMetric'
    operator: 'LessThan'
    threshold: 1
    aggregation: 'Average'
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
            timeAggregation: alert.aggregation
            criterionType: 'StaticThresholdCriterion'
          }
        ]
      }
      actions: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
]

// --- The alert that closes the real gap --------------------------------------
// Every metric above can look perfectly healthy while the application is down.
// A container that crash-loops uses almost no CPU and almost no memory, and the
// virtual machine hosting it is genuinely available. Nothing on this page
// notices — which is precisely the failure that goes unnoticed for hours.
//
// This one asks the application whether it is working, from outside, the way a
// user would.

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (!empty(healthCheckUrl)) {
  name: workspaceName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

resource healthWebTest 'Microsoft.Insights/webtests@2022-06-15' = if (!empty(healthCheckUrl)) {
  name: webTestName
  location: location
  tags: union(tags, {
    // Required by Azure: a web test must be tagged as belonging to its
    // Application Insights resource or the portal will not display it.
    'hidden-link:${appInsights.id}': 'Resource'
  })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: webTestName
    Name: webTestName
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [
      { Id: 'us-va-ash-azr' }
      { Id: 'us-il-ch1-azr' }
      { Id: 'us-tx-sn1-azr' }
    ]
    Request: {
      RequestUrl: healthCheckUrl
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      // Warn while there is still time to do something about it.
      SSLCertRemainingLifetimeCheck: 14
    }
  }
}

resource healthAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(healthCheckUrl)) {
  name: '${namePrefix}-${environment}-health-unavailable'
  location: 'global'
  tags: tags
  properties: {
    description: 'The application health endpoint is failing from outside. Users are affected right now.'
    // Severity 1: this one means the service is down, unlike the metric alerts.
    severity: 1
    enabled: true
    scopes: [healthWebTest.id, appInsights.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: healthWebTest.id
      componentId: appInsights.id
      // Alert once two of the three test locations agree. One location failing
      // is usually that location, not you.
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Outputs — what you need for the next step
// -----------------------------------------------------------------------------

@description('Point your DNS A records at this address.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('Seed your secrets into this vault before running the first deploy.')
output keyVaultName string = keyVault.name

@description('Set BACKUP_STORAGE_ACCOUNT to this in Key Vault.')
output backupStorageAccount string = backupStorage.name

@description('Virtual machine name, for: az ssh vm -g <rg> -n <name>')
output vmName string = vm.name

@description('The machine identity that was granted read access to the key vault.')
output vmPrincipalId string = vm.identity.principalId

@description('Whether cloud-init was told to enable the five-minute deploy timer.')
output deployTimerEnabled bool = enableDeployTimer
