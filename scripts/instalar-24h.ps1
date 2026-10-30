<#
Deixa esta maquina Windows atendendo o Claude pelo claude.ai e pelo app, 24h por dia:
  - garante o Claude Code de terminal (instala a partir da extensao do editor ou do
    Claude Desktop, se for o caso)
  - cria %LOCALAPPDATA%\ClaudeRemoteControl\remote-control-24h.bat, que espera a pasta
    do projeto aparecer (o Google Drive monta o G: so depois do login) e reabre o
    Remote Control se ele cair
  - com -Atalho, poe esse .bat na Inicializacao do Windows (abre a cada login)
  - com -SemSuspensao, impede o PC de dormir, hibernar ou suspender ao fechar a tampa
    quando estiver na tomada
Pergunte a pessoa antes de usar -Atalho e -SemSuspensao: as duas mudam o Windows dela.
#>
param(
    [Parameter(Mandatory = $true)][string]$Pasta,
    [switch]$Atalho,
    [switch]$SemSuspensao,
    [string]$Claude   # caminho do claude.exe, se ja souber
)
$ErrorActionPreference = 'Stop'
$Pasta = (Resolve-Path -LiteralPath $Pasta).Path

# Precisa ser um .exe num lugar fixo. Os atalhos do npm (claude.cmd, claude.ps1) quebram
# o laco do .bat, e o Claude embutido na extensao ou no Desktop muda de pasta a cada versao.
if (-not $Claude) {
    $Claude = Get-Command claude -All -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.exe' -and $_.Source -notmatch '\\extensions\\|\\claude-code\\' } |
        Select-Object -First 1 -ExpandProperty Source
    $fixo = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not $Claude -and (Test-Path -LiteralPath $fixo)) { $Claude = $fixo }
    if (-not $Claude) {
        $instalador = @(Get-ChildItem "$env:USERPROFILE\.*\extensions\anthropic.claude-code-*\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue) +
            @(Get-ChildItem "$env:LOCALAPPDATA\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\*\*\claude.exe", "$env:APPDATA\Claude\claude-code\*\*\claude.exe" -ErrorAction SilentlyContinue) |
            Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
        if (-not $instalador) { throw 'Nao achei o Claude Code. Instale com:  irm https://claude.ai/install.ps1 | iex' }
        Write-Host 'Instalando o Claude Code de terminal...'
        & $instalador install
        if (-not (Test-Path -LiteralPath $fixo)) { throw "A instalacao terminou, mas nao achei $fixo." }
        $Claude = $fixo
    }
}
Write-Host "Claude Code: $Claude"

# O Remote Control so roda com o Claude de terminal logado. Quem so usava o Desktop
# ainda nao entrou na conta por ele, e o .bat ficaria repetindo o erro de login.
$logado = $false
try { $logado = (& $Claude auth status | Out-String) -match '"loggedIn"\s*:\s*true' } catch { }
if (-not $logado) {
    Write-Host "O Claude de terminal ainda nao entrou na sua conta. Antes de usar o .bat, rode num terminal:  `"$Claude`" auth login  e entre com a mesma conta do claude.ai." -ForegroundColor Yellow
}

# Pasta sincronizada pode nao estar pronta no login, e bots 24h dentro dela geram conflitos
$sincronizada = $Pasta -match '\\(Meu Drive|My Drive|Google Drive|Dropbox)(\\|$)' -or
    ($env:OneDrive -and $Pasta.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase))
try { if (([IO.DriveInfo]$Pasta.Substring(0, 3)).VolumeLabel -match 'Google Drive') { $sincronizada = $true } } catch { }
if ($sincronizada) {
    Write-Host "Atencao: $Pasta fica numa pasta sincronizada (Drive, OneDrive ou Dropbox). O .bat espera ela aparecer depois do login, mas bots e servicos 24h rodando ai dentro costumam dar conflito de sincronizacao. Prefira uma pasta local." -ForegroundColor Yellow
}

$casa = Join-Path $env:LOCALAPPDATA 'ClaudeRemoteControl'
New-Item -ItemType Directory -Force -Path $casa | Out-Null
$bat = Join-Path $casa 'remote-control-24h.bat'
# %USERPROFILE% e expandido pelo Windows, sem passar por pagina de codigo. O que sobrar
# com acento (a pasta do projeto) e lido como UTF-8 depois do chcp 65001.
$claudeNoBat = $Claude
if ($Claude.StartsWith($env:USERPROFILE + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $claudeNoBat = '%USERPROFILE%' + $Claude.Substring($env:USERPROFILE.Length)
}
$pastaNoBat = $Pasta
if ($Pasta.StartsWith($env:USERPROFILE + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $pastaNoBat = '%USERPROFILE%' + $Pasta.Substring($env:USERPROFILE.Length)
}
$conteudo = @"
@echo off
chcp 65001 >nul
rem Criado pela skill migra-claudinho-adalton. Mantem o Remote Control no ar:
rem se o Claude fechar ou cair, abre de novo em 15 segundos. Feche a janela para parar.
title Claude Remote Control
set "PASTA=$pastaNoBat"
set "CLAUDE=$claudeNoBat"
:espera
if exist "%PASTA%\" goto achou
echo Esperando a pasta do projeto aparecer (o Google Drive pode demorar depois do login)...
timeout /t 10 /nobreak >nul
goto espera
:achou
cd /d "%PASTA%"
:inicio
"%CLAUDE%" remote-control
echo Remote Control parou. Reiniciando em 15 segundos...
timeout /t 15 /nobreak >nul
goto inicio
"@
[IO.File]::WriteAllText($bat, $conteudo.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Criado: $bat"

if ($Atalho) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Remote Control.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $bat
    $s.WorkingDirectory = $casa
    $s.WindowStyle = 7   # minimizado
    $s.Save()
    Write-Host "Abre sozinho a cada login: $lnk"
}

if ($SemSuspensao) {
    $ok = $true
    foreach ($a in @(@('/change', 'standby-timeout-ac', '0'), @('/change', 'hibernate-timeout-ac', '0'),
            @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0'), @('/setactive', 'SCHEME_CURRENT'))) {
        & powercfg @a
        if ($LASTEXITCODE -ne 0) { $ok = $false; Write-Host "powercfg $($a -join ' ') falhou ($LASTEXITCODE)." -ForegroundColor Yellow }
    }
    if ($ok) { Write-Host 'Na tomada, o PC nao dorme, nao hiberna e nao suspende ao fechar a tampa.' }
    else { Write-Host 'Parte do ajuste de energia falhou: confira em Configuracoes > Sistema > Energia.' -ForegroundColor Yellow }
}

Write-Host ''
Write-Host "Falta uma coisa: de dois cliques em $bat uma vez e responda o que ele perguntar." -ForegroundColor Green
Write-Host 'Depois disso esta maquina aparece em claude.ai/code e no app do Claude.'
Write-Host 'Se o PC reiniciar (queda de luz, atualizacao), ele so volta depois que alguem entrar na conta do Windows.'
