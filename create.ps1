###########################################
# HelloID-Conn-Prov-Target-Inception-Create
#
# Version: 1.0.1
###########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Script Configuration
#$employeeOverviewId = '0000000' !!NOT USED WITH NEW ENDPOINT USAGE
$departmentLookupProperty = { $_.Department.ExternalId }
$titleLookupProperty = { $_.Title.ExternalId }

#Generate surname conform nameconvention
function Get-LastName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object]
        $person
    )

    if ([string]::IsNullOrEmpty($person.Name.FamilyNamePrefix)) {
        $prefix = ""
    }
    else {
        $prefix = $person.Name.FamilyNamePrefix + " "
    }

    if ([string]::IsNullOrEmpty($person.Name.FamilyNamePartnerPrefix)) {
        $partnerPrefix = ""
    }
    else {
        $partnerPrefix = $person.Name.FamilyNamePartnerPrefix + " "
    }

    $Surname = switch ($person.Name.Convention) {
        "B" { $person.Name.FamilyName }
        "BP" { $person.Name.FamilyName + " - " + $partnerprefix + $person.Name.FamilyNamePartner }
        "P" { $person.Name.FamilyNamePartner }
        "PB" { $person.Name.FamilyNamePartner + " - " + $prefix + $person.Name.FamilyName }
        default { $prefix + $person.Name.FamilyName }
    }

    $Prefix = switch ($p.Name.Convention) {
        "B" { $prefix }
        "BP" { $prefix }
        "P" { $partnerPrefix }
        "PB" { $partnerPrefix }
        default { $prefix }
    }
    $output = [PSCustomObject]@{
        surname  = $Surname
        prefixes = $Prefix.Trim()
    }
    Write-Output $output
}

# Employee Account mapping
$account = [PSCustomObject]@{
    staffnumber          = $p.ExternalId
    firstname            = $p.Name.NickName
    lastname             = (Get-LastName -Person $p).surname
    middlename           = (Get-LastName -Person $p).prefixes
    initials             = $p.Name.Initials
    email                = $p.Contact.Business.Email
    phone                = $p.Contact.Business.Phone.Fixed
    dateofbirth          = if ($null -ne $p.Details.BirthDate ) { '{0:yyyy-MM-dd}' -f ([datetime]$p.Details.BirthDate) };
    startdate            = if ($null -ne $p.PrimaryContract.StartDate ) { '{0:yyyy-MM-dd}' -f ([datetime]$p.PrimaryContract.StartDate) };
    enddate              = $null # ((Get-Date).AddDays(-1))
    positionsPerOrgUnits = @()
}

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Set to true if accounts in the target system must be updated
$updatePerson = $false

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

    }
    catch {
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
#endregion

# Begin
try {
    # Verify if a user must be either [created and correlated], [updated and correlated] or just [correlated]
    $headers = @{
        Accept        = 'application/json'
        Authorization = "Bearer $(Get-InceptionToken)"
    }

    if ([string]::IsNullOrEmpty($($account.staffnumber))) {
        throw 'No staffnumber provided'
    }

    Write-Verbose  'Determine if account already exists'
    $splatUserParams = @{
        Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/staffnumber/$($account.staffnumber)"
        Method  = 'GET'
        Headers = $headers
    }
    
    $resultGetEmployee = Invoke-RestMethod @splatUserParams -Verbose:$false
    
    # To prevent correlation of multiple accounts the following fix is added. This is becauce the staffnumber is not a unique proeprty in Inception
    # So you could end up with multiple accounts with the same staffnumber which is our correlation property.
    if ($($resultGetEmployee.total) -gt 1) {
        $activeEmployeeAccountFound = $resultGetEmployee.items | Where-Object { $_.state -eq '20' }
        if (($activeEmployeeAccountFound | ConvertTo-Json ).count -gt 1) {
            throw "More than one active account was found for [$($account.staffnumber)]. Please remove the obsolete account(s) or make sure that the obsolete account(s) are disabled and enable only the correct account."
        }
    }

    $aRef = ($resultGetEmployee.items | Select-Object -First 1).id

    if (-not [string]::IsNullOrEmpty($aRef)) {
        try {
            $splatUserParams = @{
                Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$aRef"
                Method  = 'GET'
                Headers = $headers
            }
            $employee = Invoke-RestMethod @splatUserParams -Verbose:$false # Exception if not found
        }
        catch {
            if ( $_.Exception.message -notmatch '404' ) {
                throw $_
            }
        }
    }

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


    if ($null -eq $employee) {
        $action = 'Create-Correlate'
        $splatPositionsPerOrgUnitsList = @{
            AccountReference            = ([System.Collections.Generic.list[object]]::new())
            DesiredPositions            = $desiredPositionList
            CurrentPositionsInInception = $account.positionsPerOrgUnits
        }
    }
    elseif ($updatePerson -eq $true) {
        $action = 'Update-Correlate'
        $splatPositionsPerOrgUnitsList = @{
            AccountReference            = ([System.Collections.Generic.list[object]]::new())
            DesiredPositions            = $desiredPositionList
            CurrentPositionsInInception = $employee.positionsPerOrgUnits
        }
    }
    else {
        $splatPositionsPerOrgUnitsList = @{
            AccountReference            = ([System.Collections.Generic.list[object]]::new())
            DesiredPositions            = $desiredPositionList
            CurrentPositionsInInception = $employee.positionsPerOrgUnits
        }
        $action = 'Correlate'
    }
    # Update function also writes auditlogs and dryrun logging
    $account.positionsPerOrgUnits = ([array](Update-PositionsPerOrgUnitsList @splatPositionsPerOrgUnitsList -DryRunFlag:$dryRun))

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action Inception Employee account for: [$($p.DisplayName)], will be executed during enforcement"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                Write-Verbose 'Creating and correlating Inception Employee account'
                $splatEmployeeCreateParams = @{
                    Uri         = "$($config.BaseUrl)/api/v2/hrm/employees"
                    Method      = 'POST'
                    Headers     = $headers
                    Body        = ($account | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }
                $responseEmployee = Invoke-RestMethod @splatEmployeeCreateParams -Verbose:$false
                $aRef = $responseEmployee.id

                # Disable just created Employee. Position and properties are maintained
                $splatEmployeeDisableParams = @{
                    Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$aRef"
                    Method  = 'DELETE'
                    Headers = $headers
                }
                $null = Invoke-RestMethod @splatEmployeeDisableParams -Verbose:$false #204
                break
            }

            'Update-Correlate' {
                Write-Verbose 'Updating and correlating Inception Employee account'
                if ($null -eq (Compare-Object $account.positionsPerOrgUnits   $employee.positionsPerOrgUnits)) {
                    Write-Verbose 'No position update required'
                }
                $account = $account | Select-Object * -ExcludeProperty state, enddate
                $splatEmployeeUpdateParams = @{
                    Uri         = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef)"
                    Method      = 'PUT'
                    Headers     = $headers
                    Body        = ($account | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }
                $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false
                break
            }

            'Correlate' {
                if ($null -eq (Compare-Object $account.positionsPerOrgUnits   $employee.positionsPerOrgUnits)) {
                    Write-Verbose 'Correlating Inception Employee account'
                    Write-Verbose  'No position update required'
                }
                else {
                    Write-Verbose 'Updating Position and correlating Inception Employee account'
                    $splatEmployeeUpdateParams = @{
                        Uri         = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef)"
                        Method      = 'PUT'
                        Headers     = $headers
                        Body        = (($account | Select-Object positionsPerOrgUnits ) | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }
                    $null = Invoke-RestMethod @splatEmployeeUpdateParams -Verbose:$false
                }
                break
            }
        }
    }
    $success = $true
    $auditLogs.Add([PSCustomObject]@{
            Message = "$action Employee account was successful. AccountReference is: [$aRef]"
            IsError = $false
        })

}
catch {
    $success = $false
    $ex = $PSItem
    Write-Verbose -Verbose $ex.Exception.Message
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not $action Inception Employee account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not $action Inception Employee account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    if ($dryRun -eq $true) {
        Write-Warning $auditMessage
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $accountReferenceObject = @{
        AccountReference = $aRef
        Positions        = $desiredPositionList | Select-Object * -ExcludeProperty SideIndicator
    }

    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReferenceObject
        Auditlogs        = $auditLogs
        Account          = $account
        ExportData       = [PSCustomObject]@{
            Id          = $aRef
            staffNumber = $($account.staffnumber)
        }
    }

    Write-Output $result | ConvertTo-Json -Depth 10
}
