# Mingo test VM.  .\run-vm.ps1 [reset] [uefi] [debug] [show]
$p = ($PSScriptRoot -replace '^([A-Za-z]):', { '/mnt/' + $_.Groups[1].Value.ToLower() }) -replace '\\', '/'
wsl -d Ubuntu -u root -- bash "$p/run-vm.sh" @args
