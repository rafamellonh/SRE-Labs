# Snapshots das VMs. Restaurar leva segundos; refazer leva horas.
# Uso: .\checkpoints.ps1 -Name 'antes-do-caos'

param([Parameter(Mandatory=$true)][string]$Name)

Get-VM | Checkpoint-VM -SnapshotName $Name
Get-VMSnapshot -VMName * | Select-Object VMName, Name, CreationTime
