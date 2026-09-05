# Build the mspc payload from the live C:\mspc (win32 binaries must come from the VM itself).
# Trim: dev-only packages (typescript, @esbuild), .env, logs, caches, demos. Ship: dist, assets,
# package.json, .env.example, trimmed node_modules, plus node.exe.
$ErrorActionPreference = 'Stop'
$unc = '\\host.lan@Data'
$stage = 'C:\mspc-pkg'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction Continue }
New-Item -ItemType Directory -Path ($stage + '\payload\mspc') -Force | Out-Null
Copy-Item 'C:\mspc\dist' ($stage + '\payload\mspc\dist') -Recurse -Force
Copy-Item 'C:\mspc\assets' ($stage + '\payload\mspc\assets') -Recurse -Force
Copy-Item 'C:\mspc\package.json' ($stage + '\payload\mspc') -Force
Copy-Item 'C:\mspc\.env.example' ($stage + '\payload\mspc\.env.example') -Force
# node_modules without dev-only heavies
$nmDst = $stage + '\payload\mspc\node_modules'
New-Item -ItemType Directory -Path $nmDst -Force | Out-Null
$skip = @('.pnpm','typescript','.bin','@types','.package-lock.json')
foreach ($d in Get-ChildItem ('C:\mspc\node_modules') -Force -Directory) {
  if ($skip -contains $d.Name) { Write-Output ('SKIP=' + $d.Name); continue }
  Copy-Item $d.FullName (Join-Path $nmDst $d.Name) -Recurse -Force
}
Copy-Item 'C:\Program Files\nodejs\node.exe' ($stage + '\payload\node.exe') -Force
$sz = (Get-ChildItem ($stage + '\payload') -Recurse -File | Measure-Object Length -Sum).Sum
Write-Output ('STAGED_MB=' + [int]($sz/1MB))
tar.exe -czf ($stage + '\mspc-payload.tar.gz') -C ($stage + '\payload') .
Write-Output ('TAR_EXIT=' + $LASTEXITCODE)
$tgz = Get-Item ($stage + '\mspc-payload.tar.gz')
Write-Output ('TGZ_MB=' + [int]($tgz.Length/1MB))
Copy-Item $tgz.FullName (Join-Path $unc 'mspc-payload.tar.gz') -Force
Write-Output ('SHIPPED=' + (Test-Path (Join-Path $unc 'mspc-payload.tar.gz')))
Remove-Item $stage -Recurse -Force
Write-Output MSPC_PKG_DONE
