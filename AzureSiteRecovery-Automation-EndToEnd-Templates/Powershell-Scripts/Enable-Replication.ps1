param(
    [Parameter(Mandatory = $true)]
    [string]
    $VaultSubscriptionId,

    [Parameter()]
    [string]
    $VaultTenantId,

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

Write-Host 'Parameters:'
$PSBoundParameters | Out-String | Write-Host

# Initialize the designated output of deployment script that can be accessed by various scripts in the template.
$DeploymentScriptOutputs = @{}
$sourceVmARMIds = New-Object System.Collections.ArrayList
foreach ($sourceId in $sourceVmARMIdsCSV.Split(',')) {
    [void]$sourceVmARMIds.Add($sourceId.Trim())
}

$message = "Enable replication will be triggered for following $($sourceVmARMIds.Count) VMs"
foreach ($sourceVmArmId in $sourceVmARMIds) {
    $message += "`n $sourceVmARMId"
}
Write-Output $message

Write-Output ''

# Setup the vault context.
Write-Output "Setting Vault context using vault '$VaultName' under resource group '$VaultResourceGroupName' in subscription '$VaultSubscriptionId'."
$subscription = Select-AzSubscription -SubscriptionId $VaultSubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
$vaultContext = Set-AzRecoveryServicesAsrVaultContext -Vault $vault

Write-Output "Vault context set to '$($vaultContext.ResourceGroupName) - $($vaultContext.ResourceName)'"
Write-Output ''

# Lookup and create replicatio fabrics if required.
$azureFabrics = Get-ASRFabric
Foreach ($fabric in $azureFabrics) {
    Write-Output "Fabric '$($fabric.Name)' in location '$($fabric.FabricSpecificDetails.Location)'."
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
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    Write-Output "Created Primary Fabric '$($priFab.Name)'."
}

$recFab = $azureFabrics | Where-Object { $_.FabricSpecificDetails.Location -eq $RecoveryRegion }
if (-not $recFab) {
    Write-Output 'Recovery Fabric does not exist. Creating Recovery Fabric.'
    $job = New-ASRFabric -Azure -Name $recoveryRegion -Location $recoveryRegion
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    Write-Output "Created Recovery Fabric '$($recFab.Name)'."
}

Write-Output "Primary Fabric '$($priFab.Id)"
Write-Output "Recovery Fabric '$($recFab.Id)'"
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
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    Write-Output "Created Primary Protection Container '$($priContainer.Name)' on primary fabric '$($priFab.Name)'."
}

$recContainer = Get-ASRProtectionContainer -Name "$($recFab.Name.Replace(' ', ''))-R" -Fabric $recFab -ErrorAction SilentlyContinue
if (-not $recContainer) {
    Write-Output 'Recovery Protection container does not exist. Creating Recovery Protection Container.'
    $job = New-AzRecoveryServicesAsrProtectionContainer -Name "$($recFab.Name.Replace(' ', ''))-R" -Fabric $recFab
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    $recContainer = Get-ASRProtectionContainer -Name "$($recFab.Name.Replace(' ', ''))-R" -Fabric $recFab
    Write-Output "Created Recovery Protection Container '$($recContainer.Name)' on primary fabric '$($recFab.Name)'."
}

Write-Output "Primary Protection Container '$($priContainer.Id)'"
Write-Output "Recovery Protection Container '$($recContainer.Id)'"
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
        } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

        if ($job.State -eq 'Failed') {
            $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
        Write-Output "Created Replication policy '$($policy.Name)' on replication provider '$($policy.ReplicationProvider)'."
    }

    $protectionContainerMappingName = $priContainer.Name + 'To' + $recContainer.Name
    $job = New-ASRProtectionContainerMapping -Name $protectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $priContainer -RecoveryProtectionContainer $recContainer
    do {
        Start-Sleep -Seconds 5
        $job = Get-ASRJob -Job $job
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
        Write-Output $message
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe | Out-String | Write-Host
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se | Out-String | Write-Host
            }
        }

        throw $message
    }	
    $primaryProtectionContainerMapping = Get-ASRProtectionContainerMapping -Name $protectionContainerMappingName -ProtectionContainer $priContainer
    Write-Output "Created Primary Protection Container mappings: '$($primaryProtectionContainerMapping.Name)', Source '$($primaryProtectionContainerMapping.SourceFabricFriendlyName)' - Target '$($primaryProtectionContainerMapping.TargetFabricFriendlyName)'."
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
        } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

        if ($job.State -eq 'Failed') {
            Write-Output "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        Write-Output "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
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
    Write-Output "Created Recovery Protection Container mappings: '$($reverseContainerMapping.Name)', Source '$($reverseContainerMapping.SourceFabricFriendlyName)' - Target '$($reverseContainerMapping.TargetFabricFriendlyName)'."
}

Write-Output "Protection Container mapping '$($primaryProtectionContainerMapping.Id)'"
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
    $vm = Get-AzVM -ResourceGroupName $vmResourceGroupName -Name $vmName
    Write-Output "Enable protection to be triggered for '$sourceVmArmId' using VM name '$vmName' as protected item ARM name."
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
	
    Write-Output 'Enable protection being triggered.'
	
    $job = New-ASRReplicationProtectedItem -Name $vmName -ProtectionContainerMapping $primaryProtectionContainerMapping `
        -AzureVmId $vm.ID -AzureToAzureDiskReplicationConfiguration $diskList -RecoveryResourceGroupId $TargetResourceGroupId `
        -RecoveryAzureNetworkId $TargetVirtualNetworkId -RecoveryAvailabilityZone $RecoveryAvailabilityZone
    [void]$enableReplicationJobs.Add($job)
}

Write-Output ''
$replicationAlreadyEnabled = $false

# Monitor each enable replication job.
$protectedItemArmIds = New-Object System.Collections.ArrayList
foreach ($job in $enableReplicationJobs) {
    do {
        Start-Sleep -Seconds 10
        $job = Get-ASRJob -Job $job
        Write-Output $job.State
    } while ($job.State -notin 'Succeeded', 'Failed', 'CompletedWithInformation')

    if ($job.State -eq 'Failed') {
        
        $message = "Job '$($job.DisplayName)' failed for '$($job.TargetObjectName)'"
        foreach ($er in $job.Errors) {
            foreach ($pe in $er.ProviderErrorDetails) {
                $pe | Out-String | Write-Host
            }

            foreach ($se in $er.ServiceErrorDetails) {
                $se | Out-String | Write-Host
            }
        }

        throw $message
    }
    elseif ($job.State -eq 'CompletedWithInformation') {
        if ($job.Errors.Count -gt 0) { 
            if ($job.Errors[0].ServiceErrorDetails.Code -eq 45031) {
                Write-Output "$($job.Errors[0].ServiceErrorDetails.Message) ($($job.TargetObjectName))"
                $replicationAlreadyEnabled = $true
            }
        }
    }
    $targetObjectName = $job.TargetObjectName
    Write-Output "Enable protection completed for '$($targetObjectName)'. Waiting for IR."
	
    if (-not $replicationAlreadyEnabled) {
        $startTime = $job.StartTime
        $irFinished = $false
        do {
            $irJobs = Get-ASRJob | Where-Object { $_.JobType -like '*IrCompletion' -and
                $_.TargetObjectName -eq $targetObjectName -and
                $_.StartTime -gt $startTime } |
                Sort-Object StartTime -Descending | Select-Object -First 2
            if ($irJobs) {
                $secondaryIrJob = $irJobs | Where-Object { $_.JobType -eq 'SecondaryIrCompletion' }
                
                if ($secondaryIrJob -and $secondaryIrJob.Length -ge 1) {
                    $irFinished = $secondaryIrJob.State -eq 'Succeeded' -or $secondaryIrJob.State -eq 'Failed'
                }
                else {
                    $irFinished = $irJobs.State -eq 'Failed' -or $irJobs.State -eq 'Succeeded'
                }
            }
            else {
                $irFinished = $true
            }
	
            if (-not $irFinished) {
                Start-Sleep -Seconds 5
            }
        } while (-not $irFinished)

        Write-Output "IR completed for '$($targetObjectName)'."
    }
	
    $rpi = Get-ASRReplicationProtectedItem -Name $targetObjectName -ProtectionContainer $priContainer
	
    Write-Output "Enable replciation completed for '$($rpi.ID)'."
    [void]$protectedItemArmIds.Add($rpi.Id)
}

$DeploymentScriptOutputs['ProtectedItemArmIds'] = $protectedItemArmIds -join ','	

# Log consolidated output.
Write-Output 'Infrastrucure Details'
foreach ($key in $DeploymentScriptOutputs.Keys) {
    Write-Output "$key : $($DeploymentScriptOutputs[$key])"
}
