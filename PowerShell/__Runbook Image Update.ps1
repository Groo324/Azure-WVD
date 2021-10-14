################
#    Prereqs   #
################
<#
    Tags
    Image Version (Shared Image Gallery)
    Host Pools
    Automation Account
        Az modules: Az.Accounts, Az.Automation, Az.ManagedServiceIdentity, Az.Compute, and Az.DesktopVirtualization 
        imported into the Automation account
        Manage identity for automation account
        Set fx variables    
    (Logic App)
    (DevOps Pipeline)    
        check you are registered for the providers, ensure RegistrationState is set to 'Registered'.
        Get-AzResourceProvider -ProviderNamespace Microsoft.VirtualMachineImages
        Get-AzResourceProvider -ProviderNamespace Microsoft.Storage
        Get-AzResourceProvider -ProviderNamespace Microsoft.Compute
        Get-AzResourceProvider -ProviderNamespace Microsoft.KeyVault# If they do not show as registered, run the commented out code below.## Register-AzResourceProvider -ProviderNamespace Microsoft.VirtualMachineImages
        ## Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
        ## Register-AzResourceProvider -ProviderNamespace Microsoft.Compute
        ## Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault
#>

##########################
#    Script Parameters   #
##########################
Param (
        [Parameter(Mandatory=$true)]
        [String] $TagName,
        [Parameter(Mandatory=$true)]
        [String] $TagValue, 
        [Parameter(Mandatory=$true)]
        [validateset('Personal','Pooled','Both','Single')]
        [String] $PoolType,
        [Parameter(Mandatory=$false)]        
        [String] $SinglePoolName,
        [Parameter(Mandatory=$false)]        
        [String] $PoolResourceGroupName,        
        [Parameter(Mandatory=$true)]        
        [String] $ImageID = '/subscriptions/17a60df3-f02e-43a2-b52b-11abb3a53049/resourceGroups/rg-wth-aib-d-eus/providers/Microsoft.Compute/galleries/aibgallery01/images/win10wvd/versions/0.24935.25718'
)

################
#    Log in    #
################
[OutputType([String])]
$AzureContext = (Connect-AzAccount -Identity).context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
Import-Module Orchestrator.AssetManagement.Cmdlets -ErrorAction SilentlyContinue


##################
#    Variables   #
##################
$DomainFQDN = Get-AutomationVariable -Name 'DomainName'
$FSLogixProfilePath = Get-AutomationVariable -Name 'FSLogixPath'
$AACreds = (Get-AutomationPSCredential -Name 'adjoin')
$DomainCreds = New-Object System.Management.Automation.PSCredential ($AACreds.UserName, $AACreds.Password)


################################
#    Discover TAG Resources    #
################################
$Alls = Get-AzResource -TagName $TagName -TagValue $TagValue
$VMs = Get-AzResource -TagName $TagName -TagValue $TagValue `
    | Where-Object -Property ResourceType -EQ Microsoft.Compute/virtualMachines
$Disks = Get-AzResource -TagName $TagName -TagValue $TagValue `
    | Where-Object -Property ResourceType -EQ Microsoft.Compute/disks
$Nics = Get-AzResource -TagName $TagName -TagValue $TagValue `
    | Where-Object -Property ResourceType -EQ Microsoft.Network/networkInterfaces


########################
#    Get Pools Info    #
########################
switch ($PoolType) {
    Personal {
        Write-Output "Gathering PERSONAL Host Pools"
        $HPs = Get-AzWvdHostPool | Where-Object -Property HostPoolType -EQ $PoolType
    }
    Pooled {
        Write-Output "Gathering POOLED Host Pools"
        $HPs = Get-AzWvdHostPool | Where-Object -Property HostPoolType -EQ $PoolType
    }
    Both {
        Write-Output "Gathering BOTH types of Pools"
        $HPs = Get-AzWvdHostPool
    }
    Single {
        Write-Output "Gathering Hosts from "$SinglePoolName
        $HPs = Get-AzWvdHostPool -name $SinglePoolName -ResourceGroupName $PoolResourceGroupName
    }
}


################################################
#    Create Temp Resource Group for Imaging    #
################################################
$TempRG = New-AzResourceGroup -Location $inactiveHost.Location -Name AVDImaging-Temp
$TempSubnetCfg = New-AzVirtualNetworkSubnetConfig -Name Default -AddressPrefix "10.0.0.0/24"
$TempVNET = New-AzVirtualNetwork -Name AVDImaging-Temp -ResourceGroupName $TempRG.ResourceGroupName -Location $TempRG.Location -AddressPrefix "10.0.0.0/16" -Subnet $TempSubnetCfg


################################
#    Set Hosts to Drain Mode   #
################################
$InactiveHosts = @()
$ErrorActionPreference = 'SilentlyContinue'
foreach ($HP in $HPs) {
    $HPName = $HP.Name
    $HPRG = ($HP.id).Split('/')[4]
    Write-Output "Checking $HPName"
    $AllSessionHosts = Get-AzWvdSessionHost `
        -HostPoolName $HPName `
        -ResourceGroupName $HPRG
    foreach ($vm in $VMs) {
        foreach ($sessionHost in $AllSessionHosts | Where-Object {$_.ResourceId -eq $vm.Id}) {
            $userSessions = Get-AzWvdUserSession -ResourceGroupName $HPRG -HostPoolName $HP -SessionHostName $sessionHost.Name.Split('/')[1]
            if ($null -eq $userSessions)  {
                $InactiveHosts += Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName
            }
            if ($sessionHost.Name -match $HPName) {
            $sessionHostName = $sessionHost.Name
                Write-Output "Session Host $sessionHostName FOUND in $HPName"
                If (($SessionHost.AllowNewSession) -eq $true) {
                    Write-Output "Enabling Drain Mode $sessionHostName"
                    Update-AzWvdSessionHost `
                        -ResourceGroupName $HPRG `
                        -HostPoolName $HPName `
                        -Name $sessionHost.Name.Split('/')[1] `
                        -AllowNewSession:$false
                }
                else {
                    Write-Output "Drain Mode Already On for $sessionHostName"
                }
            }               
        }
    }
}
$ErrorActionPreference = 'Continue'


#########################
#    Deallocate Hosts   #
#########################
foreach ($inactiveHost in $inactiveHosts) {
    Write-Output "Stopping Host "$InactiveHost.Name
    Stop-AzVm -Name $inactiveHost.Name -ResourceGroupName $inactiveHost.ResourceGroupName -NoWait -Force
    Write-Output "Spawn New Disk From Image for Host "$InactiveHost.Name
    [string]$newDiskName = $inactiveHost.Name+"-OSDisk-"+(Get-Date -Format d-M-y)
   $TempNicName = $inactiveHost.Name+"-nic"  
    $nic = New-AzNetworkInterface `
        -Name $TempNicName `
        -ResourceGroupName $TempRG.ResourceGroupName `
        -Location $inactiveHost.Location `
        -SubnetId $TempVNET.Subnets[0].Id
    $vmConfig = New-AzVMConfig `
    -VMName $inactiveHost.name `
    -VMSize $inactiveHost.HardwareProfile.VmSize `
    | Set-AzVMOperatingSystem `
            -Windows `
            -ComputerName $inactiveHost.name `
            -Credential $cred `
            | Set-AzVMSourceImage -Id $ImageID `
            | Add-AzVMNetworkInterface -Id $nic.Id 
    Set-AzVMOSDisk `
        -VM $vmConfig `
        -Name $newDiskName `
        -Caching ReadWrite `
        -Windows `
        -DiskSizeInGB 127 `
        -CreateOption FromImage
    $newDiskCfg = New-AzDiskConfig `
        -Location $inactiveHost.Location `
        -CreateOption FromImage `
        -GalleryImageReference @{Id = $ImageID} `
        -SkuName  Premium_LRS `
        -OsType Windows `
        -DiskSizeGB 127
    New-AzVM `
        -ResourceGroupName $TempRG.ResourceGroupName `
        -Location $inactiveHost.Location `
        -VM $vmConfig    
    Stop-AzVm `
        -Name $inactiveHost.Name `
        -ResourceGroupName $TempRG.ResourceGroupName `
        -NoWait `
        -Force
    $NewSnapName = $InactiveHost.name+"-Snap"
    $SnapShotCfg = New-AzSnapshotConfig `
        -SkuName Premium_LRS `
        -OsType Windows `
        -DiskSizeGB $inactiveHost.StorageProfile.OsDisk.DiskSizeGB `
        -Location $inactiveHost.Location `
        -CreateOption  Copy `
        -SourceUri (Get-AzVM -ResourceGroupName $temprg.ResourceGroupName -Name $inactiveHost.Name).StorageProfile.OsDisk.ManagedDisk.Id
    $Snap = New-AzSnapshot `
        -ResourceGroupName $temprg.ResourceGroupName `
        -SnapshotName $NewSnapName `
        -Snapshot $SnapShotCfg `
        -Verbose
    $newDiskCfg = New-AzDiskConfig `
        -Location $inactiveHost.Location `
        -CreateOption Copy `
        -SkuName  Premium_LRS `
        -OsType Windows `
        -DiskSizeGB 127 `
        -SourceResourceId $Snap.Id
    $newDisk = New-AzDisk `
        -DiskName $newDiskName `
        -Disk $newDiskCfg `
        -ResourceGroupName $InactiveHost.ResourceGroupName
    Write-Output "Check Host Status for Host "$InactiveHost.Name
        $vmStatusCounter = 0
    while ($vmStatusCounter -lt 12) {
        $vmStatus = (Get-AzVM -Name $inactiveHost.Name -ResourceGroupName $inactiveHost.ResourceGroupName -Status).Statuses[1].Code.Split("/")[1]
        if ($vmStatus -eq "deallocated")
        {
            break
        }
        $vmStatusCounter++
        Start-Sleep -Seconds 5
    }
    Write-Output "OS Disk Swap on Host " $InactiveHost.Name
    Set-AzVMOSDisk -VM $inactiveHost -ManagedDiskId $newDisk.Id -Name $newDisk.name -Caching ReadWrite -Windows -DiskSizeInGB 127
    Write-Output "Update VM Host " $InactiveHost.Name
    Update-AzVM -ResourceGroupName $inactiveHost.ResourceGroupName -VM $inactiveHost
    Write-Output "Start Host " $InactiveHost.Name
    Start-AzVM -ResourceGroupName $inactiveHost.ResourceGroupName -Name $inactiveHost.Name -NoWait
    #Update-AzVM -ResourceGroupName $inactiveHost.ResourceGroupName -VM $inactiveHost
}


#####################
#    Join Domain    #
#####################
Set-AzVMADDomainExtension `
    -TypeHandlerVersion 1.3 `
    -DomainName $DomainFQDN `
    -VMName $inactiveHost.name `
    -ResourceGroupName $inactiveHost.ResourceGroupName `
    -Location (get-azresourcegroup -name $inactiveHost.ResourceGroupName).location `
    -Credential $DomainCreds `
    -JoinOption "0x00000003" `
    -Restart `
    -Verbose


###############################################
#    Join HostPool Custom Script Extension    #
###############################################
Set-AzVMCustomScriptExtension `
    -ResourceGroupName $inactiveHost.ResourceGroupName `
    -VMName $inactiveHost.name `
    -Location (get-azresourcegroup -name $inactiveHost.ResourceGroupName).location `
    -FileUri "https://raw.githubusercontent.com/DeanCefola/Azure-WVD/master/PowerShell/New-WVDSessionHost.ps1" `
    -Run "New-WVDSessionHost.ps1" `
    -Name AVDImageExtension `
    -Argument "$FSLogixProfilePath $Token"


##################
#    Clean Up    #
##################
Remove-AzResourceGroup -Name $TempRG.ResourceGroupName -Force -Verbose


