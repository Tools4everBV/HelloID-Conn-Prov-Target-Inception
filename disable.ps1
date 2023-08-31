############################################
# HelloID-Conn-Prov-Target-Inception-Disable
#
# Version: 1.0.1
############################################
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
    Write-Verbose "Verifying if a Inception account for [$($p.DisplayName)] exists"
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
        $null = Invoke-RestMethod @splatUserParams -Verbose:$false
        $employeeFound = $true
    }
    catch {
        if ( $_.Exception.message -notmatch '404' ) {
            throw $_
        }
    }

    if ($employeeFound) {
        $action = 'Found'
        $dryRunMessage = "Disable Inception Employee account for: [$($p.DisplayName)] will be executed during enforcement"
    }
    elseif (-not $employeeFound) {
        $action = 'NotFound'
        $dryRunMessage = "Inception Employee account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Found' {
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
                break
            }

            'NotFound' {
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Inception Employee account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
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
        $auditMessage = "Could not disable Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not disable Inception account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    if ($dryrun -eq $true) {
        Write-Warning "[DryRun] $($auditMessage)"
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
