###########################################
# HelloID-Conn-Prov-Target-Inception-Update
#
# Version: 1.0.0
###########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Script Configuration
$departmentLookupProperty = { $_.Department.ExternalId }
$titleLookupProperty = { $_.Title.ExternalId }

# Employee Account mapping
$account = [PSCustomObject]@{
    staffnumber          = $p.ExternalId
    firstname            = $p.Name.GivenName
    lastname             = $p.Name.FamilyName
    middlename           = $p.Name.FamilyNamePrefix
    initials             = $p.Name.Initials
    email                = $p.Contact.Business.Email
    phone                = $p.Contact.Business.Phone.Fixed
    dateofbirth          = if ($null -ne $p.Details.BirthDate ) { '{0:yyyy-MM-dd}' -f ([datetime]$p.Details.BirthDate) };
    startdate            = if ($null -ne $p.PrimaryContract.StartDate ) { '{0:yyyy-MM-dd}' -f ([datetime]$p.PrimaryContract.StartDate) };
    enddate              = $null
    positionsPerOrgUnits = @()
}

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
    } catch {
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
                } else {
                    if ($DryRunFlag -eq $true) {
                        Write-Warning "[DryRun] Calculated Position already exists [OrgUnit: $($currentObject.orgunitid) Position: $($currentObject.positionid)]"
                    }

                }

            } elseif ($compareResultItem.SideIndicator -eq '<=' ) {
                $itemToRemove = $CurrentPositionsInInception | Where-Object { $_.positionid -eq $compareResultItem.positionid -and $_.orgunitid -eq $compareResultItem.orgunitid }
                if (-not [string]::IsNullOrEmpty($itemToRemove)) {
                    Write-Verbose "Removing Position [$($itemToRemove)] from Employee"
                    $CurrentPositionsInInception = $CurrentPositionsInInception.Where({ $_ -ne $itemToRemove })
                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Removed Position [OrgUnit: $($compareResultItem.OrgunitName) Position: $($compareResultItem.PositionName)]"
                            IsError = $false
                        })
                } else {
                    if ($DryRunFlag -eq $true) {
                        Write-Warning "[DryRun] Previously assigned Position [$($compareResultItem | Select-Object * -ExcludeProperty SideIndicator)] is already removed from Employee"
                    }
                }
            }
        }
        Write-Output $CurrentPositionsInInception | Select-Object positionid, orgunitid
    } catch {
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
        } elseif ((-not($null -eq $ErrorObject.Exception.Response) -and $ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException')) {
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
                } elseif (-not [string]::IsNullOrEmpty($convertedErrorObject.description)) {
                    $httpErrorObj.FriendlyMessage = $convertedErrorObject.Description
                }
            } catch {
                Write-Warning "Unexpected webservice response, Error during Json conversion: $($_.Exception.Message)"
            }
        }
        Write-Output $httpErrorObj
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
                Uri     = "$($config.BaseUrl)/api/v2/hrm/positions?pagesize=$pageSize&page=$pageNumber"
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

    } catch {
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
                Uri     = "$($config.BaseUrl)/api/v2/hrm/orgunits?pagesize=$pageSize&page=$pageNumber"
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

    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-InceptionIdsFromHelloIdContact {
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
            if ( [string]::IsNullOrEmpty($positionid)) {
                $idPositionNotFound.Add($contractPositionValue)
            }

            if ($null -eq ($desiredPositionList | Where-Object { $_.positionid -eq $positionid -and $_.orgunitid -eq $orgunitid })) {
                $objectToAdd = [pscustomobject]@{
                    orgunitid    = $orgunitid
                    orgunitName  = $contractOrgUnitsValue
                    positionid   = $positionid
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
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

# Begin
try {
    Write-Verbose "Verifying if a Inception account for [$($p.DisplayName)] exists"
    if ([string]::IsNullOrEmpty($($aRef.AccountReference))) {
        throw 'No Account Reference found'
    }
    $headers = @{
        Accept        = 'application/json'
        Authorization = "Bearer $(Get-InceptionToken)"
    }

    try {
        $employeeFound = $false
        $splatUserParams = @{
            Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
            Method  = 'GET'
            Headers = $Headers
        }
        $employee = Invoke-RestMethod @splatUserParams -Verbose:$false
        $employeeFound = $true
    } catch {
        if ( $_.Exception.message -notmatch '404' ) {
            throw $_
        }
    }

    # Verify if the account must be updated
    $excludedProperties = 'enddate', 'positionsPerOrgUnits'
    $splatCompareProperties = @{
        ReferenceObject  = @(($employee | Select-Object * -ExcludeProperty $excludedProperties).PSObject.Properties )
        DifferenceObject = @(($account | Select-Object * -ExcludeProperty $excludedProperties).PSObject.Properties )
    }
    $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })

    # Retrieve Metadata
    [array]$desiredContracts = $p.contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($dryRun -eq $true) {
        [array]$desiredContracts = $p.contracts
    }

    Write-Verbose 'Gathering Inception Positions and organization Units to map the against the HelloId person'
    $positions = Get-InceptionPosition -Headers $headers -pageSize 1000
    $orgUnits = Get-InceptionOrgunit -Headers $headers -pageSize 1000

    $splatGetInceptionIds = @{
        DesiredContracts      = $desiredContracts
        LookupFieldPositionId = $titleLookupProperty
        LookupFieldOrgunitId  = $departmentLookupProperty
        MappingPositions      = ($positions | Group-Object Code -AsHashTable -AsString)
        MappingOrgUnits       = ($orgUnits | Group-Object Code -AsHashTable -AsString)
    }
    $desiredPositionList = Get-InceptionIdsFromHelloIdContact @splatGetInceptionIds

    $splatPositionsPerOrgUnitsList = @{
        AccountReference            = $aRef.Positions
        DesiredPositions            = $desiredPositionList
        CurrentPositionsInInception = $employee.positionsPerOrgUnits
    }

    $positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$dryRun))


    if ($null -ne (Compare-Object $positionsPerOrgUnits $employee.positionsPerOrgUnits)) {
        Write-Verbose 'Position update required'
        $positionsAction = 'Update'
    } else {
        $positionsAction = 'NoChanges'
    }

    if (($propertiesChanged -or $positionsAction -eq 'Update' ) -and ($employeeFound)) {
        $action = 'Update'
        $dryRunMessage = "Account property(s) required to update: [$($propertiesChanged.name -join ',')]"
    } elseif (-not($propertiesChanged) -and ($employeeFound)) {
        $action = 'NoChanges'
        $dryRunMessage = 'No changes will be made to the account during enforcement'
    } elseif (-not $employeeFound) {
        $action = 'NotFound'
        $dryRunMessage = "Inception account for: [$($p.DisplayName)] not found. Possibly deleted"
    }
    Write-Verbose $dryRunMessage

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Update' {
                Write-Verbose "Updating Inception account with accountReference: [$($aRef.AccountReference)]"
                $body = @{}

                if ($propertiesChanged) {
                    foreach ($prop in $propertiesChanged) {
                        $body["$($prop.name)"] = $prop.value
                    }
                }
                if ($positionsAction -eq 'Update') {
                    $body['positionsPerOrgUnits'] = $positionsPerOrgUnits
                }

                $splatEmployeeUpdateParams = @{
                    Uri         = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
                    Method      = 'PUT'
                    Headers     = $headers
                    Body        = ($body | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }
                $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'Update account was successful'
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Verbose "No changes to Inception account with accountReference: [$($aRef.AccountReference)]"

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'No changes made to the account during the enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                $success = $false
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Inception account for: [$($p.DisplayName)] not found. Possibly deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not update Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update Inception account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
} finally {
    $accountReferenceObject = @{
        AccountReference = $aRef.AccountReference
        Positions        = $desiredPositionList | Select-Object * -ExcludeProperty SideIndicator
    }


    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReferenceObject
        Account          = $account
        Auditlogs        = $auditLogs
    }

    Write-Output $result | ConvertTo-Json -Depth 10
}
