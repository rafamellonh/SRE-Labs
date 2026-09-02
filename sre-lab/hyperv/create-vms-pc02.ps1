# Cria as VMs do host pc-02 (16 GB)
# Executar em PowerShell como administrador
# Nota: ansible-ctl usa a ISO do CentOS Stream 9

$isoUbuntu = 'D:\ISO\ubuntu-24.04-live-server-amd64.iso'
$isoCentOS = 'D:\ISO\CentOS-Stream-9-latest-x86_64-dvd1.iso'

$vms = @(
    @{ Name='k8s-cp-01';   CPU=2; RAM=4GB; Disk=60GB; Iso=$isoUbuntu }
    @{ Name='ansible-ctl'; CPU=2; RAM=3GB; Disk=40GB; Iso=$isoCentOS }
    @{ Name='zbx-01';      CPU=2; RAM=4GB; Disk=80GB; Iso=$isoUbuntu }
)

foreach ($v in $vms) {
    $vhd = "D:\VMs\$($v.Name)\$($v.Name).vhdx"

    New-VM -Name $v.Name -Generation 2 -MemoryStartupBytes $v.RAM `
           -NewVHDPath $vhd -NewVHDSizeBytes $v.Disk -SwitchName 'vSwitch-ext'

    Set-VM -Name $v.Name -ProcessorCount $v.CPU -StaticMemory `
           -AutomaticStartAction Start -AutomaticStopAction Save

    Set-VMFirmware -VMName $v.Name -SecureBootTemplate MicrosoftUEFICertificateAuthority

    Add-VMDvdDrive -VMName $v.Name -Path $v.Iso
    Set-VMFirmware -VMName $v.Name -FirstBootDevice (Get-VMDvdDrive -VMName $v.Name)

    Set-VMNetworkAdapter -VMName $v.Name -MacAddressSpoofing On

    Start-VM -Name $v.Name
}
