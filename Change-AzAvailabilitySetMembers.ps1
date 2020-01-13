<#

 
ScriptName : Move-AzAvailabilitySetMembers
Description : This script will move all VM's of an availability set to another availability set
Author : Roelf Zomerman (https://blog.azureinfra.com)
Based on: Samir Farhat (https://buildwindows.wordpress.com) - Set-ArmVmAvailabilitySet.ps1
Version : 1.01

#Usage
    ./Change-AzAvailabilitySetMembers.ps1 -SourceAvailabilitySet SourceAVSET1 -TargetAvailabilitySet TargetAVSET2 -ResourceGroup ResourceGroupName -Login $false/$true -SelectSubscription $false/$true -PauseAfterEachVM $false/$true 

#Prerequisites#
- Azure Powershell 1.01 or later
- An Azure Subscription and an account which have the proviliges to : Remove a VM, Create a VM
- An existing Availability Set part of the same Resource Group as the VM

#How it works#
- Get the Source AV Set, grab all VirtualMachinesReferences 
- Grab AZObject -object VirtualMachinesReferences
- For each VM in the VirtualMachinesReferences
    - Get the VM object (JSON)
    - Save the JSON configuration to a file (To rebuild the VM wherever it goes wrong)
    - Remove the VM (Only the configuration, all dependencies are kept ) 
    - Modify the VM object (change the AS)
    - Change the Storage config because the recration needs the disk attach option
    - ReCreate the VM

A Deployment Template file will be created for every VM touched by this script. This allows the recreation of that VM easily in case something goes wrong (the AVSet change actually deletes the original VM)
#if required, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
#>


[CmdletBinding()]
Param(
   [Parameter(Mandatory=$True,Position=2)]
   [string]$SourceAvailabilitySet,
   [Parameter(Mandatory=$False,Position=3)]
   [string]$TargetAvailabilitySet,
   [Parameter(Mandatory=$True,Position=1)]
   [string]$ResourceGroup,
   [Parameter(Mandatory=$False,Position=4)]
   [string]$VmSize,
   [Parameter(Mandatory=$False)]
   [ValidateSet('True','False',$null)]
   [string]$AcceleratedNIC,

   [Parameter(Mandatory=$False)]
   [boolean]$Login,
   [Parameter(Mandatory=$False)]
   [boolean]$SelectSubscription,
   [Parameter(Mandatory=$False)]
   [boolean]$PauseAfterEachVM,
   [Parameter(Mandatory=$False)]
   [boolean]$Report

)

If (!($VMsize)){
    $VMsize = $null
} #Need to specify $false for the resizing is no new size is given
If (!($AcceleratedNIC)){
    $AcceleratedNIC = $null
} 
If (!($TargetAvailabilitySet)){
    $TargetAvailabilitySet = $null
} 

Import-Module .\Change-AzAvailabilitySetMembers.psm1

write-host ""
write-host ""

#Cosmetic stuff
write-host ""
write-host ""
write-host "                               _____        __                                " -ForegroundColor Green
write-host "     /\                       |_   _|      / _|                               " -ForegroundColor Yellow
write-host "    /  \    _____   _ _ __ ___  | |  _ __ | |_ _ __ __ _   ___ ___  _ __ ___  " -ForegroundColor Red
write-host "   / /\ \  |_  / | | | '__/ _ \ | | | '_ \|  _| '__/ _' | / __/ _ \| '_ ' _ \ " -ForegroundColor Cyan
write-host "  / ____ \  / /| |_| | | |  __/_| |_| | | | | | | | (_| || (_| (_) | | | | | |" -ForegroundColor DarkCyan
write-host " /_/    \_\/___|\__,_|_|  \___|_____|_| |_|_| |_|  \__,_(_)___\___/|_| |_| |_|" -ForegroundColor Magenta
write-host "     "
write-host " This script reconfigures all VM's in an Availability Set" -ForegroundColor "Green"


#Importing the functions module and primary modules for AAD and AD

If (!((LoadModule -name AzureAD))){
    Write-host "Functions Module was not found - cannot continue - please make sure Set-AzAvailabilitySet.psm1 is available in the same directory"
    Exit
}
If (!((LoadModule -name Az.Compute))){
    Write-host "Az.Compute Module was not found - cannot continue - please install the module using install-module AZ"
    Exit
}

##Setting Global Paramaters##
$ErrorActionPreference = "Stop"
$date = Get-Date -UFormat "%Y-%m-%d-%H-%M"
$workfolder = Split-Path $script:MyInvocation.MyCommand.Path
$logFile = $workfolder+'\ChangeSize'+$date+'.log'
Write-Output "Steps will be tracked on the log file : [ $logFile ]" 

##Login to Azure##
If ($Login) {
    $Description = "Connecting to Azure"
    $Command = {LogintoAzure}
    $AzureAccount = RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
}


##Select the Subscription##
##Login to Azure##
If ($SelectSubscription) {
    $Description = "Selecting the Subscription : $Subscription"
    $Command = {Get-AZSubscription | Out-GridView -PassThru | Select-AZSubscription}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
}

#Validate Existence of AVSets
$ValidateSourceAs = Validate-AsExistence -ASName $SourceAvailabilitySet -VmRG $ResourceGroup -LogFile $logFile

If ($TargetAvailabilitySet){
    $ValidateTargetAs = Validate-AsExistence -ASName $TargetAvailabilitySet -VmRG $ResourceGroup -LogFile $logFile
    If (!($ValidateTargetAs)) {
        WriteLog "Target AV Set does not exist, please create it" -LogFile $LogFile -Color "Red" 
        exit
    }else{
        $TargetAVSetObjectID=(Get-AzAvailabilitySet -ResourceGroupName $ResourceGroup -Name $TargetAvailabilitySet).Id
    }
}
If (!($ValidateSourceAs)){
    WriteLog "Source AV Set does not exist, please create it" -LogFile $LogFile -Color "Red" 
    Exit   
}

If ($VMsize){
    [array]$AvailableSizes=Get-AzVMSize -ResourceGroupName $ResourceGroup -AvailabilitySetName $SourceAvailabilitySet
    If ($AvailableSizes.Name -contains $VMsize -and $VMsize) {
        WriteLog "  -Resizing VM's to new size: $VMSize" -LogFile $LogFile -Color "Yellow" 
    }else{
        WriteLog "!! Resizing VM's to new size: $VMSize failed !!" -LogFile $LogFile -Color "Red" 
        WriteLog "!! Possible entry error or size not available for AVset: $SourceAvailabilitySet" -LogFile $LogFile -Color "Red" 
        exit
    }
}

If ($ValidateSourceAs){
   
    #Can Continue
    #Grab all the VM's in the set - get their power status and move them
    $AllVMObjects = New-Object System.Collections.ArrayList
    $AllMembers=GetAVSetMembers -AvSetName $SourceAvailabilitySet -ResourceGroupName $ResourceGroup
    If (!($AllMembers)) {
        #No members returned, nothing do to 
        WriteLog "No members on Source AV Set found, exiting" -LogFile $LogFile -Color "Red"
        Exit
    }else{
            Write-host ""
            $totalCount=$AllMembers.count
            $Description = "The source AV Set has $totalCount VM's" 
            WriteLog -Description $Description -LogFile $LogFile -Color "Green"
            $i=0
            
            #Running export on all VM configurations
            $Description = "Exporting the configuration of all VM's "
            WriteLog -Description $Description -LogFile $LogFile
            ForEach ($VM in $AllMembers) {
                $i++
                #Get to the VM and check power-status
                $VMDetails=Get-AzResource -ResourceId $VM.id
                $VMname=$VMDetails.Name
                $VMObject=Get-AzVM -ResourceGroupName $VMDetails.ResourceGroupName -Name $VMDetails.Name
                #$Description = "Moving VM $i with name $VMname"
                #WriteLog -Description $Description -LogFile $LogFile
                #Exporting VM details
                $ResourceGroupName=$VMDetails.ResourceGroupName
                $Description = "  -Exporting the VM Config to a file : $ResourceGroupName-$VMName-Object.json "
                $Command = {ConvertTo-Json -InputObject $VmObject -Depth 100 | Out-File -FilePath $workfolder'\'$ResourceGroupName-$VMName'-Object.json'}
                RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

                #Exporting JSON template for the VM - This allows the VM to be easily re-deployed back to original state in case something goes wrong
                #if so, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
                [string]$ExportFile=($workfolder + '\' + $ResourceGroupName + '-' + $VMName + '.json')

                $Description = "  -Exporting the VM JSON Deployment file: $ExportFile "

                $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroupName -Resource $VM.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $ExportFile }
                RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
                #Adding the VM to an Array for bulk change if required
                $void=$AllVMObjects.add($VMObject)
            

            }
        write-host ""
        }
}



If (!($Parallel)){
    #Actually resizing the VM
    If ($Vmsize) {
        Write-host "Script does not validate Accelerated Networking for size change - please validate that your old & new size supports it"
        Write-host "It is possible to re-run this script with -SourceAVSet -AcceleratedNIC True after moving the VM's"
    }
    $Description = "Reconfiguring VM's 1-by-1 " 
    WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
    $i=0
        ForEach ($VMObject in $AllVMObjects) {
            $i++
            $VMname=$VMObject.Name
            If ($VMsize) {
                $Resize=$true
                
                #need to check if the VM fits the new size:
                    #data disks
                    #Accelerated Networking
                $SelectedSize=$AvailableSizes | where {$_.Name -eq $vmsize}

                If ($VMObject.StorageProfile.OsDisk.DiskSizeGB -gt ($SelectedSize.OSDiskSizeInMB)/1024){
                    $Description = "* # OSDisk of $VMname is too big for selected size"    
                    WriteLog -Description $Description -LogFile $LogFile -Color "Red"
                    $Resize=$false
                }
                If ($VMObject.StorageProfile.DataDisks.count -gt $SelectedSize.MaxDataDiskCount) {
                    $Description = "* # Datadisks on $VMname too large for selected size"    
                    WriteLog -Description $Description -LogFile $LogFile -Color "Red"
                    $Resize=$false
                }
                If ($VMObject.HardwareProfile.VmSize -eq $Vmsize) {
                    $Description = "* # Vmsize already applied to $VMname"    
                    WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                    $Resize=$false
                }
            }

            If ($AcceleratedNIC -or $Vmsize) {
                $nic=$null
                $Nic=Get-AzNetworkInterface -ResourceId $VMObject.NetworkProfile.NetworkInterfaces.id
                $AccelNic=$Nic.EnableAcceleratedNetworking
                $Description = "*   Accelerated Networking is: $AccelNic"    
                WriteLog -Description $Description -LogFile $LogFile 
                
            }


            If ($AcceleratedNIC -and ($AcceleratedNIC -eq $AccelNic)){
                $Description = "* # Accelerated setting already $AcceleratedNIC"
                WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                $SwitchNicMode=$false
            }elseif (!($AcceleratedNIC)){
                $SwitchNicMode=$null
            }else{
                $SwitchNicMode=$True
            }

            If (!($Report)){
                $Description = "* Configuring VM $i with name $VMname"
                WriteLog -Description $Description -LogFile $LogFile  -Color 'Green'
            }elseif ($Report -and (!($VMsize)) -and (!($AcceleratedNIC)) -and (!($TargetAvailabilitySet))){
                $Description = "* Report for VM $i with name $VMname" 
                WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
            }else{
                $Description = "* Configuration and Report for VM $i with name $VMname"
                WriteLog -Description $Description -LogFile $LogFile -Color 'Green'

            }


            If ($Report){
                $CurrentVMSize=$VMObject.HardwareProfile.VmSize
                $VMOSDiskSize=$VMObject.StorageProfile.OsDisk.DiskSizeGB
                $VMDataDisks=$VMObject.StorageProfile.DataDisks.count

                $nic=$null
                $Nic=Get-AzNetworkInterface -ResourceId $VMObject.NetworkProfile.NetworkInterfaces.id
                $AccelNic=$Nic.EnableAcceleratedNetworking
                $PriIP=$nic.IpConfigurations[0].PrivateIpAddress
               
                $Description = "* # Hardware Size is: $CurrentVMSize"  
                WriteLog -Description $Description -LogFile $LogFile 

                $Description = "* # OsDisk size is: $VMOSDiskSize GB"    
                WriteLog -Description $Description -LogFile $LogFile 

                $Description = "* # Number of data drives: $VMDataDisks"    
                WriteLog -Description $Description -LogFile $LogFile 

                $Description = "* # Accelerated Networking is: $AccelNic"    
                WriteLog -Description $Description -LogFile $LogFile 
            }

            If ($Resize -or $SwitchNicMode -or $ValidateTargetAs){
                $PowerStatus=StopAZVM -VMObject $VMObject -LogFile $LogFile
            }
        

            If ($SwitchNicMode){
                $Description = "  -Updating Accelerated Nic to $AcceleratedNIC"
                WriteLog -Description $Description -LogFile $LogFile 
                $nic.EnableAcceleratedNetworking = $AcceleratedNIC
                $void=$nic | Set-AzNetworkInterface
            }

            If ($Resize){
                $Description = "  -Updating to size $Vmsize"
                WriteLog -Description $Description -LogFile $LogFile 
                $VMObject.HardwareProfile.VmSize = $VmSize
                $void=Update-AzVM -VM $VMObject -ResourceGroupName $VMObject.ResourceGroupName
            }
            
            If ($PowerStatus -and (!($ValidateTargetAs))) {
                Write-host "  -Starting VM" -ForegroundColor Yellow -NoNewline
                $void=Start-AZVM -Name $VMObject.name -ResourceGroupName $VMObject.ResourceGroupName
            }
           
            If ($ValidateTargetAs) {
                $Description = "  -Moving VM to $TargetAvailabilitySet"
                WriteLog -Description $Description -LogFile $LogFile 
 
                Set-AsSetting -VmObject $VmObject -TargetASObject $TargetAVSetObjectID -LogFile $LogFile -vmSize $VmSize
                    Write-host "  -Validating if VM exists" -ForegroundColor Yellow -NoNewline
                Do {
                    Write-host "." -NoNewline -ForegroundColor Yellow
                    Start-Sleep 1
                }
                While (!(Validate-VmExistence -VmName $VMObject.Name -VmRG $VMObject.ResourceGroupName -logFile $logFile)){
                }
            }

            $Description = "  -VM Reconfig Completed"
            WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
            Write-host "...  ----------------------  ..."
            if ($PauseAfterEachVM -and $VMObjects.count -ne $i) {
                write-host "Next resize has been paused as per PauseAfterEachVM option" -ForegroundColor CYAN
                write-host "            ...Press any key to continue..."  -ForegroundColor CYAN
                [void][System.Console]::ReadKey($true)
            }

        } #end of Resize per VM
    
    Write-host "** All VM's have been resized to $VMsize **" -ForegroundColor "Green"

}





