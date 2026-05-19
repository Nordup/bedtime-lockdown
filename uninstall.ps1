# Bootstrap. The real uninstaller is uninstall.py.
$ErrorActionPreference = "Stop"
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)
& python uninstall.py @args
exit $LASTEXITCODE
