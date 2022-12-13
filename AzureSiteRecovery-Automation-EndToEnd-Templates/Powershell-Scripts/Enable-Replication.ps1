param(
    [Parameter(Mandatory = $true)]
    [string]
    $VaultSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]
    $VaultResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]
    $VaultName,
    
    [Parameter(Mandatory = $true)]
    [string]
    $PrimaryRegion,
    
    [Parameter(Mandatory = $true)]
    [string]
    $RecoveryRegion,

    [Parameter()]
    [string]
    $policyName = 'A2APolicy',
    
    [Parameter(Mandatory = $true)]
    [string]
    $sourceVmARMIdsCSV,
    
    [Parameter(Mandatory = $true)]
    [string]
    $TargetResourceGroupId,
    
    [Parameter(Mandatory = $true)]
    [string]
    $TargetVirtualNetworkId,
    
    [Parameter(Mandatory = $true)]
    [int]
    $RecoveryAvailabilityZone,
    
    [Parameter(Mandatory = $true)]
    [string]
    $PrimaryStagingStorageAccount,
    
    [Parameter()]
    [string]
    $RecoveryReplicaDiskAccountType = 'Standard_LRS',
    
    [Parameter()]
    [string]
    $RecoveryTargetDiskAccountType = 'Standard_LRS'
)

# Initialize the designated output of deployment script that can be accessed by various scripts in the template.
$DeploymentScriptOutputs = @{}
$sourceVmARMIds = New-Object System.Collections.ArrayList
foreach ($sourceId in $sourceVmARMIdsCSV.Split(',')) {
    [void]$sourceVmARMIds.Add($sourceId.Trim())
}

$message = 'Enable replication will be triggered for following {0} VMs' -f $sourceVmARMIds.Count
foreach ($sourceVmArmId in $sourceVmARMIds) {
    $message += "`n $sourceVmARMId"
}
Write-Output $message

Write-Output ''

# Setup the vault context.
$message = 'Setting Vault context using vault {0} under resource group {1} in subscription {2}.' -f $VaultName, $VaultResourceGroupName, $VaultSubscriptionId
Write-Output $message
Select-AzSubscription -SubscriptionId $VaultSubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$message = 'Vault context set.'
Write-Output $message
Write-Output ''

# Lookup and create replicatio fabrics if required.
$azureFabrics = Get-ASRFabric
Foreach ($fabric in $azureFabrics) {
    $message = 'Fabric {0} in location {1}.' -f $fabric.Name, $fabric.FabricSpecificDetails.Location
    Write-Output $message
}

# Setup the fabrics. Create if the fabrics do not already exist.
$PrimaryRegion = $PrimaryRegion.Replace(' ', '')
$RecoveryRegion = $RecoveryRegion.Replace(' ', '')
$priFab = $azureFabrics | Where-Object { $_.FabricSpecificDetails.Location -like $PrimaryRegion }
if (-not $priFab) {
    Write-Output 'Primary Fabric does not exist. Creating Primary Fabric.'
    $job = New-ASRFabric -Azure -Name $primaryRegion -Location $primaryRegion
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }
    $priFab = Get-ASRFabric -Name $primaryRegion
    Write-Output 'Created Primary Fabric.'
}

$recFab = $azureFabrics | Where-Object { $_.FabricSpecificDetails.Location -eq $RecoveryRegion }
if (-not $recFab) {
    Write-Output 'Recovery Fabric does not exist. Creating Recovery Fabric.'
    $job = New-ASRFabric -Azure -Name $recoveryRegion -Location $recoveryRegion
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }
    $recFab = Get-ASRFabric -Name $RecoveryRegion
    Write-Output 'Created Recovery Fabric.'
}

$message = 'Primary Fabric {0}' -f $priFab.Id
Write-Output $message
$message = 'Recovery Fabric {0}' -f $recFab.Id
Write-Output $message
Write-Output ''

$DeploymentScriptOutputs['PrimaryFabric'] = $priFab.Name
$DeploymentScriptOutputs['RecoveryFabric'] = $recFab.Name

# Setup the Protection Containers. Create if the protection containers do not already exist.
$priContainer = Get-ASRProtectionContainer -Name $priFab.Name -Fabric $priFab -ErrorAction SilentlyContinue
if (-not $priContainer) {
    Write-Output 'Primary Protection container does not exist. Creating Primary Protection Container.'
    $job = New-AzRecoveryServicesAsrProtectionContainer -Name $priFab.Name.Replace(' ', '') -Fabric $priFab
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }
    $priContainer = Get-ASRProtectionContainer -Name $priFab.Name -Fabric $priFab
    Write-Output 'Created Primary Protection Container.'
}

$recContainer = Get-ASRProtectionContainer -Name "$($recFab.Name.Replace(' ', ''))-R" -Fabric $recFab -ErrorAction SilentlyContinue
if (-not $recContainer) {
    Write-Output 'Recovery Protection container does not exist. Creating Recovery Protection Container.'
    $job = New-AzRecoveryServicesAsrProtectionContainer -Name "$($recFab.Name.Replace(' ', ''))-R" -Fabric $recFab
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }
    $recContainer = Get-ASRProtectionContainer -Name $recFab.Name -Fabric $recFab
    Write-Output 'Created Recovery Protection Container.'
}

$message = 'Primary Protection Container {0}' -f $priContainer.Id
Write-Output $message
$message = 'Recovery Protection Container {0}' -f $recContainer.Id
Write-Output $message
Write-Output ''

$DeploymentScriptOutputs['PrimaryProtectionContainer'] = $priContainer.Name
$DeploymentScriptOutputs['RecoveryProtectionContainer'] = $recContainer.Name

# Setup the protection container mapping. Create one if it does not already exist.
$primaryProtectionContainerMapping = Get-ASRProtectionContainerMapping -ProtectionContainer $priContainer | Where-Object { $_.TargetProtectionContainerId -like $recContainer.Id }
if (-not $primaryProtectionContainerMapping) {
    Write-Output 'Protection Container mapping does not already exist. Creating protection container.' 
    $policy = Get-ASRPolicy -Name $policyName -ErrorAction SilentlyContinue
    if (-not $policy) {
        Write-Output 'Replication policy does not already exist. Creating Replication policy.' 
        $job = New-ASRPolicy -AzureToAzure -Name $policyName -RecoveryPointRetentionInHours 1 -ApplicationConsistentSnapshotFrequencyInHours 1
        do {
            Start-Sleep -Seconds 5
            $job = Get-ASRJob -Job $job
        } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

        if ($job.State -eq 'Failed') {
            $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
            Write-Output $message
            foreach ($er in $job.Errors) {
                foreach ($pe in $er.ProviderErrorDetails) {
                    $pe
                }

                foreach ($se in $er.ServiceErrorDetails) {
                    $se
                }
            }

            throw $message
        }
        $policy = Get-ASRPolicy -Name $policyName
        Write-Output 'Created Replication policy.' 
    }

    $protectionContainerMappingName = $priContainer.Name + 'To' + $recContainer.Name
    $job = New-ASRProtectionContainerMapping -Name $protectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $priContainer -RecoveryProtectionContainer $recContainer
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }	
    $primaryProtectionContainerMapping = Get-ASRProtectionContainerMapping -Name $protectionContainerMappingName -ProtectionContainer $priContainer
    Write-Output 'Created Primary Protection Container mappings.'   
}

$reverseContainerMapping = Get-ASRProtectionContainerMapping -ProtectionContainer $recContainer | Where-Object { $_.TargetProtectionContainerId -like $priContainer.Id }
if (-not $reverseContainerMapping) {
    Write-Output 'Reverse Protection container does not already exist. Creating Reverse protection container.' 
    if (-not $policy) {
        Write-Output 'Replication policy does not already exist. Creating Replication policy.' 
        $job = New-ASRPolicy -AzureToAzure -Name $policyName -RecoveryPointRetentionInHours 1 -ApplicationConsistentSnapshotFrequencyInHours 1
        do {
            Start-Sleep -Seconds 5
            $job = Get-ASRJob -Job $job
        } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

        if ($job.State -eq 'Failed') {
            $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
            Write-Output $message
            foreach ($er in $job.Errors) {
                foreach ($pe in $er.ProviderErrorDetails) {
                    $pe
                }

                foreach ($se in $er.ServiceErrorDetails) {
                    $se
                }
            }

            throw $message
        }
        $policy = Get-ASRPolicy -Name $policyName
        Write-Output 'Created Replication policy.' 
    }

    $protectionContainerMappingName = $recContainer.Name + 'To' + $priContainer.Name
    $job = New-ASRProtectionContainerMapping -Name $protectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $recContainer `
        -RecoveryProtectionContainer $priContainer
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }	
    $reverseContainerMapping = Get-ASRProtectionContainerMapping -Name $protectionContainerMappingName -ProtectionContainer $recContainer    
    Write-Output 'Created Recovery Protection Container mappings.'
}

$message = 'Protection Container mapping {0}' -f $primaryProtectionContainerMapping.Id
Write-Output $message
Write-Output ''

$DeploymentScriptOutputs['PrimaryProtectionContainerMapping'] = $primaryProtectionContainerMapping.Name
$DeploymentScriptOutputs['RecoveryProtectionContainerMapping'] = $reverseContainerMapping.Name

# Start enabling replication for all the VMs.
$enableReplicationJobs = New-Object System.Collections.ArrayList
foreach ($sourceVmArmId in $sourceVmARMIds) {
    # Trigger Enable protection
    $vmIdTokens = $sourceVmArmId.Split('/');
    $vmName = $vmIdTokens[8]
    $vmResourceGroupName = $vmIdTokens[4]
    $message = 'Enable protection to be triggered for {0} using VM name {1} as protected item ARM name.' -f $sourceVmArmId, $vmName
    $vm = Get-AzVM -ResourceGroupName $vmResourceGroupName -Name $vmName
    Write-Output $message
    $diskList = New-Object System.Collections.ArrayList

    $osDisk = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $Vm.StorageProfile.OsDisk.ManagedDisk.Id `
        -LogStorageAccountId $PrimaryStagingStorageAccount -ManagedDisk -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
        -RecoveryResourceGroupId $TargetResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType          
    [void]$diskList.Add($osDisk)
	
    foreach ($dataDisk in $script:AzureArtifactsInfo.Vm.StorageProfile.DataDisks) {
        $disk = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $dataDisk.ManagedDisk.Id `
            -LogStorageAccountId $PrimaryStagingStorageAccount -ManagedDisk -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
            -RecoveryResourceGroupId $TargetResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType
        [void]$diskList.Add($disk)
    }
	
    $message = 'Enable protection being triggered.'
    Write-Output $message
	
    $job = New-ASRReplicationProtectedItem -Name $vmName -ProtectionContainerMapping $primaryProtectionContainerMapping `
        -AzureVmId $vm.ID -AzureToAzureDiskReplicationConfiguration $diskList -RecoveryResourceGroupId $TargetResourceGroupId `
        -RecoveryAzureNetworkId $TargetVirtualNetworkId -RecoveryAvailabilityZone $RecoveryAvailabilityZone
    [void]$enableReplicationJobs.Add($job)
}

Write-Output ''

# Monitor each enable replication job.
$protectedItemArmIds = New-Object System.Collections.ArrayList
foreach ($job in $enableReplicationJobs) {
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
        Write-Output $job.State
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = 'Job {0} failed for {1}' -f $job.DisplayName, $job.TargetObjectName
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se
            }
        }

        throw $message
    }
    $targetObjectName = $job.TargetObjectName
    $message = 'Enable protection completed for {0}. Waiting for IR.' -f $targetObjectName
    Write-Output $message
	
    $startTime = $job.StartTime
    $irFinished = $false
    do {
        $irJobs = Get-ASRJob | 
            Where-Object { $_.JobType -like '*IrCompletion' -and
                $_.TargetObjectName -eq $targetObjectName -and
                $_.StartTime -gt $startTime } | Sort-Object StartTime -Descending | Select-Object -First 2

        if (-not $irJobs -and $irJobs.Length -ne 0) {
            $secondaryIrJob = $irJobs | Where-Object { $_.JobType -like 'SecondaryIrCompletion' }
            if (-not $secondaryIrJob -and $secondaryIrJob.Length -ge 1) {
                $irFinished = $secondaryIrJob.State -eq 'Succeeded' -or $secondaryIrJob.State -eq 'Failed'
            }
            else {
                $irFinished = $irJobs.State -eq 'Failed'
            }
        }
	
        if (-not $irFinished) {
            Start-Sleep -Seconds 5
        }
    } while (-not $irFinished)
	
    $message = 'IR completed for {0}.' -f $targetObjectName
    Write-Output $message
	
    $rpi = Get-ASRReplicationProtectedItem -Name $targetObjectName -ProtectionContainer $priContainer
	
    $message = 'Enable replciation completed for {0}.' -f $rpi.ID
    Write-Output $message
    [void]$protectedItemArmIds.Add($rpi.Id)
}

$DeploymentScriptOutputs['ProtectedItemArmIds'] = $protectedItemArmIds -join ','	

# Log consolidated output.
Write-Output 'Infrastrucure Details'
foreach ($key in $DeploymentScriptOutputs.Keys) {
    $message = '{0} : {1}' -f $key, $DeploymentScriptOutputs[$key]
    Write-Output $message
}
