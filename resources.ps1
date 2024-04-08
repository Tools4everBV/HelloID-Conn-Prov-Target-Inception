####################################################
# HelloID-Conn-Prov-Target-Inception-Resources
# PowerShell V2
# Version: 2.0.0
####################################################
# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($actionContext.Configuration.isDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Mapping Custom Fields in case of not using Github example customfieldnames
$DepartmentCode = 'DepartmentCode'
$DepartmentDescription = 'DepartmentDescription'
$TitleCode = 'TitleCode'
$TitleDescription = 'TitleDescription'
$resourceContext.sourceData = ($resourceContext.sourceData | Where-Object { -not [string]::IsNullOrEmpty($_.$DepartmentCode) })

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

function Get-InceptionPositions {
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

function Get-InceptionOrgunits {
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
#endregion


Write-Verbose "Creating [$($resourceContext.SourceData.Count)] resources"
$outputContext.Success = $true
try {
    <# Resource creation preview uses a timeout of 30 seconds while actual run has timeout of 10 minutes #>
    $headers = @{
        Accept        = 'application/json'
        Authorization = "Bearer $(Get-InceptionToken)"
    }

    $OrgUnits = Get-InceptionOrgunits -Headers $headers
    $positions = Get-InceptionPositions -Headers $headers


    foreach ($resource in $resourceContext.SourceData) {            
        if (-not ($actionContext.DryRun -eq $True)) {
            $targetOrgUnit = ($OrgUnits | Where-Object -Property code -eq $resource.$DepartmentCode)
            if ($targetOrgUnit.count -eq 0) {
                $body = @{
                    code        = $orgUnit.$DepartmentCode
                    name        = $orgUnit.$DepartmentDescription
                    description = $orgUnit.$DepartmentDescription
                    state       = 20
                }
                $splatCreateOrgunitParams = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/orgunits"
                    Method      = 'POST'
                    Headers     = $Headers
                    Body        = ($body | ConvertTo-Json)
                    ContentType = 'application/json; charset=utf-8'
                }
                $orgunitsResponse = Invoke-RestMethod @splatCreateOrgunitParams -Verbose:$false # Exception not found
                $OrgUnits += $orgunitsResponse

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Created orgUnit: [$($orgUnit.$DepartmentCode)]"
                        IsError = $false
                    })
            }
            else {
                $orgUnit = $OrgUnits | Where-Object -Property code -eq $orgunit.$DepartmentCode
                if ($orgUnit.state -ne 20) {
                    $body = @{
                        state = 20
                    }
                    $splatCreateOrgunitParams = @{
                        Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/orgunits/$($orgUnit.id)"
                        Method      = 'PUT'
                        Headers     = $Headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'

                    }
                    $orgunitsResponse = Invoke-RestMethod @splatCreateOrgunitParams -Verbose:$false # Exception not found
                }
            }

            $groupedOrgUnits = $OrgUnits | Group-Object -Property code -AsString -AsHashTable
            $groupedPositions = $resourceContext.SourceData | Group-Object -Property $TitleCode -AsString -AsHashTable

            foreach ($key in $groupedPositions.Keys) {
                $targetPosition = $positions | Where-Object -Property code -eq $key
                $departmentIds = @()
                foreach ($department in $groupedPositions[$key]) {
                    $departmentIds += ($groupedOrgUnits[$department.$DepartmentCode].id)
                }
                $departmentIds = [array] ($departmentIds | Select-Object -Unique)
                $currentPosition = $groupedPositions[$key] | Select-Object -First 1
                if ($targetPosition.count -eq 0) {
                    $body = @{
                        code              = $currentPosition.$TitleCode
                        name              = $currentPosition.$TitleDescription
                        description       = $currentPosition.$TitleDescription
                        state             = 20
                        belongstoorgunits = $departmentIds
                    }
                    $splatCreatePositionsParams = @{
                        Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/positions"
                        Method      = 'POST'
                        Headers     = $Headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }
                    
                    $positionsResponse = Invoke-RestMethod @splatCreatePositionsParams -Verbose:$false # Exception not found
                    $positions += $positionsResponse

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "Created position: [$($currentPosition.$TitleCode)] with orgunits: [$($departmentIds)]"
                            IsError = $false
                        })
                }
                else {
                    $differentOrgUnits = Compare-Object -ReferenceObject @($targetPosition.belongstoorgunits | Select-Object) -DifferenceObject @($departmentIds | Select-Object)
                    if ($differentOrgUnits.InputObject.count -gt 0) {
                        $orgUnitIdsToAdd = $differentOrgUnits | Where-Object -Property SideIndicator -eq '=>'
                        
                        if ($null -ne $orgUnitIdsToAdd.InputObject) {
                            $allOrgUnitIdsForPosition = ($targetPosition.belongstoorgunits += $orgUnitIdsToAdd.InputObject)
                        }
                        if ($null -eq $orgUnitIdsToAdd.InputObject) {
                            $allOrgUnitIdsForPosition = $targetPosition.belongstoorgunits
                        }
                        
                        $body = @{
                            state             = 20
                            belongstoorgunits = @($allOrgUnitIdsForPosition)
                        }

                        $splatUpdatePositionsParams = @{
                            Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/positions/$($targetPosition.id)"
                            Method      = 'PUT'
                            Headers     = $Headers
                            Body        = ($body | ConvertTo-Json)
                            ContentType = 'application/json; charset=utf-8'
                        }
                        #filter to prevent unneccessary logging
                        if ($null -ne $orgUnitIdsToAdd.InputObject) {
                            $positionsResponse = Invoke-RestMethod @splatUpdatePositionsParams -Verbose:$false # Exception not found
                            $outputContext.AuditLogs.Add([PSCustomObject]@{
                                    Message = "Added orgunits: [$($allOrgUnitIdsForPosition)] to position: [$($currentPosition.InceptionPositionCode)]"
                                    IsError = $false
                                })
                        }
                    }
                    else {
                        if ($targetPosition.state -ne 20) {
                            $body = @{
                                $state = 20
                            }

                            $splatUpdatePositionsParams = @{
                                Uri         = "$($actionContext.Configuration.BaseUrl)/api/v2/hrm/positions/$($targetPosition.id)"
                                Method      = 'PUT'
                                Headers     = $Headers
                                Body        = ($body | ConvertTo-Json)
                                ContentType = 'application/json; charset=utf-8'
                            }
                            $positionsResponse = Invoke-RestMethod @splatUpdatePositionsParams -Verbose:$false # Exception not found
                        }
                        else {
                            Write-Verbose 'skipping action orgunit already added to position [$($currentPosition.$TitleCode)]'
                        }
                    }
                }
            }
        }
        else {
            Write-Verbose "[DryRun] Create [$($resource)] Inception resource, will be executed during enforcement" -Verbose
        }            
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not create Inception resource. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create Inception resource. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}    

