ScriptName : Change-AzAvailabilitySetMembers
Description : This script will reconfigure all VM's of an availability set

options are: 
-move to new AV set (-TargetAvailabilitySet <AvSetName>
- Resize the VM's (-VMsize <vmsize>)
- Enabled Accelerated NIC's (-AcceleratedNIC <True/False>)

-Report $true
  Runs a report on the existing VM's  - if given solely with SourceAVSet will not execute, but only create a JSON back for each VM
  
-PauseAfterEachVM
  Pauses after each VM for manual check
  
  
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
    
    Depending on the mode:
    * Change NIC Accelerated mode
      - Get the NIC properties
      - Change to required setting
    
    * Resize
      - Check new size available in AVSet
      - Run Resize of VM if needed
      
     *New AVSet
    - Remove the VM (Only the configuration, all dependencies are kept ) 
    - Modify the VM object (change the AS)
    - Change the Storage config because the recration needs the disk attach option
    - ReCreate the VM

    
A Deployment Template file will be created for every VM touched by this script. This allows the recreation of that VM easily in case something goes wrong (the AVSet change actually deletes the original VM)
#if required, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>
#>
