Function GetAVSetMembers {
    #Returns array of members in an AV Set - or $false if empty
    Param (
        [parameter()]
        $ResourceGroupName,
        [parameter()]
        $AvSetName
    )   
    $AVSetMembers=(Get-AzAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvSetName).VirtualMachinesReferences
    If (!($AVSetMembers)) {
        Write-Debug "No VM's in AV Set"
        return $false
    }else{
        Write-Debug ("Found " + $AVSetMembers.Count + " members in the set" )
        return $AVSetMembers    
    }
}

#Functions
Function RunLog-Command([string]$Description, [ScriptBlock]$Command, [string]$LogFile, [string]$Color){
    If (!($Color)) {$Color="Yellow"}
    Try{
        $Output = $Description+'  ... '
        Write-Host $Output -ForegroundColor $Color
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
        $Result = Invoke-Command -ScriptBlock $Command 
    }
    Catch {
        $ErrorMessage = $_.Exception.Message
        $Output = 'Error '+$ErrorMessage
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
        $Result = ""
    }
    Finally {
        if ($ErrorMessage -eq $null) {
            $Output = "[Completed]  $Description  ... "} else {$Output = "[Failed]  $Description  ... "
        }
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
    }
    Return $Result
}


Function WriteLog([string]$Description, [string]$LogFile, [string]$Color){
    If (!($Color)) {$Color="Yellow"}
    Try{
        $Output = $Description+'  ... '
        Write-Host $Output -ForegroundColor $Color
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
        #$Result = Invoke-Command -ScriptBlock $Command 
    }
    Catch {
        $ErrorMessage = $_.Exception.Message
        $Output = 'Error '+$ErrorMessage
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
        $Result = ""
    }
    Finally {
        if ($ErrorMessage -eq $null) {
            $Output = "[Completed]  $Description  ... "} else {$Output = "[Failed]  $Description  ... "
        }
        ((Get-Date -UFormat "[%d-%m-%Y %H:%M:%S] ") + $Output) | Out-File -FilePath $LogFile -Append -Force
    }
    Return $Result
}
    
    
Function LogintoAzure(){
    $Error_WrongCredentials = $True
    $AzureAccount = $null
    while ($Error_WrongCredentials) {
        Try {
            Write-Host "Info : Please, Enter the credentials of an Admin account of Azure" -ForegroundColor Cyan
            #$AzureCredentials = Get-Credential -Message "Please, Enter the credentials of an Admin account of your subscription"      
            $AzureAccount = Add-AzAccount

            if ($AzureAccount.Context.Tenant -eq $null) 
                        {
                        $Error_WrongCredentials = $True
                        $Output = " Warning : The Credentials for [" + $AzureAccount.Context.Account.id +"] are not valid or the user does not have Azure subscriptions "
                        Write-Host $Output -BackgroundColor Red -ForegroundColor Yellow
                        } 
                        else
                        {$Error_WrongCredentials = $false ; return $AzureAccount}
            }

        Catch {
            $Output = " Warning : The Credentials for [" + $AzureAccount.Context.Account.id +"] are not valid or the user does not have Azure subscriptions "
            Write-Host $Output -BackgroundColor Red -ForegroundColor Yellow
            Generate-LogVerbose -Output $logFile -Message  $Output 
            }

        Finally {
                }
    }
    return $AzureAccount

}
    
Function Select-Subscription ($SubscriptionName, $AzureAccount){
            Select-AzSubscription -SubscriptionName $SubscriptionName -TenantId $AzureAccount.Context.Tenant.TenantId
}

Function Set-AsSetting ($VmObject, $LogFile, $TargetASObjectID, $VMSize){    
    # New section added to allow for managed disks
    if ($VmObject.StorageProfile.OsDisk.VHD -eq $null) {
        
        $VMObject.StorageProfile.OsDisk.ManagedDisk.Id = (Get-AZDisk -ResourceGroupName $VmRG -DiskName $($VMObject.StorageProfile.OsDisk.Name)).Id
            If (!($VMObject.StorageProfile.OsDisk.ManagedDisk.Id)) {
                While (!($VMObject.StorageProfile.OsDisk.ManagedDisk.Id)){
                    write-host "        retrying to get the disk info"
                    $VMObject.StorageProfile.OsDisk.ManagedDisk.Id = (Get-AZDisk -ResourceGroupName $VmRG -DiskName $($VMObject.StorageProfile.OsDisk.Name)).Id
                }
            }
        $VmObject.StorageProfile.OsDisk.ManagedDisk.StorageAccountType = $OSStorage
    }
    
    $VmObject.StorageProfile.OsDisk.CreateOption = 'Attach'
    
    for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
        $VmObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
        if ($VmObject.StorageProfile.DataDisks[$s-1].vhd -eq $null){
            $VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id = (Get-AZDisk -ResourceGroupName $VmRG -DiskName $($VmObject.StorageProfile.DataDisks[$s-1].Name)).Id
            
            If (!($VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id)) {
                While (!($VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id)){
                    write-host "        retrying to get the data disk info"
                    $VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id = (Get-AZDisk -ResourceGroupName $VmRG -DiskName $($VmObject.StorageProfile.DataDisks[$s-1].Name)).Id
                }
            }
            
            $VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.StorageAccountType = $DataStorage
        }
    }

    $AsObject = New-Object Microsoft.Azure.Management.Compute.Models.SubResource
    $AsObject.Id = $TargetASObjectID
    $VmObject.AvailabilitySetReference = $AsObject
    $VmObject.OSProfile = $null
    $VmObject.StorageProfile.ImageReference = $null
    if ($VmObject.StorageProfile.OsDisk.Image) {
        $VmObject.StorageProfile.OsDisk.Image = $null
    }
    
    $VmObject.StorageProfile.OsDisk.CreateOption = 'Attach'
    for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
        $VmObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
    }
    
    If ($VMSize){
        $VmObject.HardwareProfile.VmSize = $VMSize
    }
    #Need to discard the proximity placementgroup in case new AV set does not have the same one
    If ( $VmObject.ProximityPlacementGroup){
        $VmObject.ProximityPlacementGroup=$null
    }

    $VMName=$VmObject.Name 
    $Description = "   -Recreating the Azure VM: (Step 1 : Removing the VM...) "
    $Command = {Remove-AzVM -Name $VmObject.Name -ResourceGroupName $VmObject.ResourceGroupName -Force | Out-null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
    
    #Write-host "  -Waiting for 5 seconds to backend to sync" -ForegroundColor Yellow
    Start-sleep 5
    
    $Description = "   -Recreating the Azure VM: (Step 2 : Creating the VM...) "
    $Command = {New-AZVM -ResourceGroupName $VmObject.ResourceGroupName -Location $VmObject.Location -VM $VmObject | Out-null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
}
    
Function StopAZVM ($VMObject, $LogFile){  
    $VMstate = (Get-AzVM -ResourceGroupName $VMObject.ResourceGroupName -Name $VMObject.Name -Status).Statuses[1].code
    $Description = "  -Stopping the VM "
    if ($VMstate -ne 'PowerState/deallocated' -and $VMstate -ne 'PowerState/Stopped')
    {   
        $Command = { $VmObject | Stop-AzVM -Force | Out-Null}
        RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
        return $true
    }else{
        $Description =  "  -VM in Stopped/deallocated state already"
        RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
        return $false
    }
}
Function Validate-VmExistence ($VmName, $VmRG, $logFile){
    $VmExist = $false
    $IsExist = Get-AzVM | where-Object { $_.ResourceGroupName -eq $VmRG -and $_.Name -eq $VmName }
    $IsExist = 
    if ($IsExist) {
        $VmExist = $true
    }
    return $VmExist
}


Function Validate-AsExistence ($ASName, $VmRG, $LogFile) {
    $AsExist = $false
    $Description = "Validating input $ASName in $VmRG"
    $Command = {Get-AzAvailabilitySet -ResourceGroupName $VmRG -Name $ASName}
    $IsExist = RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
        
    if ($IsExist) {
        $AsExist = $true
    }
    return $AsExist
}

Function ValidateVMSize ($VMSize, $location){
    [array]$AvailableSizes=Get-AzVMSize -Location $location
    #write-host "searching for $VMSize"
    If ($AvailableSizes.name -contains $VMSize) {
        return $True
    }else{
        return $False
    }

}
Function LoadModule{
    param (
        [parameter(Mandatory = $true)][string] $name
    )
    $retVal = $true
    if (!(Get-Module -Name $name)){
        $retVal = Get-Module -ListAvailable | where { $_.Name -eq $name }
        if ($retVal) {
            try {
                Import-Module $name -ErrorAction SilentlyContinue
            }
            catch {
                $retVal = $false
            }
        }
    }
    return $retVal
}