# mspc payload

The Dockerfile expects `mspc-payload.tar.gz` here. It is NOT in git: win32 binaries
(node.exe + native node_modules) cannot be produced from a Linux build host, so it is
packed from a live Windows VM with `../scripts/mspc_build_payload.ps1` (staged under
`C:\mspc-pkg`, shipped over SMB to the host as `shared/mspc-payload.tar.gz`, then copied
here). The published image on ghcr already contains it; you only need this file if you
insist on rebuilding the image locally.
