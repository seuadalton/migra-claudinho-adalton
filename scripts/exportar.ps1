<#
Roda na MAQUINA ANTIGA (Windows). Junta tudo do Claude Code num pacote de migracao:
  <Destino>\claude-export.zip   conversas, memorias, skills, configuracoes
  <Destino>\manifesto.json      de onde veio cada projeto, plugins e servidores MCP
  <Destino>\skill\              esta skill, para a maquina nova saber o que fazer
  <Destino>\COLE-NO-CLAUDE.txt  texto para a pessoa colar no Claude da maquina nova
O login (.credentials.json) fica de fora de proposito: na maquina nova a pessoa entra de novo.
#>
param(
    [string]$Destino = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Migracao-Claude')
)
$ErrorActionPreference = 'Stop'

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$configGlobal = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' }
$skillDir = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath (Join-Path $claudeDir 'projects'))) {
    throw "Nao achei conversas em $claudeDir\projects. O Claude Code ja foi usado neste usuario?"
}

# Coisas desta maquina que nao fazem sentido em outra (sessoes abertas, travas, caches, login)
$naoLevarPastas = 'cache', 'plugins', 'shell-snapshots', 'session-env', 'sessions', 'ide', 'statsig',
    'telemetry', 'backups', 'state', 'security', 'debug', 'local', 'paste-cache', 'image-cache'
$naoLevarArquivos = '.credentials.json', '.last-cleanup', 'mcp-needs-auth-cache.json', '.claude.json'

New-Item -ItemType Directory -Force -Path $Destino | Out-Null
$Destino = (Resolve-Path -LiteralPath $Destino).Path
for ($p = $Destino; $p; $p = Split-Path $p -Parent) {
    if (Test-Path -LiteralPath (Join-Path $p '.git')) {
        throw "$Destino fica dentro de um repositorio git ($p). O pacote tem conversas inteiras e nao pode ir para o git. Escolha outra pasta."
    }
}

function Copiar-Pasta($de, $para, $excluirPastas = @(), $excluirArquivos = @()) {
    if (-not (Test-Path -LiteralPath $de)) { return }
    $extra = @()
    if ($excluirPastas) { $extra += '/XD'; $extra += $excluirPastas }
    if ($excluirArquivos) { $extra += '/XF'; $extra += $excluirArquivos }
    robocopy $de $para /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP @extra | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ($LASTEXITCODE) copiando $de" }
}

# Pasta de dados do Claude Desktop. O da Microsoft Store guarda tudo dentro do pacote;
# o instalador antigo, em %APPDATA%\Claude. Se houver as duas, vale a usada por ultimo.
function Achar-Desktop {
    $candidatos = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' }) + @(Join-Path $env:APPDATA 'Claude')
    $candidatos | Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending | Select-Object -First 1
}

function Ler-Cwd($arquivo) {
    $r = New-Object IO.StreamReader($arquivo)
    try {
        while ($null -ne ($linha = $r.ReadLine())) {
            $m = [regex]::Match($linha, '"cwd":"((?:[^"\\]|\\.)*)"')
            if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
        }
    } finally { $r.Close() }
    return $null
}

Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue
# JavaScriptSerializer porque o ConvertFrom-Json do PowerShell 5.1 quebra com chaves
# que so diferem em maiusculas (C:/ e c:/), comuns no .claude.json
function Ler-Json($arquivo) {
    if (-not (Test-Path -LiteralPath $arquivo)) { return $null }
    return $js.DeserializeObject([IO.File]::ReadAllText($arquivo))
}

$tmp = Join-Path $env:TEMP ('claude-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host 'Copiando conversas, memorias e configuracoes...'
    # As marcas e backups de uma migracao anterior tambem ficam: na proxima maquina,
    # elas fariam a importacao achar que ja tinha rodado ali
    Copiar-Pasta $claudeDir (Join-Path $tmp 'claude') `
        (@($naoLevarPastas | ForEach-Object { Join-Path $claudeDir $_ }) + 'backup-migracao-*') `
        (@($naoLevarArquivos | ForEach-Object { Join-Path $claudeDir $_ }) + '.migra-claudinho-*' + 'settings.json.antes-da-migracao*')
    Copiar-Pasta (Join-Path $claudeDir 'plugins\data') (Join-Path $tmp 'claude\plugins\data')
    $memAqui = Join-Path $env:USERPROFILE '.claude-mem'
    Copiar-Pasta $memAqui (Join-Path $tmp 'home\.claude-mem')
    # O banco do claude-mem pode estar sendo gravado agora. Com o sqlite3 instalado, troca a
    # copia por um retrato consistente dele; sem o sqlite3, o -wal copiado junto costuma bastar.
    $sqlite = Get-Command sqlite3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($sqlite) {
        foreach ($db in @(Get-ChildItem -LiteralPath $memAqui -Filter *.db -File -ErrorAction SilentlyContinue)) {
            $copia = Join-Path $tmp "home\.claude-mem\$($db.Name)"
            Remove-Item -LiteralPath $copia, "$copia-wal", "$copia-shm" -ErrorAction SilentlyContinue
            & $sqlite $db.FullName ".backup '$($copia.Replace("'", "''"))'"
            if ($LASTEXITCODE -ne 0) {   # sem retrato: volta a copia simples, com -wal e -shm
                foreach ($parte in '', '-wal', '-shm') {
                    if (Test-Path -LiteralPath "$($db.FullName)$parte") { Copy-Item -LiteralPath "$($db.FullName)$parte" -Destination "$copia$parte" -Force }
                }
            }
        }
    }

    # Claude Desktop: so uma lista fechada do que e do usuario. O resto da pasta dele e
    # cache, binario ou login; o config.json, por exemplo, guarda o token (oauth:tokenCache).
    $desktop = $null
    $desktopDir = Achar-Desktop
    if ($desktopDir) {
        Write-Host "Copiando o que e seu no Claude Desktop..."
        $d = Join-Path $tmp 'desktop'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $cfgDesktop = Join-Path $desktopDir 'claude_desktop_config.json'
        if (Test-Path -LiteralPath $cfgDesktop) { Copy-Item -LiteralPath $cfgDesktop -Destination $d }
        foreach ($sub in 'Claude Extensions', 'Claude Extensions Settings', 'claude-code-sessions') {
            Copiar-Pasta (Join-Path $desktopDir $sub) (Join-Path $d $sub)
        }
        # skills-plugin sao as skills embutidas, que o Desktop recria sozinho
        Copiar-Pasta (Join-Path $desktopDir 'local-agent-mode-sessions') (Join-Path $d 'local-agent-mode-sessions') `
            @(Join-Path $desktopDir 'local-agent-mode-sessions\skills-plugin')
        $cfgD = Ler-Json $cfgDesktop
        $extensoes = Join-Path $desktopDir 'Claude Extensions'
        $tarefas = 0
        Get-ChildItem -LiteralPath $d -Filter 'scheduled-tasks.json' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $t = Ler-Json $_.FullName
            if ($t -and $t.ContainsKey('scheduledTasks')) { $tarefas += @($t['scheduledTasks']).Count }
        }
        $desktop = [ordered]@{
            pasta      = [string]$desktopDir
            mcpServers = @(if ($cfgD -and $cfgD.ContainsKey('mcpServers')) { $cfgD['mcpServers'].Keys | ForEach-Object { [string]$_ } })
            extensoes  = @(if (Test-Path -LiteralPath $extensoes) { Get-ChildItem -LiteralPath $extensoes -Directory | ForEach-Object { [string]$_.Name } })
            tarefas    = $tarefas
        }
    }

    Write-Host 'Montando o manifesto...'
    $projetos = @()
    foreach ($pasta in Get-ChildItem -LiteralPath (Join-Path $claudeDir 'projects') -Directory) {
        $cwd = $null
        foreach ($f in Get-ChildItem -LiteralPath $pasta.FullName -Filter *.jsonl -Recurse) {
            $cwd = Ler-Cwd $f.FullName
            if ($cwd) { break }
        }
        $memoria = Join-Path $pasta.FullName 'memory'
        $projetos += [ordered]@{
            pasta    = $pasta.Name
            cwd      = $cwd
            sessoes  = @(Get-ChildItem -LiteralPath $pasta.FullName -Filter *.jsonl -File).Count
            memorias = if (Test-Path -LiteralPath $memoria) { @(Get-ChildItem -LiteralPath $memoria -Filter *.md -File).Count } else { 0 }
        }
    }

    $settings = Ler-Json (Join-Path $claudeDir 'settings.json')
    $plugins = @()
    if ($settings -and $settings.ContainsKey('enabledPlugins')) {
        foreach ($k in $settings['enabledPlugins'].Keys) { if ($settings['enabledPlugins'][$k] -eq $true) { $plugins += $k } }
    }
    $marketplaces = [ordered]@{}
    $conhecidos = Ler-Json (Join-Path $claudeDir 'plugins\known_marketplaces.json')
    if ($conhecidos) { foreach ($k in $conhecidos.Keys) { $marketplaces[$k] = $conhecidos[$k]['source'] } }

    $global = Ler-Json $configGlobal
    $mcpUsuario = @{}
    $mcpLocal = @()
    if ($global) {
        if ($global.ContainsKey('mcpServers')) { $mcpUsuario = $global['mcpServers'] }
        if ($global.ContainsKey('projects')) {
            foreach ($k in $global['projects'].Keys) {
                $proj = $global['projects'][$k]
                if ($proj -is [System.Collections.IDictionary] -and $proj.ContainsKey('mcpServers') -and $proj['mcpServers'].Count -gt 0) {
                    $mcpLocal += [ordered]@{ projeto = $k; servidores = $proj['mcpServers'] }
                }
            }
        }
    }

    $manifesto = [ordered]@{
        formato      = 'migra-claudinho/1'
        criadoEm     = (Get-Date).ToString('s')
        # [string]: o Join-Path devolve o texto embrulhado num PSObject, que o serializador nao aceita
        origem       = [ordered]@{ so = 'windows'; computador = $env:COMPUTERNAME; home = [string]$env:USERPROFILE; claudeDir = [string]$claudeDir }
        projetos     = $projetos
        plugins      = $plugins
        marketplaces = $marketplaces
        # So os nomes: as configuracoes (que podem ter chaves de API) vao em mcp.json,
        # dentro do zip, para nao aparecerem a quem so le o manifesto
        mcpUsuario   = @($mcpUsuario.Keys | ForEach-Object { [string]$_ })
        mcpLocal     = @($mcpLocal | ForEach-Object { [ordered]@{ projeto = $_['projeto']; servidores = @($_['servidores'].Keys | ForEach-Object { [string]$_ }) } })
        desktop      = $desktop
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Destino 'manifesto.json'), $js.Serialize($manifesto), $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp 'mcp.json'), $js.Serialize([ordered]@{ mcpUsuario = $mcpUsuario; mcpLocal = $mcpLocal }), $utf8)

    Write-Host 'Compactando...'
    $zip = Join-Path $Destino 'claude-export.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    # Nomes em UTF-8: sem isso o tar do Windows grava acentos na pagina de codigo local,
    # e eles chegam estragados no Mac, no Linux ou num Windows de outro idioma
    & "$env:SystemRoot\System32\tar.exe" --options zip:hdrcharset=UTF-8 -a -c -f $zip -C $tmp .
    if ($LASTEXITCODE -ne 0) { throw "tar falhou ($LASTEXITCODE)" }

    Copiar-Pasta $skillDir (Join-Path $Destino 'skill') @(Join-Path $skillDir '.git')
    Copy-Item -LiteralPath (Join-Path $skillDir 'assets\COLE-NO-CLAUDE.txt') -Destination $Destino -Force
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$total = ($projetos | ForEach-Object { $_.sessoes } | Measure-Object -Sum).Sum
$mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB)
Write-Host ''
Write-Host "Pronto: $total conversas de $($projetos.Count) pastas de projeto, $mb MB." -ForegroundColor Green
if ($desktop) {
    Write-Host ("Claude Desktop: {0} servidor(es) MCP, {1} extensao(oes), {2} tarefa(s) agendada(s)." -f
        $desktop['mcpServers'].Count, $desktop['extensoes'].Count, $desktop['tarefas'])
}
Write-Host "Pacote: $Destino"
Write-Host 'Leve a pasta inteira para a maquina nova. Ela tem conversas completas: guarde so em lugar privado e apague depois.'
exit 0   # sem isto, o codigo de saida seria o do ultimo robocopy (1 = "copiou arquivos")
