#################################################
# HelloID-Conn-Prov-Target-Inception-Create
# PowerShell V2
# Version: 1.0.0
#################################################

# Set to true at start, because only when an error occurs it is set to false
$outputContext.Success = $true

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
#endregion

try {
    # AccountReference must have a value
    $outputContext.AccountReference = 'Currently not available'

    # Remove ID field because only used for export data
    if ($outputContext.Data.PSObject.Properties.Name -Contains 'id') {
        $outputContext.Data.PSObject.Properties.Remove('id')
    }

    # Properties Excluded from response
    $excludedProperties = "dateofbirth,phone,mobile,residence,state,supervisorid,rolesPerOrgUnits,positionsPerOrgGroup,rolesPerOrgGroup"
    $excludedPropertiesArray = $excludedProperties -split ","

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.accountField
        $correlationValue = $actionContext.CorrelationConfiguration.accountFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Verify if a user must be either [created ] or just [correlated]
        $headers = @{
            Accept        = 'application/json'
            Authorization = "Bearer $(Get-InceptionToken)"
        }

        Write-Verbose  'Determine if account already exists'
        $splatUserParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/staffnumber/$($actionContext.Data.staffnumber)"
            Method  = 'GET'
            Headers = $headers
        }        
        $resultGetEmployee = Invoke-RestMethod @splatUserParams -Verbose:$false

        if ($resultGetEmployee.total -gt 1) {        
            $activeEmployeeAccountFound = $resultGetEmployee.items | Where-Object { $_.state -eq 20 }
            if ($activeEmployeeAccountFound.count -gt 1) {
                throw "More than one active account was found for person with staffnumber [$($actionContext.Data.staffnumber)]. Please remove the obsolete account(s) or make sure that the obsolete account(s) are disabled and enable only the correct account."
            }
        }
    } else {
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Action  = "CorrelateAccount"
                Message = "Configuration of correlation is mandatory."
                IsError = $true
            })
        throw "Configuration of correlation is mandatory."
    }

    $correlatedAccount = $resultGetEmployee.items | Select-Object -First 1

    if ($null -eq $correlatedAccount) {
        $action = 'CreateAccount'
    }
    else {
        $action = 'CorrelateAccount'
        $outputContext.AccountReference = $correlatedAccount.id
    }

    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Verbose "[DryRun] Inception $action for: [$($personContext.Person.DisplayName)], will be executed during enforcement" -Verbose
    }

    # Retrieve Metadata
    [array]$desiredContracts = $personContext.Person.Contracts | Where-Object { $_.Context.InConditions -eq $true }
    
    if ($actionContext.DryRun -eq $true) {
        [array]$desiredContracts = $personContext.Person.Contracts
    }

    # Remove supervisorid field because only used for export data
    if ($actionContext.Data.PSObject.Properties.Name -Contains 'supervisorid') {
        if ($null -ne $actionContext.References.ManagerAccount) {
            $actionContext.Data.supervisorid = $actionContext.References.ManagerAccount.AccountReference
        }
        else {
            $actionContext.Data.PSObject.Properties.Remove('supervisorid')
        }
    }    
    
    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'CreateAccount' {                
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
                $desiredPositionList = Get-InceptionIdsFromHelloIdContact @splatGetInceptionIds

                $splatPositionsPerOrgUnitsList = @{
                    DesiredPositions            = $desiredPositionList
                    CurrentPositionsInInception = $actionContext.Data.positionsPerOrgUnits
                }

                # Update function also writes auditlogs and dryrun logging
                $actionContext.Data.positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$actionContext.DryRun))
                
                # Set supervisorid to Inception
                Write-Verbose 'Creating and correlating Inception employee account'
                $splatEmployeeCreateParams = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees"
                    Method      = 'POST'
                    Headers     = $headers
                    Body        = ($actionContext.Data | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }                
                $createdAccount = Invoke-RestMethod @splatEmployeeCreateParams -Verbose:$false
                $createdAccount = $createdAccount | Select-Object -Property * -ExcludeProperty $excludedPropertiesArray
                
                # Disable just created Employee. Position and properties are maintained
                $splatEmployeeDisableParams = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/employees/$($createdAccount.id)"
                    Method  = 'DELETE'
                    Headers = $headers
                }
                $null = Invoke-RestMethod @splatEmployeeDisableParams -Verbose:$false #204

                # Only required when you do need values from the target system, for example Account Reference.
                # Otherwise $outputContext.Data is automatically filled the with account Data
                $outputContext.Data = $createdAccount
                $accountReferenceId = $createdAccount.id
                $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)"
                break
            }

            'CorrelateAccount' {
                Write-Verbose 'Correlating Inception employee account'
                $correlatedAccount = $correlatedAccount | Select-Object -Property * -ExcludeProperty $excludedPropertiesArray
                $outputContext.Data = $correlatedAccount
                $accountReferenceId = $correlatedAccount.id
                $outputContext.AccountCorrelated = $true
                $auditLogMessage = "Correlated account: [$($correlatedAccount.id)] on field: [$($correlationField)] with value: [$($correlationValue)]"
                break
            }
        }

        $accountReferenceObject = @{
            AccountReference = $accountReferenceId
            Positions        = $desiredPositionList | Select-Object * -ExcludeProperty SideIndicator
        }

        $outputContext.AccountReference = $accountReferenceObject
        $outputContext.success = $true
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Action  = $action
                Message = $auditLogMessage
                IsError = $false
            })
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not $action Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not $action Inception account. Error: $($ex.Exception.Message)"
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