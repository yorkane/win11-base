# Runs INSIDE the console session (Interactive one-shot task) and pushes
# C:\Temp\w11clip.txt (utf-16 w/ BOM) into the user clipboard, reads it back,
# and writes its OWN log file. The scheduled-task action must NOT redirect to
# that same path: cmd keeps the handle open and Set-Content silently loses the
# write (measured 2026-09-09: log existed but 0 bytes).
# ASCII-only source: PS 5.1 misparses UTF-8-without-BOM scripts with CJK comments.
$log = 'C:\Temp\w11clip.log'
$out = @()
try {
  $src = [IO.File]::ReadAllText('C:\Temp\w11clip.txt')
  Set-Clipboard -Value $src
  $back = Get-Clipboard -Raw
  $out += ('CLIPSET=' + $src.Length)
  $head = $back.Substring(0, [Math]::Min(40, $back.Length))
  $code = @()
  foreach ($ch in $head.ToCharArray()) { $code += [int]$ch }
  $out += ('CODES=' + ($code -join ','))
} catch {
  $out += ('CLIPERR=' + $_.Exception.Message)
}
$out += 'CLIP_DONE'
[IO.File]::WriteAllText($log, ($out -join [char]13 + [char]10), [Text.Encoding]::UTF8)
exit 0
