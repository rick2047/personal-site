param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$Domain = "pareshmathur.com",
    [string]$GithubUser = "rick2047",
    [switch]$IncludeIPv6 = $true
)

$ErrorActionPreference = "Stop"

$baseUri = "https://api.cloudflare.com/client/v4"
$headers = @{
    Authorization = "Bearer $Token"
    "Content-Type" = "application/json"
}

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PUT", "PATCH", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body
    )

    $params = @{
        Method  = $Method
        Uri     = "$baseUri$Path"
        Headers = $headers
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    $response = Invoke-RestMethod @params
    if (-not $response.success) {
        $message = if ($response.errors) {
            ($response.errors | ConvertTo-Json -Compress)
        } else {
            "Unknown Cloudflare API error"
        }
        throw "Cloudflare API call failed for $Method ${Path}: $message"
    }

    return $response.result
}

function Get-ZoneId {
    $zoneResult = @(Invoke-CloudflareApi -Method GET -Path "/zones?name=$Domain&status=active")
    if ($zoneResult.Count -ne 1) {
        throw "Expected exactly one active zone for $Domain, got $($zoneResult.Count)."
    }
    return $zoneResult[0].id
}

function Get-DnsRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZoneId,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Invoke-CloudflareApi -Method GET -Path "/zones/$ZoneId/dns_records?name=$Name&per_page=100"
}

function Remove-ConflictingRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZoneId,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedTypes
    )

    $records = @(Get-DnsRecords -ZoneId $ZoneId -Name $Name)
    foreach ($record in $records) {
        if ($AllowedTypes -notcontains $record.type) {
            Invoke-CloudflareApi -Method DELETE -Path "/zones/$ZoneId/dns_records/$($record.id)" | Out-Null
        }
    }
}

function Upsert-DnsRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZoneId,
        [Parameter(Mandatory = $true)]
        [ValidateSet("A", "AAAA", "CNAME")]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $existing = @(Invoke-CloudflareApi -Method GET -Path "/zones/$ZoneId/dns_records?type=$Type&name=$Name&content=$Content&per_page=100")
    $body = @{
        type    = $Type
        name    = $Name
        content = $Content
        ttl     = 1
        proxied = $false
    }

    if ($existing.Count -gt 0) {
        $recordId = $existing[0].id
        Invoke-CloudflareApi -Method PUT -Path "/zones/$ZoneId/dns_records/$recordId" -Body $body | Out-Null
    } else {
        Invoke-CloudflareApi -Method POST -Path "/zones/$ZoneId/dns_records" -Body $body | Out-Null
    }
}

$zoneId = Get-ZoneId
$apexName = $Domain
$wwwName = "www.$Domain"
$githubTarget = "$GithubUser.github.io"

Remove-ConflictingRecords -ZoneId $zoneId -Name $apexName -AllowedTypes @("A", "AAAA", "TXT", "MX", "NS", "CAA", "SRV")
Remove-ConflictingRecords -ZoneId $zoneId -Name $wwwName -AllowedTypes @("CNAME", "TXT", "MX", "CAA", "SRV")

$apexIpv4 = @(
    "185.199.108.153",
    "185.199.109.153",
    "185.199.110.153",
    "185.199.111.153"
)

foreach ($ip in $apexIpv4) {
    Upsert-DnsRecord -ZoneId $zoneId -Type A -Name $apexName -Content $ip
}

if ($IncludeIPv6) {
    $apexIpv6 = @(
        "2606:50c0:8000::153",
        "2606:50c0:8001::153",
        "2606:50c0:8002::153",
        "2606:50c0:8003::153"
    )

    foreach ($ip in $apexIpv6) {
        Upsert-DnsRecord -ZoneId $zoneId -Type AAAA -Name $apexName -Content $ip
    }
}

Upsert-DnsRecord -ZoneId $zoneId -Type CNAME -Name $wwwName -Content $githubTarget

Write-Output "Cloudflare DNS configured for $Domain"
