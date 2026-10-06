$Esp32Address = "192.168.0.124"
$Port = 42100
$IntervalSeconds = 2
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$Endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Esp32Address), $Port)
$UdpClient = [System.Net.Sockets.UdpClient]::new()

$PreviousReceivedBytes = $null
$PreviousSentBytes = $null
$PreviousSampleTime = $null

Write-Host "Sending PC metrics to $Esp32Address`:$Port every $IntervalSeconds seconds."
Write-Host "Press Ctrl+C to stop. Use a trusted private Wi-Fi network."

try {
    while ($true) {
        try {
            $Processors = @(Get-CimInstance -ClassName Win32_Processor)
            $CpuAverage = ($Processors | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -eq $CpuAverage) {
                $CpuAverage = 0
            }

            $OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
            $RamTotalGb = [double]$OperatingSystem.TotalVisibleMemorySize / 1048576
            $RamUsedGb = ([double]$OperatingSystem.TotalVisibleMemorySize - [double]$OperatingSystem.FreePhysicalMemory) / 1048576

            $SystemDrive = $env:SystemDrive
            $Disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$SystemDrive'"
            if ($null -eq $Disk -or $Disk.Size -le 0) {
                throw "Could not read capacity for system drive $SystemDrive."
            }
            $DiskTotalGb = [double]$Disk.Size / 1GB
            $DiskUsedGb = ([double]$Disk.Size - [double]$Disk.FreeSpace) / 1GB

            $ReceivedBytes = [long]0
            $SentBytes = [long]0
            $Adapters = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object {
                    $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                    $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
                    $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel
                }
            foreach ($Adapter in $Adapters) {
                $Statistics = $Adapter.GetIPv4Statistics()
                $ReceivedBytes += [long]$Statistics.BytesReceived
                $SentBytes += [long]$Statistics.BytesSent
            }

            $Now = [DateTime]::UtcNow
            $RxMbps = [double]0
            $TxMbps = [double]0
            if ($null -ne $PreviousSampleTime) {
                $ElapsedSeconds = ($Now - $PreviousSampleTime).TotalSeconds
                if ($ElapsedSeconds -gt 0) {
                    $RxMbps = [math]::Max(0, ($ReceivedBytes - $PreviousReceivedBytes) * 8 / $ElapsedSeconds / 1000000)
                    $TxMbps = [math]::Max(0, ($SentBytes - $PreviousSentBytes) * 8 / $ElapsedSeconds / 1000000)
                }
            }

            $PreviousReceivedBytes = $ReceivedBytes
            $PreviousSentBytes = $SentBytes
            $PreviousSampleTime = $Now

            $Fields = @(
                "PC1"
                $env:COMPUTERNAME
                ([double]$CpuAverage).ToString("F1", $InvariantCulture)
                ([double]$RamUsedGb).ToString("F2", $InvariantCulture)
                ([double]$RamTotalGb).ToString("F2", $InvariantCulture)
                $SystemDrive
                ([double]$DiskUsedGb).ToString("F2", $InvariantCulture)
                ([double]$DiskTotalGb).ToString("F2", $InvariantCulture)
                ([double]$RxMbps).ToString("F2", $InvariantCulture)
                ([double]$TxMbps).ToString("F2", $InvariantCulture)
            )
            $Packet = [string]::Join("|", $Fields)
            $Bytes = $Utf8.GetBytes($Packet)
            [void]$UdpClient.Send($Bytes, $Bytes.Length, $Endpoint)
            Write-Host ("CPU {0}% | RAM {1:N1}/{2:N1} GB | {3} {4:N1}/{5:N1} GB | Down {6:N2} Mbps | Up {7:N2} Mbps" -f
                [double]$CpuAverage, $RamUsedGb, $RamTotalGb, $SystemDrive, $DiskUsedGb, $DiskTotalGb, $RxMbps, $TxMbps)
        }
        catch {
            Write-Warning $_.Exception.Message
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $UdpClient.Dispose()
}
