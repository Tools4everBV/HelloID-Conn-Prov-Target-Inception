#################################################
# HelloID-Conn-Prov-Target-Inception-Update
# PowerShell V2
# Version: 2.0.0
#################################################

# Set to false at start, because only when no error occurs it is set to true
$outputContext.Success = $false

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($actionContext.Configuration.isDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Script Configuration
$departmentLookupProperty = { $_.Department.ExternalId }
$titleLookupProperty = { $_.Title.ExternalId }

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

function Get-InceptionPosition {
    [CmdletBinding()]
    Param(
        $pageSize = 200,

        $headers
    )
    try {
        $pageNumber = 1
        $positions = [System.Collections.Generic.list[object]]::new()
        do {
            $splatUserParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/positions?pagesize=$pageSize&page=$pageNumber"
                Method  = 'GET'
                Headers = $headers
            }
            Write-Verbose "$($splatUserParams.Uri)"
            $positionsResponse = Invoke-RestMethod @splatUserParams -Verbose:$false

            if ($null -ne $positionsResponse.items) {
                $positions.AddRange($positionsResponse.items)
            }
            $pageNumber++

        }until ( $positions.count -eq $positionsResponse.total )
        Write-Output $positions

    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-InceptionOrgunit {
    [CmdletBinding()]
    Param(
        $pageSize = 200,
        $headers
    )
    try {
        $pageNumber = 1
        $orgunits = [System.Collections.Generic.list[object]]::new()
        do {
            $splatUserParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/orgunits?pagesize=$pageSize&page=$pageNumber"
                Method  = 'GET'
                Headers = $headers
            }
            Write-Verbose "$($splatUserParams.Uri)"
            $orgunitsResponse = Invoke-RestMethod @splatUserParams -Verbose:$false

            if ($null -ne $orgunitsResponse.items) {
                $orgunits.AddRange($orgunitsResponse.items)
            }
            $pageNumber++

        }until ( $orgunits.count -eq $orgunitsResponse.total )
        Write-Output $orgunits

    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-InceptionIdsFromHelloIdContract {
    [CmdletBinding()]
    param(
        [System.Object[]]
        [Parameter()]
        $DesiredContracts,

        [Parameter(Mandatory)]
        $LookupFieldOrgunitId,

        [Parameter(Mandatory)]
        $LookupFieldPositionId,

        [System.Collections.Hashtable]
        [Parameter(Mandatory)]
        $MappingOrgUnits,

        [System.Collections.Hashtable]
        [Parameter(Mandatory)]
        $MappingPositions
    )
    try {
        if ($null -eq $desiredContracts) {
            throw 'No contracts in condition'
        }

        Write-Verbose 'Calculate and validate the desired Positions and organization Units'
        if ((($desiredContracts | Select-Object $LookupFieldOrgunitId).$LookupFieldOrgunitId | Measure-Object).count -ne $desiredContracts.count) {
            throw  "Not all desired contracts hold a value with Property [$LookupFieldOrgunitId]. Verify your source mapping."
        }

        if ((($desiredContracts | Select-Object $LookupFieldPositionId).$LookupFieldPositionId | Measure-Object).count -ne $desiredContracts.count) {
            throw  "Not all desired contracts hold a value with Property [$LookupFieldPositionId]. Verify your source mapping."
        }

        $desiredPositionList = [System.Collections.Generic.list[object]]::new()
        $idOrgUnitNotFound = [System.Collections.Generic.list[string]]::new()
        $idPositionNotFound = [System.Collections.Generic.list[string]]::new()
        foreach ($contract in $DesiredContracts) {
            $contractOrgUnitsValue = "$(($contract | Select-Object $LookupFieldOrgunitId )."$($LookupFieldOrgunitId)")"
            $orgunitid = ($MappingOrgUnits["$($contractOrgUnitsValue)"]).id

            if ( [string]::IsNullOrEmpty($orgunitid)) {
                $idOrgUnitNotFound.Add($contractOrgUnitsValue)
            }
            $contractPositionValue = "$(($contract | Select-Object $LookupFieldPositionId)."$($LookupFieldPositionId)")"
            $positionid = ($MappingPositions["$($contractPositionValue)"]).id
            if ( [string]::IsNullOrEmpty($positionId)) {
                $idPositionNotFound.Add($contractPositionValue)
            }

            if ($null -eq ($desiredPositionList | Where-Object { $_.positionid -eq $positionId -and $_.orgunitid -eq $orgunitid })) {
                $objectToAdd = [pscustomobject]@{
                    orgunitid    = $orgunitid
                    orgunitName  = $contractOrgUnitsValue
                    positionid   = $positionId
                    positionName = $contractPositionValue
                }
                $desiredPositionList.Add(($objectToAdd))
            }
        }

        if ( $idOrgUnitNotFound.count -gt 0 -or $idPositionNotFound.count -gt 0) {
            $errorMessage = 'Missing Inception object.'
            if ($idOrgUnitNotFound.count -gt 0 ) {
                $errorMessage += " Orgunit not found [$LookupFieldOrgunitId [$($idOrgUnitNotFound -join ', ')]]"
            }
            if (($idPositionNotFound.count -gt 0) ) {
                $errorMessage += " Position not found [$LookupFieldPositionId [$($idPositionNotFound -join ', ')]]"
            }
            throw $errorMessage
        }

        if ($desiredPositionList.count -eq 0) {
            throw 'No Position Found'
        }
        Write-Output $desiredPositionList
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
    $headers = @{
        Accept        = 'application/json'
        Authorization = "Bearer $(Get-InceptionToken)"
    }

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

    # Remove supervisorid field when manager is unknown
    if ($actionContext.Data.PSObject.Properties.Name -Contains 'supervisorid') {
        if ($null -ne $actionContext.References.ManagerAccount.AccountReference) {
            $actionContext.Data.supervisorid = $actionContext.References.ManagerAccount.AccountReference
        }
        else {
            $actionContext.Data.PSObject.Properties.Remove('supervisorid')
        }
    }

    $actionContext.Data.id = $actionContext.References.Account.AccountReference

    $propertiesToCompare = $actionContext.Data.PSObject.Properties.Name

    # Always compare the account against the current account in target system

    if ($null -ne $correlatedAccount) {
        $splatCompareProperties = @{
            ReferenceObject  = $correlatedAccount.PSObject.Properties | Where-Object { $_.Name -in $propertiesToCompare }
            DifferenceObject = $actionContext.Data.PSObject.Properties | Where-Object { $_.Name -in $propertiesToCompare }
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
        
        # Retrieve Metadata
        [array]$desiredContracts = $personContext.Person.Contracts | Where-Object { $_.Context.InConditions -eq $true }
    
        if ($actionContext.DryRun -eq $true) {
            [array]$desiredContracts = $personContext.Person.Contracts            
        }

        Write-Verbose 'Gathering Inception Positions and organization Units to map the against the HelloId person'
        $positions = Get-InceptionPosition -Headers $headers
        $orgUnits = Get-InceptionOrgunit -Headers $headers

        $splatGetInceptionIds = @{
            DesiredContracts      = $desiredContracts
            LookupFieldPositionId = $titleLookupProperty
            LookupFieldOrgunitId  = $departmentLookupProperty
            MappingPositions      = ($positions | Group-Object Code -AsHashTable -AsString)
            MappingOrgUnits       = ($orgUnits | Group-Object Code -AsHashTable -AsString)
        }
    
        $desiredPositionList = Get-InceptionIdsFromHelloIdContract @splatGetInceptionIds

        $splatPositionsPerOrgUnitsList = @{
            DesiredPositions            = $desiredPositionList
            CurrentPositionsInInception = $actionContext.Data.positionsPerOrgUnits
        }

        # Update function also writes auditlogs and dryrun logging
        $positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$actionContext.DryRun))
    
        if ($null -ne (Compare-Object $positionsPerOrgUnits $correlatedAccount.positionsPerOrgUnits -Property positionid, orgunitid)) {

            Write-Verbose 'Position update required'
            $positionsAction = 'Update'
        }
        else {
            $positionsAction = 'NoChanges'
        }

        if (($propertiesChanged -or $positionsAction -eq 'Update') -and ($null -ne $correlatedAccount)) {
            $action = 'UpdateAccount'
            $dryRunMessage = "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"
        }
        elseif (-not($propertiesChanged) -and ($null -ne $correlatedAccount)) {
            $action = 'NoChanges'
            $dryRunMessage = 'No changes will be made to the account during enforcement'
        }
    }
    else {
        $action = 'NotFound'
        $dryRunMessage = "Inception account for: [$($personContext.Person.DisplayName)] not found. Possibly deleted."
    }


    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Verbose "[DryRun] $dryRunMessage" 
    }

    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'UpdateAccount' {
                Write-Verbose "Updating Inception account with accountReference: [$($actionContext.References.Account.AccountReference)]"

                $body = @{}

                if ($propertiesChanged) {
                    foreach ($prop in $propertiesChanged) {
                        $body["$($prop.name)"] = $prop.value
                    }
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "'Account property(s) required to update: [$($propertiesChanged.name -join ',')]'"
                            IsError = $false
                        })
                }
                               
                if ($positionsAction -eq 'Update') {
                    $body['positionsPerOrgUnits'] = $positionsPerOrgUnits
                }
                
                $splatEmployeeUpdateParams = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/$($actionContext.References.Account.AccountReference)"
                    Method      = 'PUT'
                    Headers     = $headers
                    Body        = ($body | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }
                
                $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false

                $outputContext.AccountReference.Positions = $positionsPerOrgUnits
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Verbose "No changes to Inception account with accountReference: [$($actionContext.References.Account)]"

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Inception account for: [$($personContext.Person.DisplayName)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
                        IsError = $true
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
        $auditMessage = "Could not update Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update Inception account. Error: $($ex.Exception.Message)"
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
