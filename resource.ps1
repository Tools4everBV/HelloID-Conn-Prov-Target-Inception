#############################################
# HelloID-Conn-Prov-Target-Inception-Resource
#
# Version: 1.0.0
#############################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$rRef = $resourceContext | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

$rRef.sourceData = ($rRef.sourceData | Where-Object { -not [string]::IsNullOrEmpty($_.DepartmentCode) })

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
function Get-InceptionPositions {
    [CmdletBinding()]
    Param(
        $PageSize = 200,

        $headers
    )
    try {
        $pageNumber = 1
        $positions = [System.Collections.Generic.list[object]]::new()
        do {
            $splatUserParams = @{
                Uri     = "$($config.BaseUrl)/api/v2/hrm/positions?pagesize=$PageSize&page=$pageNumber"
                Method  = 'GET'
                Headers = $headers
            }
            $positionsResponse = Invoke-RestMethod @splatUserParams -Verbose:$false # Exception not found

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

function Get-InceptionOrgunits {
    [CmdletBinding()]
    Param(
        $PageSize = 200,

        $Headers
    )
    try {
        $pageNumber = 1
        $orgunits = [System.Collections.Generic.list[object]]::new()
        do {
            $splatUserParams = @{
                Uri     = "$($config.BaseUrl)/api/v2/hrm/orgunits?pagesize=$PageSize&page=$pageNumber"
                Method  = 'GET'
                Headers = $Headers
            }
            $orgunitsResponse = Invoke-RestMethod @splatUserParams -Verbose:$false # Exception not found

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
#endregion

try {
    # Process
    if (-not ($dryRun -eq $true)) {
        Write-Verbose "Creating [$($rRef.SourceData.count)] resources"
        try {
            <# Resource creation preview uses a timeout of 30 seconds
                while actual run has a timeout of 10 minutes #>
            $headers = @{
                Accept        = 'application/json'
                Authorization = "Bearer $(Get-InceptionToken)"
            }

            $OrgUnits = Get-InceptionOrgunits -Headers $headers
            $positions = Get-InceptionPositions -Headers $headers

            foreach ($orgUnit in $rRef.sourceData) {
                $targetOrgUnit = ($OrgUnits | Where-Object -Property code -eq $orgunit.DepartmentCode)
                if ($targetOrgUnit.count -eq 0) {
                    $body = @{
                        code        = $orgUnit.DepartmentCode
                        name        = $orgUnit.DepartmentCode
                        description = $orgUnit.DepartmentName
                        state       = 20
                    }
                    $splatCreateOrgunitParams = @{
                        Uri         = "$($config.BaseUrl)/api/v2/hrm/orgunits"
                        Method      = 'POST'
                        Headers     = $Headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }
                    $orgunitsResponse = Invoke-RestMethod @splatCreateOrgunitParams -Verbose:$false # Exception not found
                    $OrgUnits += $orgunitsResponse

                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Created orgUnit: [$($orgUnit.DepartmentCode)]"
                            IsError = $false
                        })
                } else {
                    $orgUnit = $OrgUnits | Where-Object -Property code -eq $orgunit.DepartmentCode
                    if ($orgUnit.state -ne 20) {
                        $body = @{
                            state = 20
                        }
                        $splatCreateOrgunitParams = @{
                            Uri         = "$($config.BaseUrl)/api/v2/hrm/orgunits/$($orgUnit.id)"
                            Method      = 'PUT'
                            Headers     = $Headers
                            Body        = ($body | ConvertTo-Json)
                            ContentType = 'application/json; charset=utf-8'

                        }
                        $orgunitsResponse = Invoke-RestMethod @splatCreateOrgunitParams -Verbose:$false # Exception not found
                    }
                }
            }

            $groupedOrgUnits = $OrgUnits | Group-Object -Property code -AsString -AsHashTable
            $groupedPositions = $rRef.SourceData | Group-Object -Property TitleCode -AsString -AsHashTable

            foreach ($key in $groupedPositions.Keys) {
                $targetPosition = $positions | Where-Object -Property code -eq $key
                $departmentIds = @()
                foreach ($department in $groupedPositions[$key]) {
                    $departmentIds += ($groupedOrgUnits[$department.DepartmentCode].id)
                }
                $departmentIds = [array] ($departmentIds | Select-Object -Unique)
                $currentPosition = $groupedPositions[$key] | Select-Object -First 1
                if ($targetPosition.count -eq 0) {
                    $body = @{
                        code              = $currentPosition.TitleCode
                        name              = $currentPosition.TitleCode
                        description       = $currentPosition.TitleDescription
                        state             = 20
                        belongstoorgunits = $departmentIds
                    }
                    $splatCreatePositionsParams = @{
                        Uri         = "$($config.BaseUrl)/api/v2/hrm/positions"
                        Method      = 'POST'
                        Headers     = $Headers
                        Body        = ($body | ConvertTo-Json)
                        ContentType = 'application/json; charset=utf-8'
                    }

                    $positionsResponse = Invoke-RestMethod @splatCreatePositionsParams -Verbose:$false # Exception not found
                    $positions += $positionsResponse

                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Created position: [$($currentPosition.TitleCode)] with orgunits: [$($departmentIds)]"
                            IsError = $false
                        })
                } else {
                    $differentOrgUnits = Compare-Object -ReferenceObject @($targetPosition.belongstoorgunits | Select-Object) -DifferenceObject @($departmentIds | Select-Object)
                    if ($differentOrgUnits.InputObject.count -gt 0) {
                        $orgUnitIdsToAdd = $differentOrgUnits | Where-Object -Property SideIndicator -eq '=>'
                        $allOrgUnitIdsForPosition = ($targetPosition.belongstoorgunits += $orgUnitIdsToAdd.InputObject)
                        $body = @{
                            state             = 20
                            belongstoorgunits = @($allOrgUnitIdsForPosition)
                        }

                        $splatUpdatePositionsParams = @{
                            Uri         = "$($config.BaseUrl)/api/v2/hrm/positions/$($targetPosition.id)"
                            Method      = 'PUT'
                            Headers     = $Headers
                            Body        = ($body | ConvertTo-Json)
                            ContentType = 'application/json; charset=utf-8'
                        }
                        $positionsResponse = Invoke-RestMethod @splatUpdatePositionsParams -Verbose:$false # Exception not found
                        $auditLogs.Add([PSCustomObject]@{
                                Message = "Added orgunits: [$($allOrgUnitIdsForPosition)] to position: [$($currentPosition.TitleCode)]"
                                IsError = $false
                            })

                    } else {
                        if ($targetPosition.state -ne 20) {
                            $body = @{
                                $state = 20
                            }

                            $splatUpdatePositionsParams = @{
                                Uri         = "$($config.BaseUrl)/api/v2/hrm/positions/$($targetPosition.id)"
                                Method      = 'PUT'
                                Headers     = $Headers
                                Body        = ($body | ConvertTo-Json)
                                ContentType = 'application/json; charset=utf-8'
                            }
                            $positionsResponse = Invoke-RestMethod @splatUpdatePositionsParams -Verbose:$false # Exception not found
                        } else {
                            Write-Verbose 'skipping action orgunit already added to position'
                        }
                    }
                }
            }

            $success = $true
        } catch {
            $success = $false
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-InceptionError -ErrorObject $ex
                $auditMessage = "Could not create Inception resource. Error: $($errorObj.FriendlyMessage)"
                Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            } else {
                $auditMessage = "Could not create Inception resource. Error: $($ex.Exception.Message)"
                Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $auditLogs.Add([PSCustomObject]@{
                    Message = $auditMessage
                    IsError = $true
                })
        }
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not create Inception resource. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create Inception resource. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
