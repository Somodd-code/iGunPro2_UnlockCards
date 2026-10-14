# Serves this folder only on loopback so the reader has a normal HTTP origin.
# It is intentionally not exposed to the LAN or public internet.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$prefix = 'http://127.0.0.1:18765/'
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($path)) { $path = 'reader.html' }
            $full = [IO.Path]::GetFullPath((Join-Path $root $path))
            if ((-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $ctx.Response.StatusCode = 404
                $bytes = [Text.Encoding]::UTF8.GetBytes('Not found')
            } else {
                $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
                $ctx.Response.ContentType = switch ($ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.js' { 'application/javascript; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css' { 'text/css; charset=utf-8' }
                    '.txt' { 'text/plain; charset=utf-8' }
                    default { 'application/octet-stream' }
                }
                $ctx.Response.Headers['Cache-Control'] = 'no-store'
                $bytes = [IO.File]::ReadAllBytes($full)
            }
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            try { $ctx.Response.StatusCode = 500 } catch {}
        } finally {
            try { $ctx.Response.Close() } catch {}
        }
    }
} finally {
    $listener.Close()
}
