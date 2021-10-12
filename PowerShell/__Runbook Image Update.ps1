﻿################
#    Prereqs   #
################
<#
    Tags
    Image Version (Shared Image Gallery)
    Host Pools
    Automation Account        
    KeyVault
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
        [Parameter(Mandatory=$true)]        
        [String] $AAResourceGroup =  'MSAA-WVDMgt',
        [Parameter(Mandatory=$true)]        
        [String] $AAName = 'MSAA-WVDAutoScale',
        [Parameter(Mandatory=$true)]        
        [String] $ImageID = '/subscriptions/17a60df3-f02e-43a2-b52b-11abb3a53049/resourceGroups/CPC-RG/providers/Microsoft.Compute/galleries/Win365Gallery/images/W365-Ent/versions/21.1.0'        
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
$DomainFQDN = (get-azautomationvariable -Name DomainName -resourcegroupname $AAResourceGroup -AutomationAccountName $AAName).value
$FSLogixProfilePath = (get-azautomationvariable -Name FSLogixPath -resourcegroupname $AAResourceGroup -AutomationAccountName $AAName).value
$AACreds = (get-azautomationcredential -name adjoin -resourcegroupname $AAResourceGroup -AutomationAccountName $AAName)
$DomainUserName = $AACreds.UserName
$DomainPassword = $AACreds.getnetworkcredentials().password
$DomainPassword1 = (Get-AzKeyVaultSecret -VaultName Image-KeyVault-1 -Name adjoin).secretvalue
$DomainCreds = New-Object System.Management.Automation.PSCredential ($DomainUserName, $DomainPassword1)


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
IF(($PoolType) -eq 'Personal') {
    Write-Host `
    -BackgroundColor Black `
    -ForegroundColor Cyan `
    "Gathering PERSONAL Host Pools"
    $HPs = Get-AzWvdHostPool | Where-Object -Property HostPoolType -EQ $PoolType

}
IF(($PoolType) -eq 'Pooled') {
    Write-Host `
    -BackgroundColor Black `
    -ForegroundColor Cyan `
    "Gathering POOLED Host Pools"
    $HPs = Get-AzWvdHostPool | Where-Object -Property HostPoolType -EQ $PoolType
    
}
IF(($PoolType) -eq 'Both') {
    Write-Host `
    -BackgroundColor Black `
    -ForegroundColor Cyan `
    "Gathering BOTH types of Pools"
    $HPs = Get-AzWvdHostPool
    
}
IF(($PoolType) -eq 'Single') {
    Write-Host `
    -BackgroundColor Black `
    -ForegroundColor Cyan `
    "Gathering Hosts from Single Pool"
    $PoolName = read-host -prompt "Enter the name of the Single Host Pool to update"
    $PoolResourceGroupName = read-host -prompt "Enter the resource group name where the Single Host Pool is located"
    $HPs = Get-AzWvdHostPool -name $PoolName -ResourceGroupName $PoolResourceGroupName
    
}


################################
#    Set Hosts to Drain Mode   #
################################
$ErrorActionPreference = 'SilentlyContinue'
foreach ($HP in $HPs) {
    $HPName = $HP.Name
    $HPRG = ($HP.id).Split('/')[4]
    Write-Host `
        -BackgroundColor Black `
        -ForegroundColor Magenta `
        "Checking $HPName"
    $AllSessionHosts = Get-AzWvdSessionHost `
        -HostPoolName $HPName `
        -ResourceGroupName $HPRG
    foreach ($vm in $VMs) {
        foreach ($sessionHost in $AllSessionHosts | Where-Object {$_.ResourceId -eq $vm.Id}) {                
            if ($sessionHost.Name -match $HPName) {
            $sessionHostName = $sessionHost.Name
                Write-Host `
                -BackgroundColor Black `
                -ForegroundColor Green `
                "Session Host $sessionHostName FOUND in $HPName"
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


#Write Foreach Loop

#########################
#    Dealloate Hosts    #
#########################
$VMName = 'EB-WVD-VM-0'
$RGName = 'QS-WVD'
$NewVMName = $VMName+"-OSDisk-"+(Get-Date -Format d-M-y)
Get-AzVM -name $VMName | Stop-AzVM -Force


##########################################
#    Provision New OSDisks from Image    #
##########################################
$diskConfig = New-AzDiskConfig `
   -Location EastUS `
   -CreateOption FromImage `
   -GalleryImageReference @{Id = $ImageID}

New-AzDisk -Disk $diskConfig `
   -ResourceGroupName $RGName `
   -DiskName $NewVMName


######################
#    OS Disk Swap    #
######################
$vm = Get-AzVM -ResourceGroupName $RGName -Name $VMName
$disk = Get-AzDisk -ResourceGroupName $RGName -Name $NewVMName
Set-AzVMOSDisk -VM $vm -ManagedDiskId $disk.Id -Name $disk.Name 
Update-AzVM -ResourceGroupName $RGName -VM $vm 


###################
#    Start VMs    #
###################
Get-AZVM -name $VMName | Start-AzVM
Invoke-AzVMRunCommand `
    -ResourceGroupName $RGName -Name $VMName -CommandId 'RunPowerShellScript' -ScriptPath '<pathToScript>' -Parameter @{"arg1" = "var1";"arg2" = "var2"}
rename-computer 

######################################
#    Remove Join Domain Extension    #
######################################
Remove-AzVMExtension -name joindomain -VMName $VMName -ResourceGroupName $RGName -Force -Verbose

#####################
#    Join Domain    #
#####################
Set-AzVMADDomainExtension `
    -DomainName $DomainFQDN `
    -VMName $VMName `
    -ResourceGroupName $RGName `
    -Location (get-azresourcegroup -name $RGName).location `
    -Credential $DomainCreds `
    -JoinOption "0x00000003" `
    -Restart `
    -Verbose

   

#######################
#    Join HostPool    #
#######################
#New-SessionHost
New-AZVMExtension 



