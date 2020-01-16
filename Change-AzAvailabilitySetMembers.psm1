Function GetAVSetMembers {
    #Returns array of members in an AV Set - or $false if empty
    Param (
        [parameter()]
        $ResourceGroupName,
        [parameter()]
        $AvsetObject
    )   
    [array]$AVSetMembers=$AvsetObject.VirtualMachinesReferences
    $AVSetMembers.count
    If (!($AVSetMembers)) {
        Write-Debug "No VM's in AV Set"
        return $false
    }else{
        Write-Debug (" -Found " + $AVSetMembers.Count + " members in the set" )
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
    write-host "Scanning Disks" -NoNewline
    for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
        $VmObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
        if ($VmObject.StorageProfile.DataDisks[$s-1].vhd -eq $null){
            write-host "." -NoNewline
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
    write-host ""
    $Description = "   -Recreating the Azure VM: (Step 1 : Removing the VM...) "
    $Command = {Remove-AzVM -Name $VmObject.Name -ResourceGroupName $VmObject.ResourceGroupName -Force | Out-null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
    
    #Write-host "  -Waiting for 5 seconds to backend to sync" -ForegroundColor Yellow
    Start-sleep 5
    
    $Description = "   -Recreating the Azure VM: (Step 2 : Creating the VM...) "
    $Command = {New-AZVM -ResourceGroupName $VmObject.ResourceGroupName -Location $VmObject.Location -VM $VmObject | Out-null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
}
    
Function AreJobsRunning ($LogFile){
    $Description = "  -Validating existing jobs"
    WriteLog -Description $Description -LogFile $LogFile -Color 'Yellow'
    Write-host "     " -NoNewline
    [array]$Jobs=Get-Job -ErrorAction SilentlyContinue
    Do {
        write-host "." -NoNewline -ForegroundColor Red
        Start-Sleep 5
        [array]$Jobs=Get-Job -ErrorAction SilentlyContinue
    }
    While ($Jobs.State -contains "Running")
    write-host "." -ForegroundColor Green
    #clearing jobs
    $void=get-job | remove-job
}
Function MonitorJobs ($OperationName, $LogFile){
    Start-sleep 3
    $Running=$true

    [array]$Jobs=Get-Job
    Write-host "     " -NoNewline
    Do {
        ForEach ($Job in $Jobs) {
            If ($Job.State -eq 'Completed') {
                $JobID=$job.id
                $Description = " job $JobID done"
                WriteLog -Description $Description -LogFile $LogFile -Color 'Green'

                $void=Get-Job -id $Job.id | remove-job
                Write-host "     " -NoNewline
            }elseif ($Job.state -eq 'Failed') {
                #Need to remove VM from return set
                #Long Running Operation for 'Remove-AzVM' on resource 'BLABLA'
                $JobID=$job.Name
                $Description = " job $JobID Failed " 
                WriteLog -Description $Description -LogFile $LogFile -Color 'Red'
                If ($job.output){
                    ForEach ($line in $job.output) {
                        WriteLog -Description $line -LogFile $LogFile -Color 'Red'
                    }
                }
                #write-host $job.Output
                $void=Get-Job -id $Job.id | remove-job
                Write-host "     " -NoNewline
            }elseif ($Job.state -eq 'Running'){
                #do nothing - job still running
                Write-host . -NoNewline -ForegroundColor Yellow
                Start-Sleep 2
                
            }else{
                $status=Get-Job
                write-host $status
                Write-host "something went wrong - or starting"
                Write-host . -NoNewline -ForegroundColor Red
                Start-Sleep 2
            }
        }
        [array]$Jobs=Get-Job
    }
    While ($Jobs.count -ne 0) {}

}

Function DeleteAzVM($VMsToDelete, $ResourceGroupName, $Logfile,$Step){
    $DeleteOKReturn = New-Object System.Collections.ArrayList    
    #Clean Jobs
    $Jobs=Get-Job | remove-job
    $d=0
    ForEach ($VM in $VMsToDelete) {
        #Actually deleting the VM's
        $d++
        $Description = "   -(Step $Step.$d : Removing VM $vm...) "
        WriteLog -Description $Description -LogFile $LogFile -Color 'Yellow'
        Remove-AzVM -Name $VM -ResourceGroupName $ResourceGroupName -AsJob -Force | Out-null
        
        }
        #Now we need to wait for all of these Jobs to finish, but also to check if the VM's are actually deleted.. 
        Start-sleep 3
        $Running=$true
        [array]$Jobs=Get-Job
        Write-host "     " -NoNewline
        Do {
            ForEach ($Job in $Jobs) {
                If ($Job.State -eq 'Completed') {
                    $JobName=$job.Name
                    $VMFromJobName= $JobName.Replace("Long Running Operation for 'Remove-AzVM' on resource '","")
                    $VMFromJobName= $VMFromJobName.Replace("'","")

                    $Description = "$VMFromJobName deleted"
                    WriteLog -Description $Description -LogFile $LogFile -Color 'Green'

                    $DeleteOKReturn.add($VMFromJobName)
                    #Write-Host "added $VMFromJobName"
                    $void=Get-Job -id $Job.id | remove-job
                    Write-host "     " -NoNewline
                }elseif ($Job.state -eq 'Failed') {
                    #Need to remove VM from return set
                    #Long Running Operation for 'Remove-AzVM' on resource 'BLABLA'
                    $JobName=$job.Name
                    $VMFromJobName= $JobName.Replace("Long Running Operation for 'Remove-AzVM' on resource '","")
                    $VMFromJobName= $VMFromJobName.Replace("'","")
                    $Description = "VM Failed to be deleted " 
                    WriteLog -Description $Description -LogFile $LogFile -Color 'Red'
                    If ($job.output){
                        ForEach ($line in $job.output) {
                            WriteLog -Description $line -LogFile $LogFile -Color 'Red'
                        }
                    }
                    #write-host $job.Output
                    $void=Get-Job -id $Job.id | remove-job
                    Write-host "     " -NoNewline
                }elseif ($Job.state -eq 'Running'){
                    #do nothing - job still running
                    Write-host . -NoNewline -ForegroundColor Yellow
                    Start-Sleep 2
                    
                }else{
                    $status=Get-Job
                    write-host $status
                    Write-host "something went wrong - or starting"
                    Write-host . -NoNewline -ForegroundColor Red
                    Start-Sleep 2
                    

                }
            }
            [array]$Jobs=Get-Job
            
        }
        While ($Jobs.count -ne 0) {}

        return $DeleteOKReturn
}

Function DeployResource($VMstoDeploy,$ResourceGroupName,$workfolder, $Logfile, $Step){
    $VMsDeployed = New-Object System.Collections.ArrayList  
    $AzDeployments = New-Object System.Collections.ArrayList  
    $a=0
    ForEach ($VM in $VMstoDeploy) {
        $a++  
        $date = Get-Date -UFormat "%Y-%m-%d-%H-%M"
        $DeploymentName=('deployment' + $VM + '-' + $date)
        If ($DeploymentName.Length -gt 64){
            #Cutting of the start of the VM - Expecting the uniqueness in the last characters of the string
            $DeploymentName=$DeploymentName.substring(($DeploymentName.Length-64),64)
        }


        
        [string]$NewDeploymentFile=($workfolder + '\' + $ResourceGroupName + '-' + $VM + '-new.json')
        #Actually deleting the VM's
        $Description = "   -(Step $Step.$a : Creating VM $VM...) "
        #$Command = {New-AzResourceGroupDeployment -Name $DeploymentName -ResourceGroup $ResourceGroup -TemplateFile $newDeploymentFile -AsJob | Out-null}
        $Command = {New-AzResourceGroupDeployment -Name $DeploymentName -ResourceGroup $ResourceGroupName -TemplateFile $newDeploymentFile -AsJob}
        RunLog-Command -Description $Description -Command $Command -LogFile $LogFile        
        $void=$AzDeployments.Add($DeploymentName)
        #write-host $Command
        write-host {    -New-AzResourceGroupDeployment -Name $DeploymentName -ResourceGroup $ResourceGroupName -TemplateFile $newDeploymentFile -AsJob} -ForegroundColor Cyan
        write-host "     -Name $DeploymentName" -ForegroundColor Cyan
        write-host "     -ResourceGroup $ResourceGroupName" -ForegroundColor Cyan
        write-host "     -TemplateFile $newDeploymentFile " -ForegroundColor Cyan
  
    }

    Start-sleep 3

    $Description = "  -Validating deployment jobs"
    WriteLog -Description $Description -LogFile $LogFile -Color "Green"
    Write-host "     " -NoNewline
    $numberOfDeployments=$AzDeployments.count
    Do {
        ForEach ($Deployment in $AzDeployments) {
            $DeployStatus=Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $Deployment -ErrorAction SilentlyContinue
            If ($DeployStatus.ProvisioningState -eq 'Succeeded') {
                $DeploymentName=$DeployStatus.DeploymentName
                $Description = "$DeploymentName succeeded"
                WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
                $numberOfDeployments--
                If ($numberOfDeployments -eq 0) {break}
                Write-host "     " -NoNewline
              }elseif ($DeployStatus.ProvisioningState -eq 'Failed') {
                #Need to remove VM from return set
                #Long Running Operation for 'Remove-AzVM' on resource 'BLABLA'
                $DeploymentName=$DeployStatus.DeploymentName
                $Description = "$DeploymentName FAILED!"
                WriteLog -Description $Description -LogFile $LogFile -Color 'Red'
                Write-host "You can try a manual deployment" -ForegroundColor Yellow
                $numberOfDeployments--
                If ($numberOfDeployments -eq 0) {break}
                Write-host "     " -NoNewline
            }elseif ($DeployStatus.ProvisioningState -eq "Running"){
                #do nothing - job still running
                Write-host . -NoNewline -ForegroundColor Yellow
            }elseif ($DeployStatus.ProvisioningState -eq "Accepted"){
                #Hiding the output as it might cause confusion.. not all Jobs will report Accepted  - depending on timing.. so just making it a green . 
                #$DeploymentName=$DeployStatus.DeploymentName
                #$ProvisioningState=$DeployStatus.ProvisioningState
                #$Description = "   -$DeploymentName"
                #WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
                #$Description = "    -$ProvisioningState"
                #WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
                Write-host . -NoNewline -ForegroundColor Green
            }else{
            }
        }                
        Start-Sleep 2
    }While ($numberOfDeployments -ne 0) {}
    return $VMsDeployed

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

Function ExportVMConfigJSON($VMObject,$workfolder,$LogFile){
    $ResourceGroupName=$VMObject.ResourceGroupName
    $VMName=$VMObject.Name
    WriteLog -Description("  -$VMName") -LogFile $LogFile -Color "Yellow"
    [string]$ExportFile=($workfolder + '\' + $ResourceGroupName + '-' + $VMName + '.json')
    [string]$ObjectFile=($workfolder + '\' + $ResourceGroupName + '-' + $VMName + '-Object.json')

    $Description = "   -Exporting the VM Config to a file : $ObjectFile"
    $Command = {ConvertTo-Json -InputObject $VmObject -Depth 100 | Out-File -FilePath $ObjectFile}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Cyan"

    #Exporting JSON template for the VM - This allows the VM to be easily re-deployed back to original state in case something goes wrong
    #if so, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
    
    $Description = "   -Exporting the VM JSON Deployment file: $ExportFile "
    $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroupName -Resource $VMObject.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $ExportFile }
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Cyan"
    #Adding the VM to an Array for bulk change if required
}

Function FilterMembers ($VMObjectArray,$FaultDomain,$UpdateDomain, $LogFile){
    If ($FaultDomain -ge 0) {
        WriteLog -Description ("  -Filtering AV set for FaultDomain $FaultDomain ") -LogFile $LogFile -Color "Yellow"
    }
    If ($UpdateDomain -ge 0) {
        WriteLog -Description ("  -Filtering AV set for UpdateDomain $UpdateDomain ") -LogFile $LogFile -Color "Yellow"
    }
    $VMObjectArrayCount=$VMObjectArray.count
    $FilteredObjectArray = New-Object System.Collections.ArrayList
    
    ForEach ($VMObject in $VMObjectArray) {
            $VMObjectStatus=Get-AzVM -ResourceGroupName $VMObject.ResourceGroupName -Name $VMObject.Name -Status
            WriteLog -Description ("   -VM " + $VMObject.Name)  -LogFile $LogFile -Color "Green"
           
            If ($FaultDomain -or $FaultDomain -ge 0) {
                WriteLog -Description ("    -Fault Domain " + $VMObjectStatus.PlatformFaultDomain) -LogFile $LogFile -Color "Yellow"
            }
            If ($UpdateDomain -or $UpdateDomain -ge 0) {
                WriteLog -Description ("    -Update  Domain " + $VMObjectStatus.PlatformUpdateDomain) -LogFile $LogFile -Color "Yellow"
            }

            #Need to run seperately if both options enabled - more strict filter
            If ($updateDomain -ne 99 -and $FaultDomain -ne 99)  {

                If ($VMObjectStatus.PlatformUpdateDomain -eq $updateDomain -and $VMObjectStatus.PlatformFaultDomain -eq $FaultDomain) {
                    $FilteredObjectArray.Add($VMObject)  
                    WriteLog -Description ("    -added to scope - Update & Fault Domain") -LogFile $LogFile -Color "Cyan"
                    continue
                }
            }else{
                #if only 1 update domain or fault domain option was enabled
                If ($updateDomain -ge 0 -and ($VMObjectStatus.PlatformUpdateDomain -eq $updateDomain)) {
                    $FilteredObjectArray.Add($VMObject)  
                    WriteLog -Description ("    -added to scope - UpdateDomain") -LogFile $LogFile -Color "Cyan"
                    continue
                }elseIf ($FaultDomain -ge 0 -and $VMObjectStatus.PlatformFaultDomain -eq $FaultDomain) {
                    $FilteredObjectArray.Add($VMObject)
                    WriteLog -Description ("    -added to scope - FaultDomain") -LogFile $LogFile -Color "Cyan"
                    continue
                }else{
                    WriteLog -Description ("     removed") -LogFile $LogFile -Color "Green"
                }
            }
    }
    If ($FilteredObjectArray.count -eq 0) {
        return $False
    }else{
        #Foreach ($object in $FilteredObjectArray){
        #    $VMObjectArray.Remove($object)
            
        #}
        return $FilteredObjectArray
    }
}
Function Validate-VmExistence ($VmName, $VmRG, $logFile){
    $VmExist = $false
    $IsExist = Get-AzVM | where-Object { $_.ResourceGroupName -eq $VmRG -and $_.Name -eq $VmName }
    
    if ($IsExist) {
        $VmExist = $true
    }
    return $VmExist
}


Function Validate-AsExistence ($ASName, $VmRG, $LogFile) {
    $AsExist = $false
    $Description = " -Validating input $ASName in $VmRG"
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