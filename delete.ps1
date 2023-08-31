###########################################
# HelloID-Conn-Prov-Target-Inception-Delete
#
# Version: 1.0.1
###########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Get-InceptionToken {
    [CmdletBinding()]
    param()
    try {
        $splatTokenParams = @{
            Uri     = "$($config.BaseUrl)/api/v2/authentication/login"
            Method  = 'POST'
            Body    = @{
                username = $config.UserName
                password = $config.Password
            } | ConvertTo-Json
            Headers = @{
                Accept         = 'application/json'
                'Content-Type' = 'application/json'
            }
        }
        $tokenResponse = Invoke-RestMethod @splatTokenParams -Verbose:$false

        Write-Output $tokenResponse.Token
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Update-PositionsPerOrgUnitsList {
    [CmdletBinding()]
    param(
        [System.Array]
        [AllowNull()]
        $AccountReference,

        [System.Array]
        [AllowNull()]
        $DesiredPositions,

        [System.Array]
        $CurrentPositionsInInception,

        $DryRunFlag
    )
    try {
        if ($null -eq $AccountReference) {
            $accountReference = [System.Collections.Generic.List[object]]::new()
        }
        if ($null -eq $DesiredPositions) {
            $DesiredPositions = [System.Collections.Generic.List[object]]::new()
        }
        $compareResults = Compare-Object $AccountReference $DesiredPositions -Property positionid, orgunitid -PassThru
        foreach ($compareResultItem in $compareResults) {
            if ($compareResultItem.SideIndicator -eq '=>' ) {
                $currentObject = ($compareResultItem | Select-Object * -ExcludeProperty SideIndicator)
                Write-Verbose "Process Position [$($currentObject)] of Employee"

                $itemToAdd = $CurrentPositionsInInception | Where-Object { $_.positionid -eq $compareResultItem.positionid -and $_.orgunitid -eq $compareResultItem.orgunitid }
                if (-not ($CurrentPositionsInInception.Contains($itemToAdd))) {
                    [array]$CurrentPositionsInInception += ($currentObject)
                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Added Position [OrgUnit: $($currentObject.OrgunitName) Position: $($currentObject.PositionName)]"
                            IsError = $false
                        })
                    if ($DryRunFlag -eq $true) {
                        Write-Warning "[DryRun] Added Position [OrgUnit: $($currentObject.orgunitid) Position: $($currentObject.positionid)]"
                    }
                }
                else {
                    if ($DryRunFlag -eq $true) {
                        Write-Warning "[DryRun] Calculated Position already exists [OrgUnit: $($currentObject.orgunitid) Position: $($currentObject.positionid)]"
                    }

                }

            }
            elseif ($compareResultItem.SideIndicator -eq '<=' ) {
                $itemToRemove = $CurrentPositionsInInception | Where-Object { $_.positionid -eq $compareResultItem.positionid -and $_.orgunitid -eq $compareResultItem.orgunitid }
                if (-not [string]::IsNullOrEmpty($itemToRemove)) {
                    Write-Verbose "Removing Position [$($itemToRemove)] from Employee"
                    $CurrentPositionsInInception = $CurrentPositionsInInception.Where({ $_ -ne $itemToRemove })
                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Removed Position [OrgUnit: $($compareResultItem.OrgunitName) Position: $($compareResultItem.PositionName)]"
                            IsError = $false
                        })
                }
                else {
                    if ($DryRunFlag -eq $true) {
                        Write-Warning "[DryRun] Previously assigned Position [$($compareResultItem | Select-Object * -ExcludeProperty SideIndicator)] is already removed from Employee"
                    }
                }
            }
        }
        Write-Output $CurrentPositionsInInception | Select-Object positionid, orgunitid
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Resolve-InceptionError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        $webresponse = $false
        if ($ErrorObject.ErrorDetails) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails
            $httpErrorObj.FriendlyMessage = $ErrorObject.ErrorDetails
            $webresponse = $true
        }
        elseif ((-not($null -eq $ErrorObject.Exception.Response) -and $ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException')) {
            $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
            if (-not([string]::IsNullOrWhiteSpace($streamReaderResponse))) {
                $httpErrorObj.ErrorDetails = $streamReaderResponse
                $httpErrorObj.FriendlyMessage = $streamReaderResponse
                $webresponse = $true
            }
        }
        if ($webresponse) {
            try {
                $convertedErrorObject = ($httpErrorObj.FriendlyMessage | ConvertFrom-Json)
                if (-not [string]::IsNullOrEmpty($convertedErrorObject.languageString)) {
                    $httpErrorObj.FriendlyMessage = $convertedErrorObject.LanguageString
                }
                elseif (-not [string]::IsNullOrEmpty($convertedErrorObject.description)) {
                    $httpErrorObj.FriendlyMessage = $convertedErrorObject.Description
                }
            }
            catch {
                Write-Warning "Unexpected webservice response, Error during Json conversion: $($_.Exception.Message)"
            }
        }
        Write-Output $httpErrorObj
    }
}
#endregion

# Begin
try {
    Write-Verbose "Verifying if an Inception account for [$($p.DisplayName)] exists"
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $(Get-InceptionToken)")
    $headers.Add('Accept', 'application/json')
    $headers.Add('Content-Type', 'application/json')

    $employeeFound = $false
    if ([string]::IsNullOrEmpty($($aRef.AccountReference))) {
        throw 'No Account Reference found'
    }
    try {
        $splatUserParams = @{
            Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
            Method  = 'GET'
            Headers = $Headers
        }
        $employee = Invoke-RestMethod @splatUserParams -Verbose:$false
        $employeeFound = $true
    }
    catch {
        if ( $_.Exception.message -notmatch '404' ) {
            throw $_
        }
    }

    if ($employeeFound) {
        $action = 'Found'
        $dryRunMessage = "Delete Inception account for: [$($p.DisplayName)] will be executed during enforcement"
    }
    elseif (-not $employeeFound) {
        $action = 'NotFound'
        $dryRunMessage = "Inception account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
    }
    Write-Verbose $dryRunMessage

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        Write-Verbose "Deleting Inception account with accountReference: [$($aRef.AccountReference)]"
        switch ($action) {
            'Found' {
                if ($null -ne $aRef.Positions) {
                    $splatPositionsPerOrgUnitsList = @{
                        AccountReference            = $aRef.Positions
                        DesiredPositions            = $null
                        CurrentPositionsInInception = $employee.positionsPerOrgUnits
                    }
                    $positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$dryRun))

                    if ( $null -eq $positionsPerOrgUnits) {
                        $positionsPerOrgUnits = @(  @{
                                positionid = $config.positionId
                                orgunitid  = $config.orgunitId
                            })
                    }

                    $body = @{
                        positionsPerOrgUnits = $positionsPerOrgUnits
                    }
                    $splatEmployeeUpdateParams = @{
                        Uri         = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
                        Method      = 'PUT'
                        Headers     = $headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }
                    $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false
                }

                if ($employee.state -eq 20) {
                    Write-Verbose "Disable Inception Employee account with accountReference: [$($aRef.AccountReference)]"
                    $splatEmployeeDisableParams = @{
                        Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
                        Method  = 'DELETE'
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatEmployeeDisableParams -Verbose:$false

                    $auditLogs.Add([PSCustomObject]@{
                            Message = 'Disable Inception Employee and Delete user account was successful'
                            IsError = $false
                        })
                }
                else {
                    $auditLogs.Add([PSCustomObject]@{
                            Message = 'Disable Inception Employee and Delete user account already processed'
                            IsError = $false
                        })
                }
                break
            }

            'NotFound' {
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Inception account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
                        IsError = $false
                    })
                break
            }
        }

        $success = $true
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not delete Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not delete Inception account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
