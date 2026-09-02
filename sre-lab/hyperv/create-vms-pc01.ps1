# Cria as VMs do host pc-01 (32 GB)
# Executar em PowerShell como administrador

$iso = 'D:\ISO\ubuntu-24.04-live-server-amd64.iso'

$vms = @(
    @{ Name='k8s-worker-01'; CPU=2; RAM=6GB;  Disk=60GB }
    @{ Name='k8s-worker-02'; CPU=2; RAM=6GB;  Disk=60GB }
    @{ Name='obs-01';        CPU=4; RAM=8GB;  Disk=120GB }
    @{ Name='svc-01';        CPU=2; RAM=4GB;  Disk=40GB }
)

foreach ($v in $vms) {
    $vhd = "D:\VMs\$($v.Name)\$($v.Name).vhdx"

    New-VM -Name $v.Name -Generation 2 -MemoryStartupBytes $v.RAM `
           -NewVHDPath $vhd -NewVHDSizeBytes $v.Disk -SwitchName 'vSwitch-ext'

    # StaticMemory: Dynamic Memory interfere no calculo de allocatable do kubelet
    Set-VM -Name $v.Name -ProcessorCount $v.CPU -StaticMemory `
           -AutomaticStartAction Start -AutomaticStopAction Save

    # Sem este template, Linux nao da boot com Secure Boot ligado
    Set-VMFirmware -VMName $v.Name -SecureBootTemplate MicrosoftUEFICertificateAuthority

    Add-VMDvdDrive -VMName $v.Name -Path $iso
    Set-VMFirmware -VMName $v.Name -FirstBootDevice (Get-VMDvdDrive -VMName $v.Name)

    # OBRIGATORIO: sem isso Calico e MetalLB nao funcionam
    Set-VMNetworkAdapter -VMName $v.Name -MacAddressSpoofing On

    Start-VM -Name $v.Name
}
