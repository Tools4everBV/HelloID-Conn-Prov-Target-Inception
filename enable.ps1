###########################################
# HelloID-Conn-Prov-Target-Inception-Enable
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

function Get-RandomCharacters($length, $characters) { 
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
    return [String]$characters[$random]
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

$accountUser = [PSCustomObject]@{
    id       = $aRef.AccountReference
    type     = 14
    name     = $p.Contact.Business.Email # UPN
    password = (Get-RandomCharacters -length 10 -characters 'abcdefghijklmnopqrstuvwxyzABCDEFGHKLMNOPRSTUVWXYZ1234567890!@#%&+{}') # Only used with new creations. Proprety is mandatory but is not used when using SSO.
}

# Begin
try {
    Write-Verbose "Verifying if a Inception account for [$($p.DisplayName)] exists"
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $(Get-InceptionToken)")
    $headers.Add('Accept', 'application/json')
    $headers.Add('Content-Type', 'application/json')

    if ([string]::IsNullOrEmpty($($aRef.AccountReference))) {
        throw 'No Account Reference found'
    }

    $employeeFound = $false
    $userFound = $false
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
    if (-not  $employeeFound) {
        throw "Employee account [$($aRef.AccountReference)] not found. Possibly deleted"
    }

    try {
        $splatUserParams = @{
            Uri     = "$($config.BaseUrl)/api/v2/security/users/$($aRef.AccountReference)"
            Method  = 'GET'
            Headers = $Headers
        }
        $user = Invoke-RestMethod @splatUserParams -Verbose:$false
        $userFound = $true
    }
    catch {
        if ( $_.Exception.message -notmatch '404' ) {
            throw $_
        }
    }



    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] Enable Inception Employee account for: [$($p.DisplayName)] will be executed during enforcement"
        if ($userFound) {
            Write-Warning "[DryRun] Enable Inception User account for: [$($p.DisplayName)] will be executed during enforcement"
        }
        else {
            Write-Warning "[DryRun] Create Inception User account for: [$($p.DisplayName)] will be executed during enforcement"
        }
    }

    # Process
    if (-not($dryRun -eq $true)) {
        Write-Verbose "Enabling Inception account with accountReference: [$($aRef.AccountReference)]"
        if ($employee.enddate) {
            $employeeEndDate = '9999-12-31'
        }
        $splatEnableEmployee = @{
            Uri     = "$($config.BaseUrl)/api/v2/hrm/employees/$($aRef.AccountReference)"
            Method  = 'PUT'
            Headers = $Headers
            Body    = @{
                state   = 20
                enddate = $employeeEndDate
            } | ConvertTo-Json
        }
        $employee = Invoke-RestMethod @splatEnableEmployee -Verbose:$false # Exception not found

        if ($userFound) {
            Write-Verbose 'Updating enddate of Exising User account'
            if ($user.enddate) {
                $userEndDate = '9999-12-31'
            }
            $splatEnableUser = @{
                Uri     = "$($config.BaseUrl)/api/v2/security/users/$($aRef.AccountReference)"
                Method  = 'PUT'
                Headers = $Headers
                Body    = @{
                    enddate = $userEndDate
                } | ConvertTo-Json
            }
            $user = Invoke-RestMethod @splatEnableUser -Verbose:$false
            $userAuditMessage = 'Enable User account'
        }
        else {
            Write-Verbose 'Creating new User account'
            $splatNewUser = @{
                Uri     = "$($config.BaseUrl)/api/v2/security/users"
                Method  = 'POST'
                Headers = $Headers
                Body    = $accountUser | ConvertTo-Json
            }
            $user = Invoke-RestMethod @splatNewUser -Verbose:$false
            $userAuditMessage = 'Create User account'
        }
        $auditLogs.Add([PSCustomObject]@{
                Message = "Enable Inception Employee account and $($userAuditMessage) was successful."
                IsError = $false
            })
    }
    $success = $true
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-InceptionError -ErrorObject $ex
        $auditMessage = "Could not enable Inception account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not enable Inception account. Error: $($ex.Exception.Message)"
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