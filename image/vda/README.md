# vdagent payload

`vda-payload.tar.gz` (368 KB: vioserial driver + vdservice/vdagent) is NOT in git --
they are signed Windows binaries. Rebuild it from the official installer with
`../scripts/vda_build_payload.sh` (host-side 7z extraction, no VM needed; installer at
docker-w11-wx/shared/spice-guest-tools.exe). The published image already contains it.
