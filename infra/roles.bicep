// =============================================================================
// The machine's standing permissions.
// =============================================================================
// Split into a module for a specific and non-obvious reason.
//
// A role assignment's NAME must be computable before the deployment starts, and
// it should be derived from the principal it grants to. Those two requirements
// conflict in the main template: `vm.identity.principalId` is only known once
// the VM exists, so Bicep rejects it in a name with BCP120.
//
// Naming from `vm.id` instead compiles, and is wrong. A VM recreated with the
// same name keeps its resource ID but gets a BRAND-NEW system-assigned
// identity, so the assignment name stays stable while the principal underneath
// it changes — and Azure refuses to update a principal in place. The deployment
// fails with RoleAssignmentUpdateNotPermitted and keeps failing, because
// redeploying cannot fix it. The stale assignment has to be deleted by hand
// before the template will apply again. (Found the hard way; see
// docs/troubleshooting.md.)
//
// Passing the principal into a module resolves it: here it is an ordinary
// parameter, known at module start, so it can name the assignment. A new
// identity produces a new name, and the old assignment is simply left behind
// rather than blocking anything.
//
// This is what makes "delete the VM and let the template recreate it" a safe
// recovery rather than a one-way door.
// =============================================================================

@description('Object ID of the identity being granted access. The VM\'s system-assigned identity.')
param principalId string

@description('Name of the key vault holding this deployment\'s secrets.')
param keyVaultName string

@description('Name of the storage account holding nightly database dumps.')
param backupStorageName string

// Built-in Azure role definition IDs. Public constants, identical in every
// tenant: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource backupStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: backupStorageName
}

// Read secret VALUES. Not list, not write, not delete, and nothing else in the
// vault. This is the whole of the machine's standing access to your secrets.
resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// Write the nightly database dump, and prune old ones. Scoped to this storage
// account alone.
resource storageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: backupStorage
  name: guid(backupStorage.id, principalId, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
