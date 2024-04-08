##################################################
# HelloID-Conn-Prov-Target-Inception-Delete
# PowerShell V2
# Version: 2.0.0
##################################################

# Set to false at start, because only when no error occurs it is set to true
$outputContext.Success = $false

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Get-InceptionToken {
    [CmdletBinding()]
    param()
    try {
        $splatTokenParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/authentication/login"
            Method  = 'POST'
            Body    = @{
                username = $actionContext.Configuration.UserName
                password = $actionContext.Configuration.Password
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
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
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
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
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
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            # Make sure to inspect the error result object and add only the error message as a FriendlyMessage.
            if (-not [string]::IsNullOrEmpty($errorDetailsObject.languageString)) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.LanguageString
            }
            elseif (-not [string]::IsNullOrEmpty($errorDetailsObject.description)) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.Description
            }            
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails # Temporarily assignment
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Verbose "Verifying if a Inception account for [$($personContext.Person.DisplayName)] exists"    
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $(Get-InceptionToken)")
    $headers.Add('Accept', 'application/json')
    $headers.Add('Content-Type', 'application/json')

    try {
        $splatUserParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/$($actionContext.References.Account.AccountReference)"
            Method  = 'GET'
            Headers = $Headers
        }
        $correlatedAccount = Invoke-RestMethod @splatUserParams -Verbose:$false
        
    }
    catch {
        if ( $_.Exception.message -notmatch '404' ) {
            throw $_
        }
    }

    if ($null -ne $correlatedAccount) {
        $action = 'DeleteAccount'
        $dryRunMessage = "Delete Inception account: [$($actionContext.References.Account.AccountReference)] for person: [$($personContext.Person.DisplayName)] will be executed during enforcement"
    }
    else {
        $action = 'NotFound'
        $dryRunMessage = "Inception account: [$($actionContext.References.Account.AccountReference)] for person: [$($personContext.Person.DisplayName)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
    }

    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Verbose "[DryRun] $dryRunMessage" 
    }

    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'DeleteAccount' {
                Write-Verbose "Deleting Inception account with accountReference: [$($actionContext.References.Account.AccountReference)]"
                if ($null -ne $($actionContext.References.Account.Positions)) {
                    $splatPositionsPerOrgUnitsList = @{
                        AccountReference            = $($actionContext.References.Account.Positions)
                        DesiredPositions            = $null
                        CurrentPositionsInInception = $correlatedAccount.positionsPerOrgUnits
                    }
                    $positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$($actionContext.DryRun)))

                    if ( $null -eq $positionsPerOrgUnits) {
                        $positionsPerOrgUnits = @(  @{
                                positionid = $actionContext.Configuration.positionId
                                orgunitid  = $actionContext.Configuration.orgunitId
                            })
                    }

                    $body = @{
                        positionsPerOrgUnits = $positionsPerOrgUnits
                    }
                    $splatEmployeeUpdateParams = @{
                        Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/$($actionContext.References.Account.AccountReference)"
                        Method      = 'PUT'
                        Headers     = $headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }
                    $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false
                }

                #Retrieve employee object to check state; Inception sets state when performing a PUT
                $employee = Invoke-RestMethod @splatUserParams -Verbose:$false

                if ($employee.state -eq 20) {                    
                    $splatEmployeeDisableParams = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/$($actionContext.References.Account.AccountReference)"
                        Method  = 'DELETE'
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatEmployeeDisableParams -Verbose:$false
                }

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'Disable Inception Employee and Delete user account was successful'
                        IsError = $false
                    })
                break
            }

            'NotFound' {                
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Inception account: [$($actionContext.References.Account.AccountReference)] for person: [$($personContext.Person.DisplayName)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
                        IsError = $false
                    })
                break
            }
        }
    }
}
catch {    
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not delete Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not delete Inception account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
finally {
    # Check if auditLogs contains errors, if no errors are found, set success to true
    if (-not($outputContext.AuditLogs.IsError -contains $true)) {
        $outputContext.Success = $true
    }
}
