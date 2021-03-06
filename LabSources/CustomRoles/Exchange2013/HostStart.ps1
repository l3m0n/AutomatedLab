param(
    [Parameter(Mandatory)]
    [string]$ComputerName,

    [string]$OrganizationName,

    [ValidateSet('True', 'False')]
    [string]$AddAdRightsInRootDomain,

    [ValidateSet('True', 'False')]
    [string]$PrepareSchema,

    [ValidateSet('True', 'False')]
    [string]$PrepareAD,

    [ValidateSet('True', 'False')]
    [string]$PrepareAllDomains,

    [ValidateSet('True', 'False')]
    [string]$InstallExchange
)

function Copy-ExchangeSources
{
    Write-ScreenInfo -Message 'Download Exchange 2013 requirements' -TaskStart
    $downloadTargetFolder = "$labSources\SoftwarePackages"
    Write-ScreenInfo -Message "Downloading Exchange 2013 from '$exchangeDownloadLink'"
    $script:exchangeInstallFile = Get-LabInternetFile -Uri $exchangeDownloadLink -Path $downloadTargetFolder -PassThru -ErrorAction Stop
    Write-ScreenInfo -Message "Downloading UCMA from '$ucmaDownloadLink'"
    $script:ucmaInstallFile = Get-LabInternetFile -Uri $ucmaDownloadLink -Path $downloadTargetFolder -PassThru -ErrorAction Stop
    Write-ScreenInfo -Message "Downloading .net Framework 4.6.2 from '$dotnetDownloadLink'"
    $script:dotnetInstallFile = Get-LabInternetFile -Uri $dotnetDownloadLink -Path $downloadTargetFolder -PassThru -ErrorAction Stop
    Write-ScreenInfo 'finished' -TaskEnd
    
    #distribute the sources to all exchange servers and the RootDC
    foreach ($vm in $vms)
    {
        Write-ScreenInfo "Copying sources to VM '$vm'" -TaskStart
        if ($vm.HostType -eq 'HyperV')
        {
            Copy-LabFileItem -Path $exchangeInstallFile.FullName -DestinationFolderPath C:\Install -ComputerName $ComputerName
            Copy-LabFileItem -Path $ucmaInstallFile.FullName -DestinationFolderPath C:\Install -ComputerName $ComputerName
            Copy-LabFileItem -Path $dotnetInstallFile.FullName -DestinationFolderPath C:\Install -ComputerName $ComputerName
        }
        Write-ScreenInfo "Finished copying file to VM '$vm'" -TaskEnd
    }
    
    Write-ScreenInfo 'Exctracting Exchange Installation files on all machines' -TaskStart -NoNewLine
    $jobs = Install-LabSoftwarePackage -LocalPath "C:\Install\$($exchangeInstallFile.FileName)" -CommandLine '/X:C:\Install\ExchangeInstall /Q' -ComputerName $vms -AsJob -PassThru -NoDisplay
    Wait-LWLabJob -Job $jobs -ProgressIndicator 10 -NoDisplay
    Write-ScreenInfo 'finished' -TaskEnd
}

function Add-ExchangeAdRights
{
    #if the exchange server is in a child domain the administrator of the child domain will be added to the group 'Organization Management' of the root domain
    if ($vm.DomainName -ne $schemaPrepVm.DomainName)
    {
        $dc = Get-LabVM -Role FirstChildDC | Where-Object DomainName -eq $vm.DomainName
        $userName = ($lab.Domains | Where-Object Name -eq $vm.DomainName).Administrator.UserName

        Write-ScreenInfo "Adding '$userName' to  'Organization Management' group" -TaskStart
        Invoke-LabCommand -ActivityName "Add '$userName' to Forest Management" -ComputerName $schemaPrepVm -ScriptBlock {
            param($userName, $Server)

            $user = Get-ADUser -Identity $userName -Server $Server

            Add-ADGroupMember -Identity 'Schema Admins' -Members $user
            Add-ADGroupMember -Identity 'Enterprise Admins' -Members $user
        } -ArgumentList $userName, $dc.FQDN -NoDisplay
        Write-ScreenInfo 'finished' -TaskEnd
    }
}

function Install-ExchangeWindowsFeature
{
    Write-ScreenInfo "Installing Windows Features 'Server-Media-Foundation' on '$vm'"  -TaskStart -NoNewLine
    if ((Get-LabWindowsFeature -ComputerName $vm -FeatureName Server-Media-Foundation, RSAT-ADDS-Tools | Where-Object { $_.Installed }).Count -ne 2)
    {
        $jobs += Install-LabWindowsFeature -ComputerName $vm -FeatureName Server-Media-Foundation, RSAT-ADDS-Tools -UseLocalCredential -AsJob -PassThru -NoDisplay
        Wait-LWLabJob -Job $jobs -NoDisplay
        Restart-LabVM -ComputerName $vm -Wait
    }
    Write-ScreenInfo 'finished' -TaskEnd
}

function Install-ExchangeRequirements
{
    Write-ScreenInfo "Installing Exchange Requirements '$vm'"  -TaskStart -NoNewLine

    $isUcmaInstalled = Invoke-LabCommand -ActivityName 'Test UCMA Installation' -ComputerName $vm -ScriptBlock {
        Test-Path -Path 'C:\Program Files\Microsoft UCMA 4.0\Runtime\Uninstaller\Setup.exe'
    } -PassThru

    $jobs = @()

    if (-not $isUcmaInstalled)
    {
        $jobs += Install-LabSoftwarePackage -ComputerName $vm -LocalPath "C:\Install\$($script:ucmaInstallFile.FileName)" -CommandLine '/Quiet /Log c:\ucma.txt' -AsJob -PassThru -NoDisplay
        Wait-LWLabJob -Job $jobs -NoDisplay -ProgressIndicator 20 -NoNewLine
    }
    else
    {
        Write-ScreenInfo "UCMA is already installed on '$vm'" -Type Verbose
    }

    foreach ($machine in $vms)
    {
        $dotnetFrameworkVersion = Get-LabVMDotNetFrameworkVersion -ComputerName $machine -NoDisplay
        if ($dotnetFrameworkVersion.Version -notcontains '4.6.2')
        {
            Write-ScreenInfo "Installing .net Framework 4.6.2 on '$machine'" -Type Verbose
            $jobs += Install-LabSoftwarePackage -ComputerName $machine -LocalPath "C:\Install\$($script:dotnetInstallFile.FileName)" -CommandLine '/q /norestart /log c:\dotnet462.txt' -AsJob -NoDisplay -AsScheduledJob -UseShellExecute -PassThru
        }
        else
        {
            Write-ScreenInfo ".net Framework 4.6.2 is already installed on '$machine'" -Type Verbose
        }
    }

    Wait-LWLabJob -Job $jobs -NoDisplay -ProgressIndicator 20 -NoNewLine
    Write-ScreenInfo done
        
    Write-ScreenInfo -Message 'Restarting machines' -NoNewLine
    Restart-LabVM -ComputerName $vms -Wait -ProgressIndicator 10 -NoDisplay

    Sync-LabActiveDirectory -ComputerName $schemaPrepVm
    Write-ScreenInfo 'finished' -TaskEnd
}

function Start-ExchangeInstallSequence
{
    param(
        [Parameter(Mandatory)]
        [string]$Activity,
        
        [Parameter(Mandatory)]
        [string]$ComputerName,
        
        [Parameter(Mandatory)]
        [string]$CommandLine
    )
    
    Write-LogFunctionEntry

    Write-ScreenInfo -Message "Starting activity '$Activity'" -TaskStart -NoNewLine

    try
    {
        $job = Install-LabSoftwarePackage -ComputerName $ComputerName -LocalPath C:\Install\ExchangeInstall\setup.exe -CommandLine $CommandLine `
        -ExpectedReturnCodes 1 -AsJob -NoDisplay -PassThru -ErrorVariable exchangeError
        $result = Wait-LWLabJob -Job $job -NoDisplay -ProgressIndicator 15 -PassThru -ErrorVariable jobError
        if ($jobError)
        {
            Write-Error -ErrorRecord $jobError -ErrorAction Stop
        }
        if ($result -clike '*FAILED*')
        {
            Write-Error -Message 'Exchange Installation failed' -ErrorAction Stop
        }
    }
    catch
    {
        if ($_ -match '(.+reboot.+pending.+)|(.+pending.+reboot.+)')
        {
            Write-ScreenInfo "Activity '$Activity' did not succeed, Exchange Server '$ComputerName' needs to be restarted first." -Type Warning -NoNewLine
            Restart-LabVM -ComputerName $ComputerName -Wait -NoNewLine
            Start-Sleep -Seconds 30 #as the feature installation can trigger a 2nd reboot, wait for the machine after 30 seconds again
            Wait-LabVM -ComputerName $ComputerName
            
            try
            {
                Write-ScreenInfo "Calling activity '$Activity' agian."
                $job = Install-LabSoftwarePackage -ComputerName $ComputerName -LocalPath C:\Install\ExchangeInstall\setup.exe -CommandLine $CommandLine `
                -ExpectedReturnCodes 1 -AsJob -NoDisplay -PassThru -ErrorAction Stop -ErrorVariable exchangeError
                $result = Wait-LWLabJob -Job $job -NoDisplay -NoNewLine -ProgressIndicator 15 -PassThru -ErrorVariable jobError
                if ($jobError)
                {
                    Write-Error -ErrorRecord $jobError -ErrorAction Stop
                }
                if ($result -clike '*FAILED*')
                {
                    Write-Error -Message 'Exchange Installation failed' -ErrorAction Stop
                }
            }
            catch
            {
                Write-ScreenInfo "Activity '$Activity' did not succeed, but did not ask for a reboot, retrying the last time" -Type Warning -NoNewLine
                if ($_ -notmatch '(.+reboot.+pending.+)|(.+pending.+reboot.+)')
                {
                    $job = Install-LabSoftwarePackage -ComputerName $ComputerName -LocalPath C:\Install\ExchangeInstall\setup.exe -CommandLine $CommandLine `
                    -ExpectedReturnCodes 1 -AsJob -NoDisplay -PassThru -ErrorAction Stop -ErrorVariable exchangeError
                    $result = Wait-LWLabJob -Job $job -NoDisplay -NoNewLine -ProgressIndicator 15 -PassThru -ErrorVariable jobError
                    if ($jobError)
                    {
                        Write-Error -ErrorRecord $jobError -ErrorAction Stop
                    }
                    if ($result -clike '*FAILED*')
                    {
                        Write-Error -Message 'Exchange Installation failed' -ErrorAction Stop
                    }
                }
            }
        }
        else
        {
            $resultVariable = New-Variable -Name ("AL_$([guid]::NewGuid().Guid)") -Scope Global -PassThru
            $resultVariable.Value = $exchangeError
            Write-Error "Exchange task '$Activity' failed on '$ComputerName'. See content of $($resultVariable.Name) for details."
        }
    }

    Write-ProgressIndicatorEnd

    Write-ScreenInfo -Message "Finished activity '$Activity'" -TaskEnd
    
    $result
    
    Write-LogFunctionExit
}

function Start-ExchangeInstallation
{
    param (
        [switch]$All,
        
        [switch]$AddAdRightsInRootDomain,
        [switch]$PrepareSchema,
        [switch]$PrepareAD,
        [switch]$PrepareAllDomains,
        [switch]$InstallExchange,
        
        [switch]$CreateCheckPoints
    )
    if ($vm.DomainName -ne $schemaPrepVm.DomainName)
    {
        $prepMachine = $schemaPrepVm
    }
    else
    {
        $prepMachine = $vm
    }

    #prepare Excahnge AD Schema
    if ($PrepareSchema -or $All)
    {
        $commandLine = '/PrepareSchema /IAcceptExchangeServerLicenseTerms'
        $result = Start-ExchangeInstallSequence -Activity 'Exchange PrepareSchema' -ComputerName $prepMachine -CommandLine $commandLine -ErrorAction Stop
        Set-Variable -Name "AL_Result_PrepareSchema_$prepMachine" -Scope Global -Value $result -Force
    }

    #prepare AD
    if ($PrepareAD -or $All)
    {
        $commandLine = '/PrepareAD /OrganizationName:"{0}" /IAcceptExchangeServerLicenseTerms' -f $OrganizationName
        $result = Start-ExchangeInstallSequence -Activity 'Exchange PrepareAD' -ComputerName $prepMachine -CommandLine $commandLine -ErrorAction Stop
        Set-Variable -Name "AL_Result_PrepareAD_$prepMachine" -Scope Global -Value $result -Force
    }
   
    #prepare all domains
    if ($PrepareAllDomains -or $All)
    {
        $commandLine = '/PrepareAllDomains /IAcceptExchangeServerLicenseTerms'
        $result = Start-ExchangeInstallSequence -Activity 'Exchange PrepareAllDomains' -ComputerName $prepMachine -CommandLine $commandLine -ErrorAction Stop
        Set-Variable -Name "AL_Result_AL_Result_PrepareAllDomains_$prepMachine" -Scope Global -Value $result -Force
    }

    if ($PrepareSchema -or $PrepareAD -or $PrepareAllDomains -or $All)
    {
        Write-ScreenInfo -Message 'Triggering AD replication after preparing AD forest'
        Get-LabVM -Role RootDC | ForEach-Object {
            Sync-LabActiveDirectory -ComputerName $_
        }
    
        Write-ScreenInfo -Message 'Restarting machines' -NoNewLine
        Restart-LabVM -ComputerName $schemaPrepVm -Wait -ProgressIndicator 10 -NoNewLine
        Restart-LabVM -ComputerName $vm -Wait -ProgressIndicator 10 -NoNewLine
        Write-ProgressIndicatorEnd
    }

    if ($InstallExchange -or $All)
    {
        Write-ScreenInfo -Message "Installing Exchange Server 2013 on machine '$vm'" -TaskStart
        
        #Actual Exchange Installaton
        $commandLine = '/Mode:Install /Roles:ca,mb,mt /InstallWindowsComponents /OrganizationName:"{0}" /IAcceptExchangeServerLicenseTerms' -f $OrganizationName
        $result = Start-ExchangeInstallSequence -Activity 'Exchange Components' -ComputerName $vm -CommandLine $commandLine -ErrorAction Stop
        Set-Variable -Name "AL_Result_ExchangeInstall_$vm" -Value $result -Scope Global 
        
        Write-ScreenInfo -Message "Finished installing Exchange Server 2013 on machine '$vm'" -TaskEnd
    
        Write-ScreenInfo -Message "Restarting machines '$vm'" -NoNewLine
        Restart-LabVM -ComputerName $vm -Wait -ProgressIndicator 15
    }
}

$ucmaDownloadLink = 'http://download.microsoft.com/download/2/C/4/2C47A5C1-A1F3-4843-B9FE-84C0032C61EC/UcmaRuntimeSetup.exe'
$exchangeDownloadLink = 'https://download.microsoft.com/download/3/9/B/39B25E37-2265-4FBC-AF87-7CA6CA089615/Exchange2013-x64-cu20.exe'
$dotnetDownloadLink = Get-LabConfigurationItem -Name dotnet462DownloadLink

#----------------------------------------------------------------------------------------------------------------------------------------------------

$lab = Import-Lab -Name $data.Name -NoValidation -NoDisplay -PassThru
$vm = Get-LabVM -ComputerName $ComputerName
$schemaPrepVm = if ($lab.IsRootDomain($vm.DomainName))
{
    $vm
}
else
{
    $rootDc = Get-LabVM -Role RootDC | Where-Object { $_.DomainName -eq $vm.DomainName }
    if ($rootDc.SkipDeployment)
    {
        Write-Error "VM '$vm' is not in the root domain and the root domain controller '$rootDc' is not available on this host."
        return
    }
    $rootDc
}

#if the schemaPrepVm is the same as the exchange server, Select-Object will filter it out
$vms = (@($vm) + $schemaPrepVm) | Select-Object -Unique

Write-ScreenInfo "Starting machines '$($vms -join ', ')'" -NoNewLine
Start-LabVM -ComputerName $vms -Wait

if (-not $OrganizationName)
{
    $OrganizationName = $lab.Name + 'ExOrg'
}

$psVersion = Invoke-LabCommand -ActivityName 'Get PowerShell Version' -ComputerName $vm -ScriptBlock {
    $PSVersionTable
} -NoDisplay -PassThru
if ($psVersion.PSVersion.Major -gt 4)
{
    Write-Error "Exchange 2013 does not support PowerShell 5+. The installation on '$vm' cannot succeed."
    return
}

Write-ScreenInfo "Intalling Exchange 2013 '$ComputerName'..." -TaskStart

Copy-ExchangeSources

Install-ExchangeWindowsFeature
Install-ExchangeRequirements
Restart-LabVM -ComputerName $vm -Wait

$param = @{}
if ($PrepareSchema -eq 'True') { $param.Add('PrepareSchema', $true) }
if ($PrepareAD -eq 'True') { $param.Add('PrepareAD', $true) }
if ($PrepareAllDomains -eq 'True') { $param.Add('PrepareAllDomains', $true) }
if ($InstallExchange -eq 'True') { $param.Add('InstallExchange', $true) }
if ($AddAdRightsInRootDomain -eq 'True') { $param.Add('AddAdRightsInRootDomain', $true) }
if (-not $PrepareSchema -and -not $PrepareAD -and -not $PrepareAllDomains -and -not $InstallExchange -and -not $AddAdRightsInRootDomain)
{
    $param.Add('All', $True)
}
Start-ExchangeInstallation @param

Write-ScreenInfo "Finished installing Exchange 2013 on '$ComputerName'" -TaskEnd
