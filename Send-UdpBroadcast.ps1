[CmdletBinding()]
param(
    [string]$InterfaceAlias = "vEthernet (wsl-net)",
    [string]$BroadcastAddress = "10.10.255.255",
    [ValidateRange(1, 65535)]
    [int]$Port = 8001,
    [ValidateRange(1, 10000)]
    [int]$Count = 10,
    [ValidateRange(0, 86400)]
    [int]$IntervalSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$addressInfo = Get-NetIPAddress `
    -InterfaceAlias $InterfaceAlias `
    -AddressFamily IPv4 `
    -ErrorAction Stop |
    Where-Object { $_.IPAddress -notlike "169.254.*" } |
    Select-Object -First 1

if ($null -eq $addressInfo) {
    throw "No usable IPv4 address was found on interface '$InterfaceAlias'."
}

$sourceAddress = [System.Net.IPAddress]::Parse($addressInfo.IPAddress)
$destinationAddress = [System.Net.IPAddress]::Parse($BroadcastAddress)
$sourceEndpoint = [System.Net.IPEndPoint]::new($sourceAddress, 0)
$destinationEndpoint = [System.Net.IPEndPoint]::new($destinationAddress, $Port)
$udpClient = [System.Net.Sockets.UdpClient]::new($sourceEndpoint)
$udpClient.EnableBroadcast = $true

try {
    Write-Host "Source      : $($addressInfo.IPAddress) ($InterfaceAlias)"
    Write-Host "Destination : ${BroadcastAddress}:$Port"
    Write-Host "Schedule    : $Count packets, one every $IntervalSeconds seconds"
    Write-Host ""

    for ($sequence = 1; $sequence -le $Count; $sequence++) {
        $timestamp = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz")
        $message = "WSL-UDP-BROADCAST sequence=$sequence/$Count source=$($addressInfo.IPAddress) timestamp=$timestamp"
        $payload = [System.Text.Encoding]::UTF8.GetBytes($message)
        $bytesSent = $udpClient.Send($payload, $payload.Length, $destinationEndpoint)

        Write-Host "[$sequence/$Count] Sent $bytesSent bytes: $message"

        if ($sequence -lt $Count -and $IntervalSeconds -gt 0) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
}
finally {
    $udpClient.Dispose()
}
