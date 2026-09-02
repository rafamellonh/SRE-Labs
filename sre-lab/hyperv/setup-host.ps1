# Preparacao inicial do host Hyper-V
# Executar nos dois mini PCs, em PowerShell como administrador
# Reiniciar apos habilitar o Hyper-V

Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
New-VMSwitch -Name 'vSwitch-ext' -NetAdapterName $nic.Name -AllowManagementOS $true

New-Item -ItemType Directory -Path 'D:\VMs','D:\ISO' -Force
