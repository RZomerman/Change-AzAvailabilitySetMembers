<#

 
ScriptName : Change-AzAvailabilitySetMembers
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
   [boolean]$Report,
   [Parameter(Mandatory=$False)]
   [int]$Parallel,
   [Parameter(Mandatory=$False)]
   [int]$BatchSkip,
   [Parameter(Mandatory=$False)]
   [int]$FaultDomain=99,
   [Parameter(Mandatory=$False)]
   [int]$UpdateDomain=99,
   [Parameter(Mandatory=$False)]
   [string]$TargetVM,
   [Parameter(Mandatory=$False)]
   [string]$TargetVMResourceGroup

)

#If (!($VMsize)){
#    $VMsize = $null
#} #Need to specify $false for the resizing is no new size is given
If (!($AcceleratedNIC)){
    $AcceleratedNIC = $null
} 
If (!($TargetAvailabilitySet)){
    $TargetAvailabilitySet = $null
} 

If ($TargetVM) {
    $Parallel=1
}

If (!($TargetVMResourceGroup)) {
    $TargetVMResourceGroup = $ResourceGroup
}
#Importing the functions module and primary modules for AAD and AD
If ((Get-Module).name -contains "Change-AzAvailabilitySetMembers") {
    write-host "reloading module"
    Remove-Module "Change-AzAvailabilitySetMembers"
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


If (!((LoadModule -name Az.Compute))){
    Write-host "Az.Compute Module was not found - cannot continue - please install the module using install-module AZ"
    Exit
}

##Setting Global Paramaters##
$ErrorActionPreference = "Stop"
$date = Get-Date -UFormat "%Y-%m-%d-%H-%M"
$workfolder = Split-Path $script:MyInvocation.MyCommand.Path
$logFile = $workfolder+'\ChangeSize'+$date+'.log'
write-host ""
write-host ""
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

WriteLog "Validating AV set input" -LogFile $LogFile -Color "Green" 
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
    #In parallel runmode need to perform size change against target - while in regular more (as there is no delete in !Parallel possible)   
    If ($Parallel -and $TargetAvailabilitySet) {
        [array]$AvailableSizes=Get-AzVMSize -ResourceGroupName $ResourceGroup -AvailabilitySetName $TargetAvailabilitySet
    }else{
        [array]$AvailableSizes=Get-AzVMSize -ResourceGroupName $ResourceGroup -AvailabilitySetName $SourceAvailabilitySet
    }
    
    If ($AvailableSizes.Name -contains $VMsize -and $VMsize) {
        WriteLog "  -Resizing VM's to new size: $VMSize" -LogFile $LogFile -Color "Yellow" 
    }else{
        WriteLog "!! Resizing VM's to new size: $VMSize failed !!" -LogFile $LogFile -Color "Red" 
        If ($Parallel){
            WriteLog "!! Possible entry error or size not available for AVset: $TargetAvailabilitySet" -LogFile $LogFile -Color "Red" 
        }else{
            WriteLog "!! Possible entry error or size not available for AVset: $SourceAvailabilitySet" -LogFile $LogFile -Color "Red" 
        }
        
        exit
    }
}
If ($ValidateSourceAs){
    #Can Continue
    #Grab all the VM's in the set - get their power status and move them
    #If parallel is selected, we will only select the first $Parallel VM's

    $AvsetObject=Get-AzAvailabilitySet -Name $SourceAvailabilitySet -ResourceGroupName $ResourceGroup
    $FaultOrUpdateDomains=$False
    
    if (($UpdateDomain -ge 0 -or $FaultDomain -ge 0) -and ($UpdateDomain -ne 99 -or $FaultDomain -ne 99) ){
        $sourceUpdateDomains=$AvsetObject.PlatformUpdateDomainCount
        $sourceFaultDomains=$AvsetObject.PlatformFaultDomainCount
        If ($updateDomain -gt $sourceUpdateDomains -and $updateDomain -ne 99){
            WriteLog "!! Cannot find the $updateDomain Update Domains - Source AV Set has only $sourceUpdateDomains  !!" -LogFile $LogFile -Color "Red" 
            Exit
        }
        if ($FaultDomain -gt $sourceFaultDomains -and $FaultDomain -ne 99){
            WriteLog "!! Cannot find the $FaultDomain Fault Domains - Source AV Set has only $sourceFaultDomains  !!" -LogFile $LogFile -Color "Red" 
            Exit
        }
        $FaultOrUpdateDomains=$True
    }
    
    write-host ""
    [array]$AllMembers=$AvsetObject.VirtualMachinesReferences
    If (!($AllMembers) -or $AllMembers.count -eq 0 ){
        #No members returned, nothing do to 
        WriteLog "No members on Source AV Set found, exiting" -LogFile $LogFile -Color "Red"
        Exit
    }
    #ArrayList allows removal and adding of nodes - required for Update/FaultDomain Filtering as that is per VM
    #[System.Collections.ArrayList]$AllMembers=GetAVSetMembers -AvSetObject $AvsetObject -ResourceGroupName $ResourceGroup

    $totalCount=$AllMembers.count
    $Description = "Source AV Set has $totalCount VM's" 
    WriteLog -Description $Description -LogFile $LogFile -Color "Green"

    If ($Parallel){
        $Description = " -Parallel limit set to $Parallel" 
        WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"        
    }

    If ($FaultDomain -ge 0 -and $FaultDomain-ne 99){
        $Description = " -Scope limited to Fault Domain $FaultDomain" 
        WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"        
    }
    If ($UpdateDomain -ge 0 -and $UpdateDomain-ne 99){
        $Description = " -Scope limited to Update Domain $UpdateDomain" 
        WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"        
    }
    If ($TargetVM){
        $Description = " -Scope limited to VM $VM" 
        WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"        

    }




   
   
    If ($AllMembers){
        #This section filters the initial list of all VM id's in the VirtualMachinesReferences attribute on the source AV
        #Filtering if done for _ Parallel _ Fault&Update domains _ VMNames
        

        $AllMembers=$AllMembers.id

        #If no update/fault domains specified, but only Parallel jobs, no need to get all the VM's in the set $Allmembers is Object.ID
        #so early filter on parallel
        If ($Parallel -and ($FaultOrUpdateDomains -eq $False) -and (!($TargetVM)) -and ($TargetAvailabilitySet)) {
            $Description = "Filtering on Parallel limit" 
            WriteLog -Description $Description -LogFile $LogFile -Color "Green"
            $AllMembers=$AllMembers | select -first $Parallel
        }

        If ($Parallel -and ($FaultOrUpdateDomains -eq $False) -and (!($TargetVM)) -and (!($TargetAvailabilitySet))-and ($BatchSkip)) {
            $Description = "Filtering on Parallel limit - but VM's aren't moved to new AV set..." 
            WriteLog -Description $Description -LogFile $LogFile -Color "Green"
            $AllMembers=$AllMembers | select -Skip $BatchSkip
            $AllMembers=$AllMembers | select -first $Parallel
            $void=$allMembers.count

        }


        #If single VM is given, need to filter on that VM
        If ($TargetVM){
            $TargetObjectVM = Get-AZVm -ResourceGroupName $TargetVMResourceGroup -Name $TargetVM
            If ($AllMembers -contains $TargetObjectVM.id){
                $AllMembers=$AllMembers|where {$_ -contains $TargetObjectVM.id}
                WriteLog -Description ("  -Filter applied for $TargetVM") -LogFile $LogFile -Color "Green"    
                $AllMembers
            }
        }    
        #Exit based on VMname not found in set
        If ($AllMembers -eq 0) {   
            WriteLog -Description ("-All VM's filtered for this AV set-") -LogFile $LogFile -Color "Red"
            exit
        }


        #NEED TO GET ALL VM"S IN 1 OBJECT ARRAY

        Write-host " -Retrieving VMs" -NoNewline -ForegroundColor Yellow
        $AllMemberObjects = New-Object System.Collections.ArrayList


        ForEach ($VM in $AllMembers) {
            $i++
            #Get to the VM and check power-status
            $VMDetails=Get-AzResource -ResourceId $VM
            $VMname=$VMDetails.Name
            $VMObject=Get-AzVM -ResourceGroupName $VMDetails.ResourceGroupName -Name $VMDetails.Name
            $void=$AllMemberObjects.Add($VMObject)
            write-host "." -ForegroundColor Yellow -NoNewline
        }

        #Filter the AllMemberObjects to remove some noise
        $AllMemberObjects = $AllMemberObjects | where {$AllMemberObjects.id}

        #IF UPDATE / FAULT - NEED TO FILTER ARRAYLIST
        If ($FaultOrUpdateDomains) {
            $totalCount=$AllMemberObjects.count
            WriteLog -Description (" -Applying filters") -LogFile $LogFile -Color "Green"
            $AllMemberObjects=FilterMembers -VMObjectArray $AllMemberObjects -FaultDomain $FaultDomain -UpdateDomain $updateDomain -LogFile $LogFile
            If ($AllMemberObjects -eq $False) {   
                WriteLog -Description ("-All VM's filtered for this AV set-") -LogFile $LogFile -Color "Red"
                exit
            }
            $AllMemberObjects=$AllMemberObjects |where {$_.id}

            #$AllMemberObjects
        }
        

        
        #resetting object
        $VMObject=$null

        #FilterForMaxNumberInParallel and in Fault/UpdateDomains
        If ($Parallel -and ($FaultOrUpdateDomains -eq $True) -and (!($TargetVM))) {
            $AllMembers=$AllMembers | select -first $Parallel
        }

        Write-host ""
        WriteLog -Description (" -Exporting selected VM details") -LogFile $LogFile -Color "Green"
        ForEach ($VMObject in $AllMemberObjects){
            $void=ExportVMConfigJSON -VMObject $VMObject -workfolder $workfolder -LogFile $LogFile
        }
        write-host ""
        #resetting object
        $VMObject=$null
    }
}


If ($Parallel){
    #Actually reconfiguring the VMs in the ObjectSet
    $totalCount=$AllMemberObjects.count
    If ($Parallel -ge $totalCount) {
        Write-host "Running changes in parallel for $totalCount VM's" -ForegroundColor Green    
    }else{
        Write-host "Running changes in parallel for $Parallel VM's" -ForegroundColor Green
    }
    If ($Vmsize -or $AcceleratedNIC) {
        write-host !!
        Write-host "Script does not validate Accelerated Networking for size change - please validate that your old & new size supports it"
        Write-host "It is possible to re-run this script with -SourceAVSet -AcceleratedNIC True after moving the VM's"
        If ($VMSize -and (!($AcceleratedNIC))) {
            Write-host "!!WARNING!! Deployment might fail if new VM size does not support Accelerated Networking !!WARNING!!" -ForegroundColor Yellow
            write-host !!
        }elseIf (!($VMSize) -and ($AcceleratedNIC)) {
            Write-host "!!WARNING!! Deployment might fail if existing VM size does not support Accelerated Networking !!WARNING!!" -ForegroundColor Yellow
            write-host !!
        }else{
            Write-host "!!WARNING!! Deployment might fail if new VM size does not support Accelerated Networking !!WARNING!!" -ForegroundColor Yellow
            write-host !!
        }
    
    }

    #ALWAYS NEED TO VALIDATE IF SIZE IS AVAILABLE IN TARGET AVSET IF SWICTING - given the speed.. only doing this for 1 VM
    If ($vmsize ) {
        $SelectedSize=$AvailableSizes | where {$_.Name -eq $vmsize}
    }elseif ($ValidateTargetAs){
        $SelectedSize=$AvailableSizes | where {$_.Name -eq $AllMemberObjects[0].HardwareProfile.VmSize}
    }else{
        #NIC config only - no validation possible for supported VMsizes
    }


    $VMsToBeDeleted = New-Object System.Collections.ArrayList

    write-host ""
#Validating if existing jobs are running in the background and if so.. need to wait for those to complete. 
    $void=AreJobsRunning -LogFile $LogFile 

#Initializing a new array for NIC's
    $AllMemberNicIDs = New-Object System.Collections.ArrayList

    $i=0
    $vmsInset=0
                ForEach ($VMObject in $AllMemberObjects) {
                    $i++ #Counter for Parallel
                    $vmsInset++ #Counter for all VM's done in set
                    $VMname=$VMObject.Name
                    $ResourceGroupName=$VMObject.ResourceGroupName
                    $ImportFile=($workfolder + '\' + $ResourceGroupName + '-' + $VMName + '.json')
                    $NewDeploymentFile=($workfolder + '\' + $ResourceGroupName + '-' + $VMName + '-new.json')
                    #Create copy of the export file
                    $VMObjectFile = (Get-Content $ImportFile | Out-String | ConvertFrom-Json)

                    #Set the ImageOption for the OS disks and Data disks to Attach instead of CreateFromImage for restore
                    If ($VMObjectFile.resources.properties.storageprofile.osDisk.createOption -eq 'FromImage') {
                        ($VMObjectFile.resources.properties.storageprofile.osDisk.createOption = "Attach")
                    }
                    If ($VMObjectFile.resources.properties.storageProfile.dataDisks) {
                        Foreach ($DatadiskEntry in $VMObjectFile.resources.properties.storageProfile.dataDisks) {
                            If ($DatadiskEntry.createoption = 'FromImage') {
                                $DatadiskEntry.createoption = "Attach"
                            }
                        }
                    }
                    If ($VMObjectFile.resources.properties.storageProfile.imageReference.id) {
                        $VMObjectFile.resources.properties.storageProfile.imageReference.id = $null
                    }
                    If ($VMObjectFile.resources.properties.osProfile) {
                        $VMObjectFile.resources.properties.osProfile = $null
                    }
                    
                    if ($VmObject.resources.properties.storageProfile.OsDisk.Image) {
                        $VmObject.resources.properties.storageProfile.OsDisk.Image = $null
                    }
                    

                If ($VMsize) {
                    $Resize=$true
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
                    #need to exclude the !$TargetAvailabilitySet options else OnlyResize will fail
                    If ($VMObject.HardwareProfile.VmSize -eq $Vmsize -and $TargetAvailabilitySet) {
                        $Description = "* # Vmsize already applied to $VMname"    
                        WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                        $Resize=$false
                    }
                }


                If ($Resize -and $TargetAvailabilitySet){
                    #Given TargetAvailabilitySet is mentioned - deleting the VM so no need for manual VMsize update
                    #change the value of the export file           "vmSize": "Standard_D1_v2" + "vmSize": "Standard_D2_v2"
                    $VMObjectFile.resources.properties.hardwareProfile.Vmsize = $VMsize
                }elseif($Resize -and (!($TargetAvailabilitySet))){
                    #Only a resize will be required, this can be done by updating the VM (it will reboot)
                    If (($VmObject.HardwareProfile.VmSize).ToUpper() -ne $Vmsize.ToUpper()){
                        $VMName=$VMObject.name
                        $Description = "  -Updating to $VMName to size $Vmsize"
                        WriteLog -Description $Description -LogFile $LogFile 
                        $VmObject.HardwareProfile.VmSize=$Vmsize
                        $void=Update-AzVM -VM $VMObject -ResourceGroupName $VMObject.ResourceGroupName -AsJob
                    }else{
                        $Description = "   # Vmsize already applied to $VMname"
                        WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                    }

                }else{ #must be TargetAV or No Resize or No Resize No TargetAV
                    #will trigger either nothing or $TargetAVSet deletion of VM
                    #write-host "Nothing to do" -ForegroundColor Red
                }

                If ($TargetAvailabilitySet) {
                    #write-host "TargetAVSetName - Adding $VMname"
                    #given TargetAVset was found - need to delete the VM - regardless of VMSize change
                    #CHANGE - NEED TO DELETE ALL OF THEM IN 1 GO - so create an array of VM's and then AsJob delete all of them in a function
                    $void=$VMsToBeDeleted.add($VMname)
                }

                If ($TargetAvailabilitySet) {
                    #Write the final deployment file and deploy
                    If ($SourceAvailabilitySet -match "-") {
                        $JsonFormattedSourceAvailabilitySet=$SourceAvailabilitySet.Replace("-","_")
                    }else{
                        $JsonFormattedSourceAvailabilitySet=$SourceAvailabilitySet
                    }
                    $externalidChange=('availabilitySets_' + $JsonFormattedSourceAvailabilitySet + '_externalid')
                    $VMObjectFile.parameters.$externalidChange.defaultValue = $TargetAVSetObjectID
                    #Need to disable the proximityPlacementGroup (will be readded if applicable to AVSet)
                    If ($VMObjectFile.resources.properties.proximityPlacementGroup) {
                        $VMObjectFile.resources.properties.proximityPlacementGroup=$null
                    }

                    $void=ConvertTo-Json -InputObject $VMObjectFile -Depth 100 | Out-File -FilePath $newDeploymentFile -Force
                    #$DeploymentName=('deployment' + $VMname + '-' + $i)

                    #$Description = "Re-Deploying VM " 
                    #WriteLog -Description $Description -LogFile $LogFile -Color 'Green'

                    #NEED TO CREATE ALL OF THEM in 1 GO- Create an array and functionize this
                   # New-AzResourceGroupDeployment -Name $DeploymentName -ResourceGroup $ResourceGroup -TemplateFile $newDeploymentFile -AsJob
                }
                If ($AcceleratedNIC){
                    #Need to get the NIC ID for Each VM
                    ForEach ($NICProperty in $VMObjectFile.resources.properties.networkProfile.networkInterfaces){
                        $ParameterForNic=$NICProperty.id
                        #[parameters('networkInterfaces_vm00b921_externalid')]
                        $ParameterForNic=$ParameterForNic.Replace("[parameters('","")
                        $ParameterForNic=$ParameterForNic.Replace("')]","")
                        #write-host $VMObjectFile.parameters.$ParameterForNic.defaultValue
                        $void=$AllMemberNicIDs.Add($VMObjectFile.parameters.$ParameterForNic.defaultValue)
                        $ParameterForNic=$null
                    }
                }
            }#END FOR EACH VM LOOP

        #As all resize only jobs run in background, this is to monitor those and quit once done
        If($Resize -and (!($TargetAvailabilitySet))){
            $void=MonitorJobs OperationName "Update-AzVM" -LogFile $LogFile
            $Description = "  -Size update complete"
            WriteLog -Description $Description -LogFile $LogFile 
            $Description = " -All VM's done -"
            WriteLog -Description $Description -LogFile $LogFile -Color "Green"
            exit
        }

            $Description = "  -Preparations done"
            WriteLog -Description $Description -LogFile $LogFile -Color "Green"
            $Description = "   -Deployment files folder: $workfolder"
            WriteLog -Description $Description -LogFile $LogFile -Color "CYAN"
            #End of For Each
            #Shutdown the VM's in the VMsToBeShutdown Array


#START OF ACTUAL RUNTIME - All ARRAYS HAVE BEEN CREATED AND FILLED: VMSTOBEDELETED == VMS TO TOUCH WITH DELETION PROCESS & $AllMemberNicIDs for all NICs to update to accelerated networking
            $Step=1
            If ($VMsToBeDeleted) {
                write-host 
                $Description = "  -Starting deletion"
                WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                [array]$RebuildVMs=DeleteAzVM -VMsToDelete $VMsToBeDeleted -ResourceGroupName $ResourceGroupName -LogFile $Logfile -Step $Step
            }

            #Added to support AcceleratedNIC options for VM/NIC While VM is deleted but NIC isn't (no need to shutdown VM)
            If ($AcceleratedNIC){
                $Step++
                write-host 
                $Description = "  -Starting NIC updates"
                WriteLog -Description $Description -LogFile $LogFile -Color "Green"   
                $n=0
                ForEach($NICID in $AllMemberNicIDs){
                    $n++
                    $nicObject=Get-AzNetworkInterface -ResourceId $NICID
                    $NicName=$nicObject.Name

                    If ($AcceleratedNIC -eq "True") {$FutureNicStatus=$True}
                    If ($AcceleratedNIC -eq "False") {$FutureNicStatus=$False}

                    If ($nicObject.EnableAcceleratedNetworking -ne $FutureNicStatus) {
                        If ($AcceleratedNIC -eq "True"){
                            $Description = "   -(Step 2.$n : Enabling Accelerated Networking for NIC $NicName)"
                            #WriteLog -Description $Description -LogFile $LogFile -Color "Green"   
                            $nicObject.EnableAcceleratedNetworking = $True
                        }elseif ($AcceleratedNIC -eq "False"){
                            $Description = "   -(Step 2.$n : Disabling Accelerated Networking for NIC $NicName)"
                            #WriteLog -Description $Description -LogFile $LogFile -Color "Green"   
                            $nicObject.EnableAcceleratedNetworking = $False
                        }else{
                            $Description = "   -(Step 2.$n : Unknown setting for Accelerated Networking for NIC $NicName)"
                        }
                    #Performin the actual NIC update
                    $void=Set-AzNetworkInterface -NetworkInterface $nicObject -AsJob
                    WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"
                    }else{
                        $Description = "   -Accelerated Networking for NIC $NicName already set to $AcceleratedNIC "
                        WriteLog -Description $Description -LogFile $LogFile -Color "Green"   
        
                    }
                    
                }
                $void=MonitorJobs OperationName "Set-AzNetworkInterface" -LogFile $LogFile

            }
            
<#  
                $Description = "  -Updating Accelerated Nic to $AcceleratedNIC"
                WriteLog -Description $Description -LogFile $LogFile 
                $nic.EnableAcceleratedNetworking = $AcceleratedNIC
                $void=$nic | Set-AzNetworkInterface
#>
            

            If ($RebuildVMs) {
                #Recreate the VM's from the deleted VMs list
                write-host ""
                $Description = "  -Starting deployments"
                WriteLog -Description $Description -LogFile $LogFile -Color "Green"
                
                #Foreach ($entry in $VMsToBeDeleted) {
                #    $Description = "   -Redeploying $entry"
                #    WriteLog -Description $Description -LogFile $LogFile -Color "Yellow"
                #}
                $DeployedVMarray=DeployResource -VMstoDeploy $VMsToBeDeleted -ResourceGroupName $ResourceGroupName -workfolder $workfolder -LogFile $LogFile -Step $Step
            }

}


If (!($Parallel)){
    #Actually resizing the VM
    If ($Vmsize -or $AcceleratedNIC) {
        write-host !!
        Write-host "Script does not validate Accelerated Networking for size change - please validate that your old & new size supports it"
        Write-host "It is possible to re-run this script with -SourceAVSet -AcceleratedNIC True after moving the VM's"
        If ($VMSize -and (!($AcceleratedNIC))) {
        Write-host "!!WARNING!! Deployment might fail if new VM size does not support Accelerated Networking !!WARNING!!" -ForegroundColor Yellow
        write-host !!
        }
        If (!($VMSize) -and ($AcceleratedNIC)) {
            Write-host "!!WARNING!! Deployment might fail if existing VM size does not support Accelerated Networking !!WARNING!!" -ForegroundColor Yellow
            write-host !!
            }
    
    }
    $Description = "Reconfiguring VM's 1-by-1 " 
    WriteLog -Description $Description -LogFile $LogFile -Color 'Green'
    $i=0
        ForEach ($VMObject in $AllMemberObjects) {
            $i++
            $VMname=$VMObject.Name

            if ($PauseAfterEachVM) {
                write-host "The following VM is the next target, please prepare the node for shutdown" -ForegroundColor CYAN
                Write-host $VMname
                write-host "            ...Press any key to continue..."  -ForegroundColor CYAN
                [void][System.Console]::ReadKey($true)
            }

            #ALWAYS NEED TO VALIDATE IF SIZE IS AVAILABLE IN TARGET AVSET IF SWICTING
                If ($vmsize ) {
                    $SelectedSize=$AvailableSizes | where {$_.Name -eq $vmsize}
                }elseif ($ValidateTargetAs){
                    $SelectedSize=$AvailableSizes | where {$_.Name -eq $VMObject.HardwareProfile.VmSize}
                }else{
                    #NIC config only - no validation possible for supported VMsizes
                }

            If ($VMsize) {
                $Resize=$true
                
                #need to check if the VM fits the new size:
                    #data disks
                    #Accelerated Networking


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

            If ($Resize -or $SwitchNicMode){
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
    
    Write-host "** All VM's have been reconfigured **" -ForegroundColor "Green"

}





