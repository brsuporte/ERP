<#
.SYNOPSIS
    Browser Diagnostic Manager - BR Suporte Informática
.DESCRIPTION
    Ferramenta profissional de diagnóstico, manutenção, backup, restauração
    e otimização de navegadores. Desenvolvida para uso interno da BR Suporte Informática.
.VERSION
    1.0.0
.BUILD
    20260629
.AUTHOR
    BR Suporte Informática
.NOTES
    Compatível com Windows PowerShell 5.1+ e Windows 10/11.
    Não requer dependências externas, módulos, DLLs de terceiros ou executáveis externos.

    Changelog v1.0.0:
    - Implementação inicial completa
    - Interface WPF moderna com tema escuro (Catppuccin Mocha)
    - Dashboard com métricas em tempo real (auto-refresh 3s)
    - Diagnóstico completo com relatório HTML
    - Gerenciamento de abas via Chrome DevTools Protocol (CDP)
    - Limpeza seletiva e Otimização Inteligente
    - Backup e Restauração com Manifest.json e Inventario.json
    - Ferramentas de atalho para pastas e páginas do Chrome
    - Sistema de Configuração via Config.json
    - Visualizador de Logs em tempo real
    - Modo Atendimento com compactação ZIP
    - Estrutura automática de diretórios em C:\Inst\Navegadores
#>

#region === INICIALIZAÇÃO ===
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
#endregion

#region === CONSTANTES ===
$script:AppName   = "Browser Diagnostic Manager"
$script:Company   = "BR Suporte Informática"
$script:Version   = "1.0.0"
$script:Build     = "20260629"
$script:BaseDir   = "C:\Inst\Navegadores"
$script:StartTime = Get-Date

$script:Dirs = [ordered]@{
    Base          = $script:BaseDir
    Backup        = "$script:BaseDir\Backup"
    BackupChrome  = "$script:BaseDir\Backup\Chrome"
    BackupEdge    = "$script:BaseDir\Backup\Edge"
    BackupBrave   = "$script:BaseDir\Backup\Brave"
    BackupFirefox = "$script:BaseDir\Backup\Firefox"
    BackupOpera   = "$script:BaseDir\Backup\Opera"
    Diagnosticos  = "$script:BaseDir\Diagnosticos"
    Logs          = "$script:BaseDir\Logs"
    Relatorios    = "$script:BaseDir\Relatorios"
    Restore       = "$script:BaseDir\Restore"
    Temp          = "$script:BaseDir\Temp"
    Atendimentos  = "$script:BaseDir\Atendimentos"
}

$script:ConfigFile          = "$script:BaseDir\Config.json"
$script:LogFile             = "$script:BaseDir\BrowserDiagnosticManager.log"
$script:Config              = $null
$script:Window              = $null
$script:LogTextBox          = $null
$script:Timer               = $null
$script:CurrentAtendimento  = $null
$script:LastDiagnosticReport = $null
#endregion

#region === ESTRUTURA DE ARQUIVOS ===
function Initialize-AppStructure {
    <#
    .SYNOPSIS
        Cria os diretórios e arquivos necessários para a aplicação.
    #>
    foreach ($dir in $script:Dirs.Values) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if (-not (Test-Path $script:ConfigFile)) {
        $default = [ordered]@{
            Theme       = "Dark"
            Language    = "pt-BR"
            AutoRefresh = $true
            BaseDir     = $script:BaseDir
            Whitelist   = @()
            Version     = $script:Version
        }
        $default | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigFile -Encoding UTF8
    }
}
#endregion

#region === LOG ===
function Write-AppLog {
    <#
    .SYNOPSIS
        Registra uma entrada no log da aplicação.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Level] $Message"

    try {
        $logDir = Split-Path $script:LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }

    if ($script:LogTextBox -and $script:Window) {
        try {
            $script:Window.Dispatcher.InvokeAsync([Action]{
                $script:LogTextBox.AppendText("$line`n")
                $script:LogTextBox.ScrollToEnd()
            }) | Out-Null
        } catch { }
    }
}
#endregion

#region === CONFIGURAÇÃO ===
function Get-AppConfig {
    <#
    .SYNOPSIS
        Carrega a configuração do arquivo Config.json.
    #>
    try {
        if (Test-Path $script:ConfigFile) {
            return (Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch {
        Write-AppLog "Erro ao carregar configuração: $_" -Level ERROR
    }
    return $null
}

function Save-AppConfig {
    <#
    .SYNOPSIS
        Salva a configuração no arquivo Config.json.
        Nunca sobrescreve — apenas mescla novas propriedades.
    #>
    [CmdletBinding()]
    param([hashtable]$NewConfig)

    try {
        $existing = Get-AppConfig
        $merged   = [ordered]@{}

        # Preserva propriedades existentes
        if ($existing) {
            $existing.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
        }

        # Aplica novos valores
        foreach ($key in $NewConfig.Keys) { $merged[$key] = $NewConfig[$key] }

        $merged | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigFile -Encoding UTF8
        Write-AppLog "Configuração salva" -Level INFO
    } catch {
        Write-AppLog "Erro ao salvar configuração: $_" -Level ERROR
    }
}
#endregion

#region === DETECÇÃO DO CHROME ===
function Get-ChromeInstallPath {
    $paths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:LocalAppData}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-ChromeVersion {
    param([string]$ChromePath)
    try {
        if ($ChromePath -and (Test-Path $ChromePath)) {
            return (Get-Item $ChromePath).VersionInfo.ProductVersion
        }
    } catch { }
    return "Não encontrado"
}

function Get-ChromeProfilePath {
    return "$env:LOCALAPPDATA\Google\Chrome\User Data"
}

function Get-ChromeProfiles {
    $base = Get-ChromeProfilePath
    if (-not (Test-Path $base)) { return @() }

    $result = @()
    Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(Default|Profile \d+)$' } |
        ForEach-Object {
            $displayName = $_.Name
            $prefFile    = Join-Path $_.FullName 'Preferences'
            if (Test-Path $prefFile) {
                try {
                    $pref = Get-Content $prefFile -Raw | ConvertFrom-Json
                    if ($pref.profile.name) { $displayName = $pref.profile.name }
                } catch { }
            }
            $result += [PSCustomObject]@{
                Directory = $_.Name
                Name      = $displayName
                Path      = $_.FullName
            }
        }
    return $result
}

function Get-ChromeProcessInfo {
    $procs = Get-Process -Name chrome -ErrorAction SilentlyContinue
    if (-not $procs) { return @{ Count = 0; RAM = 0; CPU = 0 } }
    return @{
        Count = @($procs).Count
        RAM   = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        CPU   = [math]::Round(($procs | Measure-Object CPU -Sum).Sum, 1)
    }
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
        return [math]::Round($sum / 1MB, 1)
    } catch { return 0 }
}

function Get-ChromeHealthScore {
    param($Info)
    if (-not $Info.Installed) { return 0 }
    $score = 100
    if ($Info.CacheMB   -gt 1000) { $score -= 20 } elseif ($Info.CacheMB   -gt 500) { $score -= 10 }
    if ($Info.ProfileMB -gt 5000) { $score -= 15 } elseif ($Info.ProfileMB -gt 2000) { $score -= 7  }
    if ($Info.Processes -gt 20)   { $score -= 15 } elseif ($Info.Processes -gt 10)   { $score -= 5  }
    if ($Info.RAM       -gt 2048) { $score -= 10 } elseif ($Info.RAM       -gt 1024) { $score -= 5  }
    return [math]::Max(0, [math]::Min(100, $score))
}

function Get-ChromeFullInfo {
    $path        = Get-ChromeInstallPath
    $profilePath = Get-ChromeProfilePath
    $profiles    = Get-ChromeProfiles
    $procs       = Get-ChromeProcessInfo
    $cacheMB     = Get-FolderSizeMB (Join-Path $profilePath "Default\Cache")
    $profileMB   = Get-FolderSizeMB $profilePath

    $info = @{
        Installed  = ($null -ne $path)
        Path       = $path
        Version    = if ($path) { Get-ChromeVersion $path } else { "N/A" }
        ProfilePath= $profilePath
        Profiles   = @($profiles)
        ProfileCount = @($profiles).Count
        Processes  = $procs['Count']
        RAM        = $procs['RAM']
        CPU        = $procs['CPU']
        CacheMB    = $cacheMB
        ProfileMB  = $profileMB
    }
    $info.HealthScore = Get-ChromeHealthScore $info
    return $info
}
#endregion

#region === DIAGNÓSTICO ===
function Invoke-ChromeDiagnostics {
    Write-AppLog "Iniciando diagnóstico completo" -Level INFO
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $add = {
        param($check, $status, $detail)
        $results.Add([PSCustomObject]@{ Check = $check; Status = $status; Detail = $detail })
    }

    # Chrome instalado
    $chromePath = Get-ChromeInstallPath
    & $add "Chrome Instalado" $(if ($chromePath) { "OK" } else { "FALHA" }) $(if ($chromePath) { $chromePath } else { "Chrome não encontrado no sistema" })

    # Versão do Chrome
    if ($chromePath) {
        $ver = Get-ChromeVersion $chromePath
        & $add "Versão do Chrome" "INFO" $ver
    }

    # Perfil localizado
    $profilePath = Get-ChromeProfilePath
    & $add "Perfil Localizado" $(if (Test-Path $profilePath) { "OK" } else { "FALHA" }) $profilePath

    # Cache excessivo
    $cachePath = Join-Path $profilePath "Default\Cache"
    $cacheMB   = Get-FolderSizeMB $cachePath
    $cacheStatus = if ($cacheMB -gt 1000) { "ALERTA" } elseif ($cacheMB -gt 500) { "AVISO" } else { "OK" }
    & $add "Cache do Chrome" $cacheStatus "$cacheMB MB"

    # Histórico
    $histFile = Join-Path $profilePath "Default\History"
    $histMB   = if (Test-Path $histFile) { [math]::Round((Get-Item $histFile).Length / 1MB, 2) } else { 0 }
    & $add "Histórico de Navegação" $(if ($histMB -gt 100) { "AVISO" } else { "OK" }) "$histMB MB"

    # Extensões
    $extPath  = Join-Path $profilePath "Default\Extensions"
    $extCount = if (Test-Path $extPath) { @(Get-ChildItem $extPath -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
    & $add "Extensões Instaladas" $(if ($extCount -gt 20) { "AVISO" } else { "OK" }) "$extCount extensões"

    # Processos do Chrome
    $procs = Get-Process chrome -ErrorAction SilentlyContinue
    $procCount = @($procs).Count
    & $add "Processos Chrome" $(if ($procCount -gt 25) { "AVISO" } else { "OK" }) "$procCount processos em execução"

    # Conectividade
    $internet = $false
    try { $internet = (Test-Connection "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch { }
    & $add "Conectividade Internet" $(if ($internet) { "OK" } else { "FALHA" }) $(if ($internet) { "Conectado (DNS Google)" } else { "Sem conexão detectada" })

    # Espaço em disco
    try {
        $drive  = $env:SystemDrive.TrimEnd(':')
        $disk   = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            $totalGB = [math]::Round(($disk.Free + $disk.Used) / 1GB, 1)
            $status  = if ($freeGB -lt 5) { "ALERTA" } elseif ($freeGB -lt 10) { "AVISO" } else { "OK" }
            & $add "Espaço em Disco ($drive`:)" $status "$freeGB GB livres de $totalGB GB"
        }
    } catch { }

    # Memória RAM
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $status  = if ($freeGB -lt 1) { "ALERTA" } elseif ($freeGB -lt 2) { "AVISO" } else { "OK" }
            & $add "Memória RAM Disponível" $status "$freeGB GB livres de $totalGB GB"
        }
    } catch { }

    Write-AppLog "Diagnóstico concluído: $($results.Count) verificações" -Level INFO
    return $results
}

function New-DiagnosticReportHTML {
    <#
    .SYNOPSIS
        Gera relatório HTML do diagnóstico e retorna o caminho do arquivo.
    #>
    param([System.Collections.Generic.List[PSCustomObject]]$Results)

    $ts   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = "$($script:Dirs.Relatorios)\Diagnostico_$ts.html"

    $colorMap = @{
        OK     = '#a6e3a1'
        AVISO  = '#f9e2af'
        ALERTA = '#fab387'
        FALHA  = '#f38ba8'
        INFO   = '#89b4fa'
    }

    $rows = ($Results | ForEach-Object {
        $c = if ($colorMap.ContainsKey($_.Status)) { $colorMap[$_.Status] } else { '#cdd6f4' }
        "<tr><td>$($_.Check)</td><td style='color:$c;font-weight:600'>$($_.Status)</td><td>$($_.Detail)</td></tr>"
    }) -join "`n"

    $computer  = $env:COMPUTERNAME
    $user      = $env:USERNAME
    $dateStr   = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
    $appName   = $script:AppName
    $company   = $script:Company
    $version   = $script:Version

    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Relatório de Diagnóstico - $appName</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',sans-serif;background:#1e1e2e;color:#cdd6f4;padding:24px}
  header{margin-bottom:24px}
  h1{color:#89b4fa;font-size:22px;margin-bottom:4px}
  h2{color:#cba6f7;font-size:16px;font-weight:400;margin-bottom:12px}
  .meta{font-size:12px;color:#6c7086;margin-bottom:4px}
  table{width:100%;border-collapse:collapse;margin-top:16px}
  th{background:#313244;padding:10px 12px;text-align:left;font-size:13px;color:#89b4fa;border-bottom:2px solid #45475a}
  td{padding:8px 12px;font-size:13px;border-bottom:1px solid #313244}
  tr:hover td{background:#313244}
  footer{margin-top:24px;font-size:11px;color:#45475a}
</style>
</head>
<body>
<header>
  <h1>$appName</h1>
  <h2>$company</h2>
  <p class="meta">Data/Hora: $dateStr</p>
  <p class="meta">Computador: $computer &nbsp;|&nbsp; Usuário: $user</p>
  <p class="meta">Versão da ferramenta: v$version</p>
</header>
<table>
<thead><tr><th>Verificação</th><th>Status</th><th>Detalhe</th></tr></thead>
<tbody>
$rows
</tbody>
</table>
<footer><p>$appName v$version &mdash; $company &mdash; $dateStr</p></footer>
</body>
</html>
"@

    $html | Set-Content -Path $file -Encoding UTF8
    Write-AppLog "Relatório HTML gerado: $file" -Level INFO
    return $file
}
#endregion

#region === LIMPEZA ===
function Invoke-ChromeCleanup {
    <#
    .SYNOPSIS
        Executa limpeza seletiva dos dados do Chrome.
    #>
    [CmdletBinding()]
    param(
        [bool]$Cache     = $false,
        [bool]$Cookies   = $false,
        [bool]$History   = $false,
        [bool]$Downloads = $false,
        [bool]$SiteData  = $false,
        [bool]$TempFiles = $false
    )

    $profilePath = Get-ChromeProfilePath
    $chromeRunning = [bool](Get-Process chrome -ErrorAction SilentlyContinue)
    $results = [System.Collections.Generic.List[string]]::new()

    if ($Cache) {
        $cacheDirs = @(
            "$profilePath\Default\Cache",
            "$profilePath\Default\Code Cache",
            "$profilePath\Default\GPUCache",
            "$profilePath\Default\Service Worker\CacheStorage"
        )
        foreach ($cp in $cacheDirs) {
            if (Test-Path $cp) {
                $sizeBefore = Get-FolderSizeMB $cp
                try {
                    Get-ChildItem "$cp\*" -Recurse -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    $sizeAfter = Get-FolderSizeMB $cp
                    $freed = [math]::Round($sizeBefore - $sizeAfter, 1)
                    $results.Add("Cache limpo: $(Split-Path $cp -Leaf) - liberados $freed MB")
                    Write-AppLog "Cache limpo: $cp ($freed MB liberados)" -Level INFO
                } catch {
                    Write-AppLog "Erro ao limpar cache $cp`: $_" -Level ERROR
                }
            }
        }
    }

    if ($History -and -not $chromeRunning) {
        $histFile = "$profilePath\Default\History"
        if (Test-Path $histFile) {
            try {
                $sz = [math]::Round((Get-Item $histFile).Length / 1MB, 1)
                Remove-Item $histFile -Force
                $results.Add("Histórico removido ($sz MB)")
                Write-AppLog "Histórico removido ($sz MB)" -Level INFO
            } catch { Write-AppLog "Erro ao remover histórico: $_" -Level ERROR }
        }
    } elseif ($History -and $chromeRunning) {
        $results.Add("AVISO: Feche o Chrome para limpar o histórico.")
    }

    if ($Cookies -and -not $chromeRunning) {
        @("$profilePath\Default\Cookies", "$profilePath\Default\Network\Cookies") | ForEach-Object {
            if (Test-Path $_) {
                try {
                    Remove-Item $_ -Force
                    $results.Add("Cookies removidos: $(Split-Path $_ -Leaf)")
                    Write-AppLog "Cookies removidos: $_" -Level INFO
                } catch { Write-AppLog "Erro ao remover cookies: $_" -Level ERROR }
            }
        }
    } elseif ($Cookies -and $chromeRunning) {
        $results.Add("AVISO: Feche o Chrome para limpar os cookies.")
    }

    if ($SiteData -and -not $chromeRunning) {
        $siteDataPaths = @(
            "$profilePath\Default\Local Storage",
            "$profilePath\Default\IndexedDB",
            "$profilePath\Default\Session Storage"
        )
        foreach ($sd in $siteDataPaths) {
            if (Test-Path $sd) {
                try {
                    $sz = Get-FolderSizeMB $sd
                    Remove-Item "$sd\*" -Recurse -Force -ErrorAction SilentlyContinue
                    $results.Add("Dados de sites limpos: $(Split-Path $sd -Leaf) ($sz MB)")
                    Write-AppLog "Dados de sites limpos: $sd" -Level INFO
                } catch { }
            }
        }
    }

    if ($TempFiles) {
        Get-ChildItem $env:TEMP -Filter "*.tmp" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $results.Add("Arquivos temporários do sistema limpos")
        Write-AppLog "Arquivos temporários limpos" -Level INFO
    }

    if ($results.Count -eq 0) {
        $results.Add("Nenhum item foi processado. Verifique as seleções.")
    }

    return $results
}

function Invoke-SmartOptimization {
    Write-AppLog "Iniciando Otimização Inteligente" -Level INFO
    $results = Invoke-ChromeCleanup -Cache $true -TempFiles $true
    Write-AppLog "Otimização Inteligente concluída" -Level INFO
    return $results
}
#endregion

#region === BACKUP E RESTAURAÇÃO ===
function New-ChromeBackup {
    <#
    .SYNOPSIS
        Cria um backup do perfil do Chrome com Manifest e Inventário.
    #>
    [CmdletBinding()]
    param(
        [bool]$Bookmarks  = $true,
        [bool]$History    = $false,
        [bool]$Cookies    = $false,
        [bool]$Settings   = $true,
        [bool]$Extensions = $false
    )

    $ts        = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = "$($script:Dirs.BackupChrome)\$ts"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $profilePath = Get-ChromeProfilePath
    $copiedItems = [System.Collections.Generic.List[string]]::new()

    $map = @{
        Bookmarks  = @('Default\Bookmarks', 'Default\Bookmarks.bak')
        History    = @('Default\History')
        Cookies    = @('Default\Cookies', 'Default\Network\Cookies')
        Settings   = @('Default\Preferences', 'Default\Secure Preferences')
        Extensions = @('Default\Extensions', 'Default\Local Extension Settings')
    }

    $selected = [ordered]@{}
    if ($Bookmarks)  { $selected['Bookmarks']  = $map.Bookmarks  }
    if ($History)    { $selected['History']    = $map.History    }
    if ($Cookies)    { $selected['Cookies']    = $map.Cookies    }
    if ($Settings)   { $selected['Settings']   = $map.Settings   }
    if ($Extensions) { $selected['Extensions'] = $map.Extensions }

    foreach ($cat in $selected.Keys) {
        $catDir = "$backupDir\$cat"
        New-Item -ItemType Directory -Path $catDir -Force | Out-Null
        foreach ($rel in $selected[$cat]) {
            $src = Join-Path $profilePath $rel
            if (Test-Path $src) {
                $dst = Join-Path $catDir (Split-Path $rel -Leaf)
                try {
                    Copy-Item $src $dst -Recurse -Force
                    $copiedItems.Add($rel)
                } catch { Write-AppLog "Erro ao copiar $rel`: $_" -Level ERROR }
            }
        }
    }

    $chromePath = Get-ChromeInstallPath
    $chromeVer  = Get-ChromeVersion $chromePath

    $manifest = [ordered]@{
        AppName   = $script:AppName
        Company   = $script:Company
        Version   = $script:Version
        Timestamp = $ts
        Computer  = $env:COMPUTERNAME
        User      = $env:USERNAME
        ChromeVer = $chromeVer
        Items     = @($copiedItems)
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content "$backupDir\Manifest.json" -Encoding UTF8

    $profiles = Get-ChromeProfiles
    $inventory = [ordered]@{
        Computer  = $env:COMPUTERNAME
        User      = $env:USERNAME
        ChromeVer = $chromeVer
        Profiles  = @($profiles | ForEach-Object { $_.Name })
        Items     = @($copiedItems)
        Favoritos = if ($Bookmarks) { "Incluído" } else { "Não incluído" }
        Historico = if ($History)   { "Incluído" } else { "Não incluído" }
        Extensoes = if ($Extensions){ "Incluído" } else { "Não incluído" }
        Date      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    $inventory | ConvertTo-Json -Depth 5 | Set-Content "$backupDir\Inventario.json" -Encoding UTF8

    Write-AppLog "Backup criado: $backupDir ($($copiedItems.Count) itens)" -Level INFO
    return $backupDir
}

function Get-BackupList {
    $dirs = Get-ChildItem $script:Dirs.BackupChrome -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    return @($dirs | ForEach-Object {
        $manifestFile = Join-Path $_.FullName "Manifest.json"
        $mf = $null
        if (Test-Path $manifestFile) {
            try { $mf = Get-Content $manifestFile -Raw | ConvertFrom-Json } catch { }
        }
        [PSCustomObject]@{
            Name     = $_.Name
            Path     = $_.FullName
            Date     = $_.LastWriteTime.ToString('dd/MM/yyyy HH:mm')
            Manifest = $mf
        }
    })
}
#endregion

#region === CDP - GERENCIAMENTO DE ABAS ===
function Test-CDPAvailable {
    try {
        Invoke-RestMethod -Uri "http://localhost:9222/json/version" -TimeoutSec 2 -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Get-ChromeTabs {
    try {
        return (Invoke-RestMethod -Uri "http://localhost:9222/json" -TimeoutSec 3 -ErrorAction Stop)
    } catch { return $null }
}

function Close-ChromeTab {
    param([string]$TabId)
    try {
        Invoke-RestMethod -Uri "http://localhost:9222/json/close/$TabId" -TimeoutSec 3 -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}
#endregion

#region === ATENDIMENTO ===
function Start-Atendimento {
    [CmdletBinding()]
    param(
        [string]$Cliente,
        [string]$Empresa,
        [string]$Tecnico,
        [string]$Chamado,
        [string]$Observacoes
    )

    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeName   = $Cliente -replace '[^\w\-]', '_'
    $folderName = "${ts}_${safeName}"
    $atendDir   = Join-Path $script:Dirs.Atendimentos $folderName

    foreach ($sub in @('Logs','Diagnosticos','Relatorios','Backups')) {
        New-Item -ItemType Directory -Path (Join-Path $atendDir $sub) -Force | Out-Null
    }

    $script:CurrentAtendimento = [ordered]@{
        Cliente    = $Cliente
        Empresa    = $Empresa
        Tecnico    = $Tecnico
        Chamado    = $Chamado
        Observacoes= $Observacoes
        Inicio     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Path       = $atendDir
    }

    $script:CurrentAtendimento | ConvertTo-Json |
        Set-Content (Join-Path $atendDir "Atendimento.json") -Encoding UTF8

    Write-AppLog "Atendimento iniciado — Cliente: $Cliente | Chamado: $Chamado | Técnico: $Tecnico" -Level INFO
    return $atendDir
}

function Stop-Atendimento {
    [CmdletBinding()]
    param([bool]$CompactZip = $false)

    if (-not $script:CurrentAtendimento) { return }

    $atendDir = $script:CurrentAtendimento.Path

    # Copia log atual para a pasta do atendimento
    if (Test-Path $script:LogFile) {
        Copy-Item $script:LogFile (Join-Path $atendDir "Logs\") -Force -ErrorAction SilentlyContinue
    }

    if ($CompactZip) {
        $zipPath = "$atendDir.zip"
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($atendDir, $zipPath)
            Write-AppLog "Atendimento compactado: $zipPath" -Level INFO
        } catch {
            Write-AppLog "Erro ao compactar atendimento: $_" -Level ERROR
        }
    }

    Write-AppLog "Atendimento finalizado — Cliente: $($script:CurrentAtendimento.Cliente)" -Level INFO
    $script:CurrentAtendimento = $null
}
#endregion

#region === XAML DA INTERFACE ===
[xml]$script:XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Browser Diagnostic Manager - BR Suporte Informática"
        Height="800" Width="1200" MinHeight="640" MinWidth="960"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E2E">
  <Window.Resources>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#A6ADC8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="14,0,0,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Margin="6,2,6,2">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A3E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtnActive" TargetType="Button" BasedOn="{StaticResource NavBtn}">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Foreground" Value="#89B4FA"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#89B4FA"/>
      <Setter Property="Foreground" Value="#1E1E2E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#B4BEFE"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#45475A"/>
                <Setter Property="Foreground" Value="#585B70"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="Background" Value="#F38BA8"/>
    </Style>

    <Style x:Key="SuccessBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="Background" Value="#A6E3A1"/>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="Background" Value="#45475A"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="4"/>
    </Style>

    <Style x:Key="MetaLbl" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#6C7086"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>

    <Style x:Key="MetaVal" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
    </Style>

    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>

    <Style x:Key="FieldLbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,10,0,4"/>
    </Style>

    <Style x:Key="InputTxt" TargetType="TextBox">
      <Setter Property="Background" Value="#45475A"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="CaretBrush" Value="#89B4FA"/>
      <Setter Property="BorderBrush" Value="#585B70"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
    </Style>

    <Style x:Key="ChkStyle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,5"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="#313244"/>
      <Setter Property="AlternatingRowBackground" Value="#2D2D42"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#45475A"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#45475A"/>
      <Setter Property="Foreground" Value="#89B4FA"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#45475A"/>
      <Setter Property="Foreground" Value="#CDD6F4"/>
      <Setter Property="BorderBrush" Value="#585B70"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Width" Value="8"/>
    </Style>

  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="28"/>
    </Grid.RowDefinitions>

    <!-- ===== HEADER ===== -->
    <Border Grid.Row="0" Background="#181825" BorderBrush="#313244" BorderThickness="0,0,0,1">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse Width="36" Height="36" Margin="0,0,10,0">
            <Ellipse.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#89B4FA" Offset="0"/>
                <GradientStop Color="#CBA6F7" Offset="1"/>
              </LinearGradientBrush>
            </Ellipse.Fill>
          </Ellipse>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Browser Diagnostic Manager" FontSize="15" FontWeight="Bold" Foreground="#CDD6F4"/>
            <TextBlock Text="BR Suporte Informática" FontSize="11" Foreground="#6C7086"/>
          </StackPanel>
        </StackPanel>

        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#313244" CornerRadius="4" Padding="8,3" Margin="0,0,6,0">
            <TextBlock Text="v1.0.0" FontSize="11" Foreground="#89B4FA" FontWeight="SemiBold"/>
          </Border>
          <Border Background="#313244" CornerRadius="4" Padding="8,3" Margin="0,0,10,0">
            <TextBlock Text="Build 20260629" FontSize="11" Foreground="#6C7086"/>
          </Border>
          <Button x:Name="btnAtendimento" Content="▶  Iniciar Atendimento"
                  Style="{StaticResource SuccessBtn}" Height="30" FontSize="11" Padding="12,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ===== CORPO PRINCIPAL ===== -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="196"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- SIDEBAR -->
      <Border Grid.Column="0" Background="#181825" BorderBrush="#313244" BorderThickness="0,0,1,0">
        <StackPanel Margin="0,12,0,0">
          <TextBlock Text="NAVEGAÇÃO" FontSize="10" FontWeight="Bold" Foreground="#45475A"
                     Margin="18,0,0,8"/>
          <Button x:Name="btnNavDashboard"   Content="📊  Dashboard"         Style="{StaticResource NavBtnActive}"/>
          <Button x:Name="btnNavDiagnostico" Content="🔍  Diagnóstico"       Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavAbas"        Content="🗂  Gerenciar Abas"    Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavLimpeza"     Content="🧹  Limpeza"           Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavBackup"      Content="💾  Backup e Migração" Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavFerramentas" Content="🛠  Ferramentas"       Style="{StaticResource NavBtn}"/>
          <Separator Background="#313244" Margin="12,10"/>
          <Button x:Name="btnNavConfig"      Content="⚙  Configurações"     Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavLogs"        Content="📝  Logs"              Style="{StaticResource NavBtn}"/>
          <Button x:Name="btnNavSobre"       Content="ℹ  Sobre"             Style="{StaticResource NavBtn}"/>
        </StackPanel>
      </Border>

      <!-- ÁREA DE CONTEÚDO -->
      <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <Grid Margin="20,16,20,16">

          <!-- ══════════════════════════════════════ DASHBOARD ══════════════════════════════════════ -->
          <StackPanel x:Name="panelDashboard" Visibility="Visible">
            <TextBlock Text="Dashboard" Style="{StaticResource SectionTitle}"/>

            <!-- Linha 1: Status, Versão, Perfis, Health -->
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="STATUS CHROME" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblChromeStatus" Text="—" Style="{StaticResource MetaVal}" FontSize="16"/>
                  <TextBlock x:Name="lblChromePath" Text="" FontSize="10" Foreground="#585B70"
                             TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="VERSÃO" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblChromeVersion" Text="—" Style="{StaticResource MetaVal}" FontSize="15"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="PERFIS" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblProfileCount" Text="0" Style="{StaticResource MetaVal}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="HEALTH SCORE" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblHealthScore" Text="—%" Style="{StaticResource MetaVal}" Foreground="#A6E3A1"/>
                  <ProgressBar x:Name="pbHealth" Minimum="0" Maximum="100" Value="0" Height="6"
                               Margin="0,8,0,0" Background="#45475A" Foreground="#A6E3A1"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <!-- Linha 2: Processos, RAM, Perfil, Cache -->
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="PROCESSOS" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblProcessCount" Text="0" Style="{StaticResource MetaVal}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="RAM CHROME (MB)" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblRAM" Text="0" Style="{StaticResource MetaVal}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="TAMANHO PERFIL" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblProfileSize" Text="0 MB" Style="{StaticResource MetaVal}" FontSize="16"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="CACHE" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblCacheSize" Text="0 MB" Style="{StaticResource MetaVal}" FontSize="16"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <!-- Linha 3: CPU, Runtime -->
            <UniformGrid Columns="2">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="CPU CHROME (total proc)" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblCPU" Text="0 s" Style="{StaticResource MetaVal}" FontSize="16"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="TEMPO DE EXECUÇÃO DA FERRAMENTA" Style="{StaticResource MetaLbl}"/>
                  <TextBlock x:Name="lblRuntime" Text="00:00:00" Style="{StaticResource MetaVal}" FontSize="16"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <!-- Perfis detectados -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Perfis Detectados" FontSize="13" FontWeight="SemiBold"
                           Foreground="#CDD6F4" Margin="0,0,0,8"/>
                <ListBox x:Name="listProfiles" Height="90">
                  <ListBox.ItemTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="👤 " FontSize="12"/>
                        <TextBlock Text="{Binding Name}" FontSize="12"/>
                        <TextBlock Text=" — " FontSize="12" Foreground="#6C7086"/>
                        <TextBlock Text="{Binding Directory}" FontSize="11" Foreground="#585B70"/>
                      </StackPanel>
                    </DataTemplate>
                  </ListBox.ItemTemplate>
                </ListBox>
              </StackPanel>
            </Border>

            <StackPanel Orientation="Horizontal" Margin="4,4,0,0">
              <Button x:Name="btnRefreshDash" Content="↺  Atualizar Agora" Style="{StaticResource PrimaryBtn}" Margin="0,0,10,0"/>
              <TextBlock x:Name="lblLastUpdate" Text="Última atualização: —" FontSize="11"
                         Foreground="#6C7086" VerticalAlignment="Center"/>
            </StackPanel>
          </StackPanel>

          <!-- ══════════════════════════════════════ DIAGNÓSTICO ══════════════════════════════════════ -->
          <StackPanel x:Name="panelDiagnostico" Visibility="Collapsed">
            <TextBlock Text="Diagnóstico do Chrome" Style="{StaticResource SectionTitle}"/>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Foreground="#6C7086" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,14"
                           Text="Execute uma verificação completa do Chrome. O resultado é exibido na tabela abaixo e um relatório HTML é gerado automaticamente em Relatorios\."/>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="btnRunDiag"    Content="▶  Executar Diagnóstico"  Style="{StaticResource PrimaryBtn}" Margin="0,0,8,0"/>
                  <Button x:Name="btnOpenReport" Content="🌐  Abrir Relatório HTML" Style="{StaticResource GhostBtn}"   IsEnabled="False"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <DataGrid x:Name="gridDiag" Height="380" IsReadOnly="True">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Verificação" Binding="{Binding Check}"  Width="240"/>
                  <DataGridTextColumn Header="Status"      Binding="{Binding Status}" Width="90"/>
                  <DataGridTextColumn Header="Detalhe"     Binding="{Binding Detail}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </StackPanel>

          <!-- ══════════════════════════════════════ ABAS CDP ══════════════════════════════════════ -->
          <StackPanel x:Name="panelAbas" Visibility="Collapsed">
            <TextBlock Text="Gerenciamento de Abas" Style="{StaticResource SectionTitle}"/>

            <Border Style="{StaticResource Card}" Background="#2A2A1E">
              <StackPanel>
                <TextBlock Foreground="#F9E2AF" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,4">
                  ⚠  Requisito: Chrome com DevTools Protocol habilitado
                </TextBlock>
                <TextBlock Foreground="#6C7086" FontSize="11" FontFamily="Consolas"
                           Text="Inicie o Chrome com:  chrome.exe --remote-debugging-port=9222"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                  <Button x:Name="btnRefreshTabs"      Content="↺  Listar Abas"          Style="{StaticResource PrimaryBtn}" Margin="0,0,8,0"/>
                  <Button x:Name="btnSelectAllTabs"    Content="☑  Selecionar Todas"      Style="{StaticResource GhostBtn}"   Margin="0,0,8,0"/>
                  <Button x:Name="btnCloseSelectedTabs" Content="✕  Fechar Selecionadas"  Style="{StaticResource DangerBtn}"  Margin="0,0,8,0"/>
                  <Button x:Name="btnCloseAllTabs"     Content="✕✕  Fechar Todas"         Style="{StaticResource DangerBtn}"/>
                </StackPanel>

                <Border x:Name="borderCDPWarn" Background="#3D1A1A" CornerRadius="6"
                        Padding="12,8" Margin="0,0,0,10" Visibility="Collapsed">
                  <TextBlock Foreground="#F38BA8" TextWrapping="Wrap"
                             Text="❌  Chrome DevTools Protocol indisponível. Inicie o Chrome com --remote-debugging-port=9222 e clique em Listar Abas novamente."/>
                </Border>

                <DataGrid x:Name="gridTabs" Height="380" IsReadOnly="False"
                          CanUserAddRows="False" SelectionMode="Extended">
                  <DataGrid.Columns>
                    <DataGridCheckBoxColumn Header="✓" Binding="{Binding Selected, UpdateSourceTrigger=PropertyChanged}" Width="40"/>
                    <DataGridTextColumn Header="Título" Binding="{Binding title}" Width="320" IsReadOnly="True"/>
                    <DataGridTextColumn Header="URL"    Binding="{Binding url}"   Width="*"   IsReadOnly="True"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ══════════════════════════════════════ LIMPEZA ══════════════════════════════════════ -->
          <StackPanel x:Name="panelLimpeza" Visibility="Collapsed">
            <TextBlock Text="Limpeza do Chrome" Style="{StaticResource SectionTitle}"/>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Selecione o que deseja limpar:" FontSize="13" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,12"/>
                  <CheckBox x:Name="chkClnCache"     Content="Cache do Chrome"                      Style="{StaticResource ChkStyle}" IsChecked="True"/>
                  <CheckBox x:Name="chkClnCookies"   Content="Cookies"                              Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkClnHistory"   Content="Histórico de navegação"               Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkClnDownloads" Content="Histórico de downloads"               Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkClnSiteData"  Content="Dados dos sites (localStorage, IDB)"  Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkClnTempFiles" Content="Arquivos temporários do sistema"      Style="{StaticResource ChkStyle}"/>

                  <Border Background="#2A2010" CornerRadius="6" Padding="10,8" Margin="0,14,0,0">
                    <TextBlock Foreground="#F9E2AF" FontSize="11" TextWrapping="Wrap"
                               Text="⚠ Para limpar histórico, cookies e dados dos sites o Chrome deve estar fechado."/>
                  </Border>

                  <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                    <Button x:Name="btnRunCleanup"    Content="🧹  Executar Limpeza"         Style="{StaticResource DangerBtn}"  Margin="0,0,8,0"/>
                    <Button x:Name="btnSmartOptimize" Content="⚡  Otimização Inteligente"  Style="{StaticResource SuccessBtn}"/>
                  </StackPanel>
                </StackPanel>
              </Border>

              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Resultado" FontSize="13" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,8"/>
                  <TextBox x:Name="txtCleanupResult" Background="#1E1E2E" Foreground="#A6E3A1"
                           BorderThickness="0" IsReadOnly="True" Height="260"
                           VerticalScrollBarVisibility="Auto" FontFamily="Consolas"
                           TextWrapping="Wrap" FontSize="12" Padding="4"/>
                </StackPanel>
              </Border>
            </Grid>
          </StackPanel>

          <!-- ══════════════════════════════════════ BACKUP ══════════════════════════════════════ -->
          <StackPanel x:Name="panelBackup" Visibility="Collapsed">
            <TextBlock Text="Backup e Migração" Style="{StaticResource SectionTitle}"/>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <!-- Criar backup -->
              <Border Grid.Column="0" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Criar Backup" FontSize="14" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,12"/>
                  <CheckBox x:Name="chkBkpBookmarks"  Content="Favoritos"     Style="{StaticResource ChkStyle}" IsChecked="True"/>
                  <CheckBox x:Name="chkBkpHistory"    Content="Histórico"     Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkBkpCookies"    Content="Cookies"       Style="{StaticResource ChkStyle}"/>
                  <CheckBox x:Name="chkBkpSettings"   Content="Configurações" Style="{StaticResource ChkStyle}" IsChecked="True"/>
                  <CheckBox x:Name="chkBkpExtensions" Content="Extensões"     Style="{StaticResource ChkStyle}"/>
                  <Button x:Name="btnCreateBackup" Content="💾  Criar Backup Agora"
                          Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left"
                          Margin="0,16,0,0" Width="190"/>
                </StackPanel>
              </Border>

              <!-- Lista de backups -->
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Backups Disponíveis" FontSize="14" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,8"/>
                  <ListBox x:Name="listBackups" Height="180">
                    <ListBox.ItemTemplate>
                      <DataTemplate>
                        <StackPanel Margin="0,2">
                          <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="SemiBold"/>
                          <TextBlock Text="{Binding Date}" FontSize="10" Foreground="#6C7086"/>
                        </StackPanel>
                      </DataTemplate>
                    </ListBox.ItemTemplate>
                  </ListBox>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <Button x:Name="btnRefreshBackups" Content="↺ Atualizar"   Style="{StaticResource GhostBtn}"   Height="28" FontSize="11" Padding="10,0" Margin="0,0,6,0"/>
                    <Button x:Name="btnRestoreBackup"  Content="↩ Restaurar"   Style="{StaticResource SuccessBtn}" Height="28" FontSize="11" Padding="10,0"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </Grid>

            <Border Style="{StaticResource Card}">
              <TextBlock x:Name="lblBackupResult" Text="Aguardando operação…"
                         Foreground="#6C7086" FontSize="12" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>

          <!-- ══════════════════════════════════════ FERRAMENTAS ══════════════════════════════════════ -->
          <StackPanel x:Name="panelFerramentas" Visibility="Collapsed">
            <TextBlock Text="Ferramentas" Style="{StaticResource SectionTitle}"/>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="📁  Atalhos de Pastas" FontSize="14" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,14"/>
                  <Button x:Name="btnOpenProfile"   Content="📁  Pasta do Perfil"   Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnOpenCache"     Content="📁  Cache do Chrome"   Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnOpenDownloads" Content="📁  Downloads"         Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnOpenLogs"      Content="📁  Logs da Ferramenta" Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnOpenBackups"   Content="📁  Backups"           Style="{StaticResource PrimaryBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="🌐  Páginas Internas do Chrome" FontSize="14" FontWeight="SemiBold"
                             Foreground="#CDD6F4" Margin="0,0,0,14"/>
                  <Button x:Name="btnChromeSettings"   Content="⚙  chrome://settings"    Style="{StaticResource GhostBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnChromeExtensions" Content="🧩  chrome://extensions"  Style="{StaticResource GhostBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnChromeHistory"    Content="📜  chrome://history"     Style="{StaticResource GhostBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnChromeDownloads"  Content="⬇  chrome://downloads"   Style="{StaticResource GhostBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                  <Button x:Name="btnChromeVersion"    Content="ℹ  chrome://version"     Style="{StaticResource GhostBtn}" HorizontalAlignment="Left" Margin="0,4" Width="220"/>
                </StackPanel>
              </Border>
            </Grid>
          </StackPanel>

          <!-- ══════════════════════════════════════ CONFIGURAÇÕES ══════════════════════════════════════ -->
          <StackPanel x:Name="panelConfig" Visibility="Collapsed">
            <TextBlock Text="Configurações" Style="{StaticResource SectionTitle}"/>

            <Border Style="{StaticResource Card}">
              <StackPanel MaxWidth="480" HorizontalAlignment="Left">
                <TextBlock Text="Configurações Gerais" FontSize="14" FontWeight="SemiBold"
                           Foreground="#CDD6F4" Margin="0,0,0,16"/>

                <TextBlock Text="Tema:" Style="{StaticResource FieldLbl}"/>
                <ComboBox x:Name="cmbTheme">
                  <ComboBoxItem Content="Dark" IsSelected="True"/>
                  <ComboBoxItem Content="Light"/>
                </ComboBox>

                <TextBlock Text="Idioma:" Style="{StaticResource FieldLbl}"/>
                <ComboBox x:Name="cmbLanguage">
                  <ComboBoxItem Content="pt-BR" IsSelected="True"/>
                  <ComboBoxItem Content="en-US"/>
                </ComboBox>

                <CheckBox x:Name="chkAutoRefresh" Content="Atualização automática do Dashboard (a cada 3 segundos)"
                          Style="{StaticResource ChkStyle}" IsChecked="True" Margin="0,14,0,0"/>

                <TextBlock Text="Diretório Base:" Style="{StaticResource FieldLbl}"/>
                <TextBox x:Name="txtBaseDir" Style="{StaticResource InputTxt}" Text="C:\Inst\Navegadores"/>

                <Button x:Name="btnSaveConfig" Content="✔  Salvar Configurações"
                        Style="{StaticResource SuccessBtn}" HorizontalAlignment="Left"
                        Margin="0,20,0,0" Width="210"/>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ══════════════════════════════════════ LOGS ══════════════════════════════════════ -->
          <StackPanel x:Name="panelLogs" Visibility="Collapsed">
            <TextBlock Text="Logs do Sistema" Style="{StaticResource SectionTitle}"/>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="btnRefreshLogs"  Content="↺  Atualizar"           Style="{StaticResource PrimaryBtn}" Margin="0,0,8,0"/>
                  <Button x:Name="btnClearLogsUI"  Content="🗑  Limpar Exibição"     Style="{StaticResource GhostBtn}"   Margin="0,0,8,0"/>
                  <Button x:Name="btnOpenLogFile"  Content="📂  Abrir Arquivo de Log" Style="{StaticResource GhostBtn}"/>
                </StackPanel>
                <TextBox x:Name="txtLogs" Background="#11111B" Foreground="#A6E3A1"
                         BorderThickness="0" IsReadOnly="True" Height="480"
                         VerticalScrollBarVisibility="Auto" FontFamily="Consolas"
                         TextWrapping="Wrap" FontSize="11" Padding="8"/>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- ══════════════════════════════════════ SOBRE ══════════════════════════════════════ -->
          <StackPanel x:Name="panelSobre" Visibility="Collapsed">
            <TextBlock Text="Sobre" Style="{StaticResource SectionTitle}"/>

            <Border Style="{StaticResource Card}">
              <StackPanel HorizontalAlignment="Center" Margin="0,30">
                <Ellipse Width="80" Height="80" HorizontalAlignment="Center" Margin="0,0,0,16">
                  <Ellipse.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#89B4FA" Offset="0"/>
                      <GradientStop Color="#CBA6F7" Offset="1"/>
                    </LinearGradientBrush>
                  </Ellipse.Fill>
                </Ellipse>

                <TextBlock Text="Browser Diagnostic Manager" FontSize="22" FontWeight="Bold"
                           Foreground="#89B4FA" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                <TextBlock Text="BR Suporte Informática" FontSize="15" Foreground="#CBA6F7"
                           HorizontalAlignment="Center" Margin="0,0,0,6"/>
                <TextBlock Text="Versão 1.0.0  |  Build 20260629" FontSize="12"
                           Foreground="#6C7086" HorizontalAlignment="Center" Margin="0,0,0,24"/>

                <Separator Background="#45475A" Margin="80,0"/>

                <TextBlock HorizontalAlignment="Center" Margin="0,20,0,6" Foreground="#CDD6F4"
                           FontSize="13" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="500">
                  Ferramenta profissional de diagnóstico, manutenção, backup,
                  restauração e otimização de navegadores.
                  Desenvolvida exclusivamente para uso interno da BR Suporte Informática.
                </TextBlock>

                <TextBlock HorizontalAlignment="Center" Margin="0,12" Foreground="#6C7086"
                           FontSize="11" TextAlignment="Center">
                  Desenvolvido em PowerShell 5.1+ com WPF
                  <LineBreak/>Compatível com Windows 10 e Windows 11
                  <LineBreak/>Sem dependências externas
                </TextBlock>

                <TextBlock HorizontalAlignment="Center" Margin="0,20,0,0" Foreground="#45475A"
                           FontSize="11" Text="© 2026 BR Suporte Informática. Todos os direitos reservados."/>
              </StackPanel>
            </Border>
          </StackPanel>

        </Grid>
      </ScrollViewer>
    </Grid>

    <!-- ===== STATUS BAR ===== -->
    <Border Grid.Row="2" Background="#181825" BorderBrush="#313244" BorderThickness="0,1,0,0">
      <Grid Margin="14,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="sbChrome"  Text="Chrome: —"  FontSize="11" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,20,0"/>
        <TextBlock Grid.Column="1" x:Name="sbProfile" Text="Perfil: —"  FontSize="11" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,20,0"/>
        <TextBlock Grid.Column="2" x:Name="sbConfig"  Text="Config: OK" FontSize="11" Foreground="#6C7086" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="4" x:Name="sbTime"    Text="—"          FontSize="11" Foreground="#6C7086" VerticalAlignment="Center"/>
      </Grid>
    </Border>

  </Grid>
</Window>
'@
#endregion

#region === AUXILIARES DE UI ===
function Show-Panel {
    param([string]$PanelName)

    $all = @('panelDashboard','panelDiagnostico','panelAbas','panelLimpeza',
             'panelBackup','panelFerramentas','panelConfig','panelLogs','panelSobre')

    foreach ($p in $all) {
        ($script:Window.FindName($p)).Visibility = [System.Windows.Visibility]::Collapsed
    }
    ($script:Window.FindName($PanelName)).Visibility = [System.Windows.Visibility]::Visible

    # Realça botão ativo
    $navMap = @{
        panelDashboard   = 'btnNavDashboard'
        panelDiagnostico = 'btnNavDiagnostico'
        panelAbas        = 'btnNavAbas'
        panelLimpeza     = 'btnNavLimpeza'
        panelBackup      = 'btnNavBackup'
        panelFerramentas = 'btnNavFerramentas'
        panelConfig      = 'btnNavConfig'
        panelLogs        = 'btnNavLogs'
        panelSobre       = 'btnNavSobre'
    }

    $activeStyle = $script:Window.Resources['NavBtnActive']
    $normalStyle = $script:Window.Resources['NavBtn']

    foreach ($panel in $navMap.Keys) {
        $btn = $script:Window.FindName($navMap[$panel])
        if ($btn) { $btn.Style = if ($panel -eq $PanelName) { $activeStyle } else { $normalStyle } }
    }
}

function Update-Dashboard {
    try {
        $info = Get-ChromeFullInfo

        $script:Window.Dispatcher.InvokeAsync([Action]{
            try {
                $cv = $script:Window.FindName('lblChromeStatus')
                if ($info.Installed) {
                    $cv.Text       = "✔ Instalado"
                    $cv.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6E3A1')
                } else {
                    $cv.Text       = "✗ Não encontrado"
                    $cv.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F38BA8')
                }

                $script:Window.FindName('lblChromePath').Text    = $info.Path
                $script:Window.FindName('lblChromeVersion').Text = $info.Version
                $script:Window.FindName('lblProfileCount').Text  = $info.ProfileCount
                $script:Window.FindName('lblProcessCount').Text  = $info.Processes
                $script:Window.FindName('lblRAM').Text           = "$($info.RAM) MB"
                $script:Window.FindName('lblCPU').Text           = "$($info.CPU) s"
                $script:Window.FindName('lblProfileSize').Text   = "$($info.ProfileMB) MB"
                $script:Window.FindName('lblCacheSize').Text     = "$($info.CacheMB) MB"

                $hs   = $info.HealthScore
                $hCtrl = $script:Window.FindName('lblHealthScore')
                $hCtrl.Text = "$hs%"
                $hColor = if ($hs -ge 80) { '#A6E3A1' } elseif ($hs -ge 60) { '#F9E2AF' } else { '#F38BA8' }
                $hCtrl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hColor)
                $script:Window.FindName('pbHealth').Value = $hs

                $elapsed = (Get-Date) - $script:StartTime
                $script:Window.FindName('lblRuntime').Text     = $elapsed.ToString('hh\:mm\:ss')
                $script:Window.FindName('listProfiles').ItemsSource = @($info.Profiles)
                $script:Window.FindName('lblLastUpdate').Text  = "Última atualização: $(Get-Date -Format 'HH:mm:ss')"

                $script:Window.FindName('sbChrome').Text  = "Chrome: $(if($info.Installed){'OK'}else{'Ausente'})"
                $script:Window.FindName('sbProfile').Text = "Perfil: $($info.ProfileCount) perfil(is)"
                $script:Window.FindName('sbTime').Text    = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
            } catch { }
        }) | Out-Null
    } catch {
        Write-AppLog "Erro ao atualizar Dashboard: $_" -Level ERROR
    }
}
#endregion

#region === DIÁLOGO DE ATENDIMENTO ===
function Show-AtendimentoDialog {
    [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Iniciar Atendimento" Height="430" Width="480"
        WindowStartupLocation="CenterOwner" Background="#1E1E2E"
        ResizeMode="NoResize">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Novo Atendimento" FontSize="18" FontWeight="Bold"
               Foreground="#89B4FA" Margin="0,0,0,20"/>

    <StackPanel Grid.Row="1">
      <TextBlock Text="Cliente *"       Foreground="#CDD6F4" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="txtCliente"     Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70"
               Height="34" Padding="8,6" FontSize="13" Margin="0,0,0,10"/>

      <TextBlock Text="Empresa"         Foreground="#CDD6F4" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="txtEmpresa"     Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70"
               Height="34" Padding="8,6" FontSize="13" Margin="0,0,0,10"/>

      <TextBlock Text="Técnico *"       Foreground="#CDD6F4" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="txtTecnico"     Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70"
               Height="34" Padding="8,6" FontSize="13" Margin="0,0,0,10"/>

      <TextBlock Text="N° do Chamado"   Foreground="#CDD6F4" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="txtChamado"     Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70"
               Height="34" Padding="8,6" FontSize="13" Margin="0,0,0,10"/>

      <TextBlock Text="Observações"     Foreground="#CDD6F4" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="txtObs"         Background="#45475A" Foreground="#CDD6F4" BorderBrush="#585B70"
               Height="60" Padding="8,6" FontSize="13" TextWrapping="Wrap" AcceptsReturn="True"/>
    </StackPanel>

    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="btnCancel"  Content="Cancelar" Width="100" Height="34" Margin="0,0,8,0"
              Background="#45475A" Foreground="#CDD6F4" BorderThickness="0" Cursor="Hand"/>
      <Button x:Name="btnConfirm" Content="Iniciar"  Width="100" Height="34"
              Background="#89B4FA" Foreground="#1E1E2E" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($dlgXaml)
    $dlg    = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $script:Window

    $dlg.FindName('btnCancel').Add_Click({ $dlg.Close() })
    $dlg.FindName('btnConfirm').Add_Click({
        $cliente = $dlg.FindName('txtCliente').Text.Trim()
        $tecnico = $dlg.FindName('txtTecnico').Text.Trim()
        if (-not $cliente -or -not $tecnico) {
            [System.Windows.MessageBox]::Show("Preencha os campos obrigatórios: Cliente e Técnico.", "Campos obrigatórios")
            return
        }
        $dlg.Tag = @{
            Cliente    = $cliente
            Empresa    = $dlg.FindName('txtEmpresa').Text.Trim()
            Tecnico    = $tecnico
            Chamado    = $dlg.FindName('txtChamado').Text.Trim()
            Observacoes= $dlg.FindName('txtObs').Text.Trim()
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    })

    if ($dlg.ShowDialog() -eq $true) { return $dlg.Tag }
    return $null
}
#endregion

#region === INICIALIZAÇÃO DA JANELA ===
function Initialize-Window {
    $reader         = [System.Xml.XmlNodeReader]::new($script:XAML)
    $script:Window  = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:LogTextBox = $script:Window.FindName('txtLogs')

    #-- Navegação --
    $script:Window.FindName('btnNavDashboard').Add_Click({
        Show-Panel 'panelDashboard'; Update-Dashboard
    })
    $script:Window.FindName('btnNavDiagnostico').Add_Click({
        Show-Panel 'panelDiagnostico'
    })
    $script:Window.FindName('btnNavAbas').Add_Click({
        Show-Panel 'panelAbas'
    })
    $script:Window.FindName('btnNavLimpeza').Add_Click({
        Show-Panel 'panelLimpeza'
    })
    $script:Window.FindName('btnNavBackup').Add_Click({
        Show-Panel 'panelBackup'
        $bks = Get-BackupList
        $script:Window.FindName('listBackups').ItemsSource = @($bks)
    })
    $script:Window.FindName('btnNavFerramentas').Add_Click({
        Show-Panel 'panelFerramentas'
    })
    $script:Window.FindName('btnNavConfig').Add_Click({
        Show-Panel 'panelConfig'
        $cfg = Get-AppConfig
        if ($cfg) {
            try {
                $arCtrl = $script:Window.FindName('chkAutoRefresh')
                $arCtrl.IsChecked = if ($null -ne $cfg.AutoRefresh) { [bool]$cfg.AutoRefresh } else { $true }
                $bdCtrl = $script:Window.FindName('txtBaseDir')
                if ($cfg.BaseDir) { $bdCtrl.Text = $cfg.BaseDir }
            } catch { }
        }
    })
    $script:Window.FindName('btnNavLogs').Add_Click({
        Show-Panel 'panelLogs'
        if (Test-Path $script:LogFile) {
            $script:Window.FindName('txtLogs').Text =
                (Get-Content $script:LogFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            $script:Window.FindName('txtLogs').ScrollToEnd()
        }
    })
    $script:Window.FindName('btnNavSobre').Add_Click({ Show-Panel 'panelSobre' })

    #-- Dashboard --
    $script:Window.FindName('btnRefreshDash').Add_Click({ Update-Dashboard })

    #-- Diagnóstico --
    $script:Window.FindName('btnRunDiag').Add_Click({
        $btn = $script:Window.FindName('btnRunDiag')
        $btn.IsEnabled = $false
        $btn.Content   = "Executando…"
        try {
            $results = Invoke-ChromeDiagnostics
            $script:Window.FindName('gridDiag').ItemsSource = $results

            $reportFile = New-DiagnosticReportHTML -Results $results
            $script:LastDiagnosticReport = $reportFile

            $openBtn = $script:Window.FindName('btnOpenReport')
            $openBtn.IsEnabled = $true
        } catch {
            Write-AppLog "Erro no diagnóstico: $_" -Level ERROR
            [System.Windows.MessageBox]::Show("Erro ao executar diagnóstico: $_", "Erro")
        } finally {
            $btn.IsEnabled = $true
            $btn.Content   = "▶  Executar Diagnóstico"
        }
    })

    $script:Window.FindName('btnOpenReport').Add_Click({
        if ($script:LastDiagnosticReport -and (Test-Path $script:LastDiagnosticReport)) {
            Start-Process $script:LastDiagnosticReport
        }
    })

    #-- Abas CDP --
    $script:Window.FindName('btnRefreshTabs').Add_Click({
        $warnBorder = $script:Window.FindName('borderCDPWarn')
        $grid       = $script:Window.FindName('gridTabs')

        if (-not (Test-CDPAvailable)) {
            $warnBorder.Visibility = [System.Windows.Visibility]::Visible
            $grid.ItemsSource = $null
            return
        }
        $warnBorder.Visibility = [System.Windows.Visibility]::Collapsed

        $tabs = Get-ChromeTabs
        if ($tabs) {
            $items = $tabs | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'Selected' -NotePropertyValue $false -Force -PassThru
            }
            $grid.ItemsSource = @($items)
            Write-AppLog "Abas listadas via CDP: $($tabs.Count)" -Level INFO
        }
    })

    $script:Window.FindName('btnSelectAllTabs').Add_Click({
        $grid = $script:Window.FindName('gridTabs')
        if ($grid.ItemsSource) {
            foreach ($item in $grid.ItemsSource) { $item.Selected = $true }
            $grid.Items.Refresh()
        }
    })

    $script:Window.FindName('btnCloseSelectedTabs').Add_Click({
        $grid = $script:Window.FindName('gridTabs')
        if (-not $grid.ItemsSource) { return }
        $toClose = @($grid.ItemsSource | Where-Object { $_.Selected })
        foreach ($tab in $toClose) {
            Close-ChromeTab $tab.id | Out-Null
            Write-AppLog "Aba fechada via CDP: $($tab.title)" -Level INFO
        }
        Start-Sleep -Milliseconds 600

        # Re-lista abas
        $tabs = Get-ChromeTabs
        if ($tabs) {
            $items = $tabs | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'Selected' -NotePropertyValue $false -Force -PassThru
            }
            $grid.ItemsSource = @($items)
        }
    })

    $script:Window.FindName('btnCloseAllTabs').Add_Click({
        $r = [System.Windows.MessageBox]::Show(
            "Fechar TODAS as abas abertas no Chrome?", "Confirmar",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $grid = $script:Window.FindName('gridTabs')
        if ($grid.ItemsSource) {
            foreach ($tab in $grid.ItemsSource) { Close-ChromeTab $tab.id | Out-Null }
            Write-AppLog "Todas as abas fechadas via CDP" -Level INFO
            Start-Sleep -Milliseconds 600
            $grid.ItemsSource = $null
        }
    })

    #-- Limpeza --
    $script:Window.FindName('btnRunCleanup').Add_Click({
        $r = [System.Windows.MessageBox]::Show(
            "Executar limpeza com as opções selecionadas?", "Confirmar Limpeza",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $txt = $script:Window.FindName('txtCleanupResult')
        $txt.Text = "Executando limpeza…`n"

        $params = @{
            Cache     = [bool]$script:Window.FindName('chkClnCache').IsChecked
            Cookies   = [bool]$script:Window.FindName('chkClnCookies').IsChecked
            History   = [bool]$script:Window.FindName('chkClnHistory').IsChecked
            Downloads = [bool]$script:Window.FindName('chkClnDownloads').IsChecked
            SiteData  = [bool]$script:Window.FindName('chkClnSiteData').IsChecked
            TempFiles = [bool]$script:Window.FindName('chkClnTempFiles').IsChecked
        }

        $results = Invoke-ChromeCleanup @params
        $txt.Text = ($results -join "`n")
        Update-Dashboard
    })

    $script:Window.FindName('btnSmartOptimize').Add_Click({
        $txt = $script:Window.FindName('txtCleanupResult')
        $txt.Text = "Executando Otimização Inteligente…"
        $results = Invoke-SmartOptimization
        $txt.Text = "✔ Otimização Inteligente concluída:`n" + ($results -join "`n")
        Update-Dashboard
    })

    #-- Backup --
    $script:Window.FindName('btnCreateBackup').Add_Click({
        $btn = $script:Window.FindName('btnCreateBackup')
        $btn.IsEnabled = $false
        $btn.Content   = "Criando…"
        try {
            $bkDir = New-ChromeBackup `
                -Bookmarks  ([bool]$script:Window.FindName('chkBkpBookmarks').IsChecked)  `
                -History    ([bool]$script:Window.FindName('chkBkpHistory').IsChecked)    `
                -Cookies    ([bool]$script:Window.FindName('chkBkpCookies').IsChecked)    `
                -Settings   ([bool]$script:Window.FindName('chkBkpSettings').IsChecked)   `
                -Extensions ([bool]$script:Window.FindName('chkBkpExtensions').IsChecked)

            $lbl = $script:Window.FindName('lblBackupResult')
            $lbl.Text       = "✔ Backup criado: $bkDir"
            $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6E3A1')
            [System.Windows.MessageBox]::Show("Backup criado com sucesso!`n$bkDir", "Backup Concluído")

            $bks = Get-BackupList
            $script:Window.FindName('listBackups').ItemsSource = @($bks)
        } catch {
            Write-AppLog "Erro ao criar backup: $_" -Level ERROR
            $lbl = $script:Window.FindName('lblBackupResult')
            $lbl.Text       = "✗ Erro ao criar backup: $_"
            $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F38BA8')
        } finally {
            $btn.IsEnabled = $true
            $btn.Content   = "💾  Criar Backup Agora"
        }
    })

    $script:Window.FindName('btnRefreshBackups').Add_Click({
        $script:Window.FindName('listBackups').ItemsSource = @(Get-BackupList)
    })

    $script:Window.FindName('btnRestoreBackup').Add_Click({
        $sel = $script:Window.FindName('listBackups').SelectedItem
        if (-not $sel) {
            [System.Windows.MessageBox]::Show("Selecione um backup da lista.","Aviso")
            return
        }
        $r = [System.Windows.MessageBox]::Show(
            "Restaurar backup de $($sel.Date)?`nAlguns dados atuais podem ser substituídos.",
            "Confirmar Restauração",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }

        try {
            $profilePath = Get-ChromeProfilePath
            $bkPath      = $sel.Path

            $itemMap = @{
                'Bookmarks\Bookmarks'   = 'Default\Bookmarks'
                'Settings\Preferences'  = 'Default\Preferences'
            }
            foreach ($src in $itemMap.Keys) {
                $srcFull = Join-Path $bkPath $src
                $dstFull = Join-Path $profilePath $itemMap[$src]
                if (Test-Path $srcFull) {
                    Copy-Item $srcFull $dstFull -Force
                    Write-AppLog "Restaurado: $src" -Level INFO
                }
            }

            $lbl = $script:Window.FindName('lblBackupResult')
            $lbl.Text       = "✔ Backup restaurado com sucesso em: $(Get-Date -Format 'HH:mm:ss')"
            $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6E3A1')
            [System.Windows.MessageBox]::Show("Restauração concluída com sucesso!", "Restauração")
        } catch {
            Write-AppLog "Erro na restauração: $_" -Level ERROR
            [System.Windows.MessageBox]::Show("Erro na restauração: $_", "Erro")
        }
    })

    #-- Ferramentas: pastas --
    $script:Window.FindName('btnOpenProfile').Add_Click({
        $p = Get-ChromeProfilePath
        if (Test-Path $p) { Start-Process $p } else { [System.Windows.MessageBox]::Show("Pasta não encontrada: $p") }
    })
    $script:Window.FindName('btnOpenCache').Add_Click({
        $p = Join-Path (Get-ChromeProfilePath) "Default\Cache"
        if (Test-Path $p) { Start-Process $p } else { [System.Windows.MessageBox]::Show("Cache não encontrado.") }
    })
    $script:Window.FindName('btnOpenDownloads').Add_Click({
        Start-Process "$env:USERPROFILE\Downloads"
    })
    $script:Window.FindName('btnOpenLogs').Add_Click({
        Start-Process $script:Dirs.Logs
    })
    $script:Window.FindName('btnOpenBackups').Add_Click({
        Start-Process $script:Dirs.BackupChrome
    })

    #-- Ferramentas: chrome:// --
    $script:Window.FindName('btnChromeSettings').Add_Click({
        $cp = Get-ChromeInstallPath
        if ($cp) { Start-Process $cp "chrome://settings" } else { [System.Windows.MessageBox]::Show("Chrome não encontrado.") }
    })
    $script:Window.FindName('btnChromeExtensions').Add_Click({
        $cp = Get-ChromeInstallPath
        if ($cp) { Start-Process $cp "chrome://extensions" } else { [System.Windows.MessageBox]::Show("Chrome não encontrado.") }
    })
    $script:Window.FindName('btnChromeHistory').Add_Click({
        $cp = Get-ChromeInstallPath
        if ($cp) { Start-Process $cp "chrome://history" } else { [System.Windows.MessageBox]::Show("Chrome não encontrado.") }
    })
    $script:Window.FindName('btnChromeDownloads').Add_Click({
        $cp = Get-ChromeInstallPath
        if ($cp) { Start-Process $cp "chrome://downloads" } else { [System.Windows.MessageBox]::Show("Chrome não encontrado.") }
    })
    $script:Window.FindName('btnChromeVersion').Add_Click({
        $cp = Get-ChromeInstallPath
        if ($cp) { Start-Process $cp "chrome://version" } else { [System.Windows.MessageBox]::Show("Chrome não encontrado.") }
    })

    #-- Configurações --
    $script:Window.FindName('btnSaveConfig').Add_Click({
        $cfg = @{
            Theme       = $script:Window.FindName('cmbTheme').SelectedItem.Content
            Language    = $script:Window.FindName('cmbLanguage').SelectedItem.Content
            AutoRefresh = [bool]$script:Window.FindName('chkAutoRefresh').IsChecked
            BaseDir     = $script:Window.FindName('txtBaseDir').Text
            Version     = $script:Version
        }
        Save-AppConfig -NewConfig $cfg

        if ($cfg.AutoRefresh) { $script:Timer.Start() } else { $script:Timer.Stop() }
        [System.Windows.MessageBox]::Show("Configurações salvas com sucesso!", "Configurações")
    })

    #-- Logs --
    $script:Window.FindName('btnRefreshLogs').Add_Click({
        if (Test-Path $script:LogFile) {
            $script:Window.FindName('txtLogs').Text =
                (Get-Content $script:LogFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
            $script:Window.FindName('txtLogs').ScrollToEnd()
        }
    })
    $script:Window.FindName('btnClearLogsUI').Add_Click({
        $script:Window.FindName('txtLogs').Clear()
    })
    $script:Window.FindName('btnOpenLogFile').Add_Click({
        if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile }
    })

    #-- Atendimento --
    $script:Window.FindName('btnAtendimento').Add_Click({
        $btn = $script:Window.FindName('btnAtendimento')

        if ($script:CurrentAtendimento) {
            $r = [System.Windows.MessageBox]::Show(
                "Deseja compactar o atendimento em ZIP antes de finalizar?",
                "Finalizar Atendimento — $($script:CurrentAtendimento.Cliente)",
                [System.Windows.MessageBoxButton]::YesNoCancel,
                [System.Windows.MessageBoxImage]::Question)

            if ($r -eq [System.Windows.MessageBoxResult]::Cancel) { return }

            Stop-Atendimento -CompactZip ($r -eq [System.Windows.MessageBoxResult]::Yes)

            $btn.Content    = "▶  Iniciar Atendimento"
            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A6E3A1')
            $script:Window.FindName('sbConfig').Text = "Atendimento: finalizado"
        } else {
            $data = Show-AtendimentoDialog
            if ($data -and $data.Cliente) {
                $atendDir = Start-Atendimento @data
                $btn.Content    = "■  Finalizar Atendimento ($($data.Cliente))"
                $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F38BA8')
                $script:Window.FindName('sbConfig').Text = "Atendimento: $($data.Cliente)"
                [System.Windows.MessageBox]::Show(
                    "Atendimento iniciado!`nPasta: $atendDir",
                    "Atendimento Iniciado")
            }
        }
    })

    #-- Timer de auto-refresh --
    $script:Timer          = [System.Windows.Threading.DispatcherTimer]::new()
    $script:Timer.Interval = [TimeSpan]::FromSeconds(3)
    $script:Timer.Add_Tick({
        $dashPanel = $script:Window.FindName('panelDashboard')
        if ($dashPanel -and $dashPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            Update-Dashboard
        }
        if ($script:Window) {
            $script:Window.FindName('sbTime').Text = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
        }
    })
    $script:Timer.Start()

    $script:Window.Add_Closing({
        $script:Timer.Stop()
        Write-AppLog "Aplicação encerrada pelo usuário" -Level INFO
    })

    Write-AppLog "Interface WPF inicializada com sucesso" -Level INFO
}
#endregion

#region === PONTO DE ENTRADA ===
function Main {
    <#
    .SYNOPSIS
        Ponto de entrada principal da aplicação.
    #>
    try {
        # Cria a estrutura de diretórios ANTES de qualquer operação de log
        Initialize-AppStructure

        Write-AppLog "=====================================================" -Level INFO
        Write-AppLog "$($script:AppName) v$($script:Version) — $($script:Company)" -Level INFO
        Write-AppLog "Build $($script:Build) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
        Write-AppLog "Computador: $env:COMPUTERNAME | Usuário: $env:USERNAME" -Level INFO
        Write-AppLog "=====================================================" -Level INFO
        Write-AppLog "Estrutura de diretórios verificada em: $script:BaseDir" -Level INFO

        $script:Config = Get-AppConfig
        if ($script:Config) {
            Write-AppLog "Configuração carregada com sucesso" -Level INFO
        }

        Initialize-Window
        Update-Dashboard

        $script:Window.ShowDialog() | Out-Null
    } catch {
        $errMsg = "Erro fatal na inicialização: $_"
        try { Write-AppLog $errMsg -Level ERROR } catch { }
        [System.Windows.MessageBox]::Show($errMsg, "Erro Fatal",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
}

Main
#endregion
