# Bootstrap. The real installer is install.py.
$ErrorActionPreference = "Stop"
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)
& python install.py @args
exit $LASTEXITCODE
