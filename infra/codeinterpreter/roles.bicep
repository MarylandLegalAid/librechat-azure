// =============================================================================
// The code interpreter machine's standing permissions: read its own secrets.
// =============================================================================
// A module for the same reason as infra/roles.bicep, which explains it: the
// assignment is named from the VM's principal, so a recreated VM (with a new
// identity) gets a new assignment instead of failing to update the old one.
// =============================================================================

@description('Object ID of the VM\'s system-assigned identity.')
param principalId string

@description('Name of the interpreter\'s key vault.')
param keyVaultName string

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
