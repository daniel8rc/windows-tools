# find-biggest-folder.ps1
# Código en inglés, comentarios en español.
# Comando: .\find-biggest-folder.ps1 -PerFolderTimeout 10 -MaxDepth 5 -Root "C:\"

param(
    # Tiempo en segundos que esperamos por cada medición de carpeta
    [int]$PerFolderTimeout = 8,
    # Profundidad máxima de descenso (1 = solo primer nivel, 2 = primer nivel + 1 nivel dentro de la carpeta más grande, etc.)
    [int]$MaxDepth = 4,
    # Ruta raíz a escanear (por defecto C:\)
    [string]$Root = "C:\"
)

# -----------------------
# Funciones auxiliares
# -----------------------

function BytesToHuman {
    param([long]$bytes)
    if ($bytes -eq $null -or $bytes -eq 0) { return "0 B" }
    $sizes = "B","KB","MB","GB","TB"
    $i = 0
    $d = [double]$bytes
    while ($d -ge 1024 -and $i -lt $sizes.Length - 1) {
        $d = $d / 1024
        $i++
    }
    return ("{0:N2} {1}" -f $d, $sizes[$i])
}

function Start-SizeJob {
    param([string]$path)
    # Inicia un job que calcula la suma de tamaños (bytes) de todos los ficheros bajo $path
    return Start-Job -ScriptBlock {
        param($p)
        try {
            $sum = (Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue -File | Measure-Object -Property Length -Sum).Sum
            if ($sum -eq $null) { $sum = 0 }
            return @{ Path = $p; Bytes = [long]$sum; Status = "OK" }
        } catch {
            return @{ Path = $p; Bytes = 0; Status = "ERROR" }
        }
    } -ArgumentList $path
}

function Measure-DirsFast {
    param(
        [string[]]$dirs,
        [int]$timeoutSec
    )
    # Lanza jobs en paralelo para cada dir y espera con timeout.
    $jobs = @()
    foreach ($d in $dirs) {
        $jobs += Start-SizeJob -path $d
    }

    $results = @()
    foreach ($j in $jobs) {
        $finished = Wait-Job -Job $j -Timeout $timeoutSec
        if ($finished) {
            $r = Receive-Job -Job $j -ErrorAction SilentlyContinue
            if ($r -ne $null) {
                $results += $r
            } else {
                # si no hay resultado, intentamos extraer la ruta desde el argumento del job
                $argPath = $null
                try {
                    $argPath = ($j.ChildJobs[0].JobStateInfo.Reason | Out-String).Trim()
                } catch {}
                $results += @{ Path = $argPath; Bytes = 0; Status = "NO_RESULT" }
            }
        } else {
            # No ha terminado a tiempo: lo matamos y marcamos como TIMEOUT
            try {
                Stop-Job -Job $j -Force -ErrorAction SilentlyContinue
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            } catch {}
            # Intentamos recuperar el argumento Path de forma segura
            $arg = $null
            try {
                $arg = $j.ChildJobs[0].InvocationInfo.Arguments | Select-Object -First 1
            } catch {}
            $results += @{ Path = ($arg -as [string]); Bytes = 0; Status = "TIMEOUT" }
        }
    }

    # Cleanup jobs por si queda alguno
    Get-Job | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        try { Stop-Job $_ -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $_ -Force -ErrorAction SilentlyContinue } catch {}
    }

    return $results
}

# -----------------------
# Lógica principal
# -----------------------

Write-Host "Iniciando búsqueda rápida en $Root (timeout por carpeta: $PerFolderTimeout s, max depth: $MaxDepth)." -ForegroundColor Cyan

# Normalizar ruta
$rootPath = [IO.Path]::GetFullPath($Root)

# Empezar con primer nivel
$currentDirs = Get-ChildItem -Path $rootPath -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

if (-not $currentDirs -or $currentDirs.Count -eq 0) {
    Write-Host "No se encontraron directorios en $rootPath" -ForegroundColor Red
    exit 1
}

$depth = 1
$largestCandidate = @{ Path = $rootPath; Bytes = 0; Status = "ROOT" }

while ($depth -le $MaxDepth) {
    Write-Host ""
    # <-- CORRECCIÓN: usar $($depth) y $($currentDirs.Count) para interpolación segura
    Write-Host ("== Nivel {0}: midiendo {1} carpetas (timeout por carpeta: {2} s) ==" -f $($depth), $($currentDirs.Count), $PerFolderTimeout) -ForegroundColor Yellow

    $measurements = Measure-DirsFast -dirs $currentDirs -timeoutSec $PerFolderTimeout

    # Ordenar por Bytes (si Bytes no existe o es null, tratamos como 0)
    $sorted = $measurements | Sort-Object -Property @{Expression = { if ($_.Bytes) { $_.Bytes } else { 0 } } } -Descending

    # Mostrar resumen rápido del nivel (top 10)
    $idx = 0
    foreach ($m in $sorted) {
        $idx++
        $displayBytes = if ($m.Bytes -and $m.Bytes -gt 0) { BytesToHuman $m.Bytes } else { "-" }
        $status = $m.Status
        Write-Host ("{0,2}. {1} | {2} | {3}" -f $idx, $m.Path, $displayBytes, $status)
        if ($idx -ge 10) { break } # mostramos solo top 10
    }

    # Elegir el candidato más grande que tenga Bytes > 0; si todos 0, escoger primero no-timeout
    $best = $sorted | Where-Object { $_.Bytes -gt 0 } | Select-Object -First 1
    if (-not $best) {
        $best = $sorted | Where-Object { $_.Status -ne "TIMEOUT" } | Select-Object -First 1
        if (-not $best) { $best = $sorted | Select-Object -First 1 }
    }

    if ($best -and $best.Path) {
        $largestCandidate = $best
    }

    # Si el candidato no tiene subdirectorios o alcance max depth, rompemos
    try {
        $subdirs = Get-ChildItem -Path $largestCandidate.Path -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    } catch {
        $subdirs = @()
    }

    if (-not $subdirs -or $subdirs.Count -eq 0) {
        Write-Host ""
        Write-Host "No se encontraron subdirectorios dentro de: $($largestCandidate.Path) — detenido." -ForegroundColor Green
        break
    }

    # Preparar siguiente iteración: descender solo dentro del candidato mayor
    $currentDirs = $subdirs
    $depth++
}

# Resultado final
$finalPath = $largestCandidate.Path
$finalBytes = if ($largestCandidate.Bytes) { $largestCandidate.Bytes } else { 0 }

Write-Host ""
Write-Host "===== Resultado (posición estimada) =====" -ForegroundColor Cyan
Write-Host ("Ruta: {0}" -f $finalPath) -ForegroundColor White
Write-Host ("Tamaño (estimado): {0}" -f (BytesToHuman $finalBytes)) -ForegroundColor Green
Write-Host "Nota: Si ves '0' o '-' probablemente la medición dio TIMEOUT o faltan permisos. Aumenta PerFolderTimeout para más precisión." -ForegroundColor Yellow
Write-Host ""
Write-Host "Si quieres un escaneo exacto (más lento), puedo darte una versión que haga un Get-ChildItem -Recurse completo sobre la carpeta final." -ForegroundColor Cyan
