<#
Roda na MAQUINA NOVA (Windows), com o Claude instalado e logado na mesma conta.
Restaura o pacote do exportar e reescreve os caminhos para as conversas antigas
aparecerem nas pastas certas desta maquina.

  -Pacote          pasta com claude-export.zip (ou .tar.gz) e manifesto.json
  -Simular         so mostra o que faria. Comece sempre por aqui.
  -Mapa            arquivo JSON {"caminho antigo": "caminho novo"}. Cada regra vale
                   para a pasta e tudo dentro dela.
  -SemPlugins      nao reinstala marketplaces e plugins (o Claude costuma baixar sozinho)
  -DiasHistorico   prazo, em dias, para o Claude apagar conversas antigas, quando ninguem
                   definiu (o padrao do Claude e 30). 0 = nao mexer.
  -SoDesktop       faz so a parte do Claude Desktop (para rodar depois de fechar o Desktop)
  -SemDesktop      pula a parte do Claude Desktop

Pode rodar quantas vezes quiser. Nada se perde: quando o mesmo arquivo mudou nos dois
lados, o mais novo fica no lugar e o outro vai para ~/.claude/backup-migracao-<data>.
#>
param(
    [string]$Pacote,
    [string]$Mapa,
    [switch]$Simular,
    [switch]$SemPlugins,
    [int]$DiasHistorico = 365,
    [switch]$SoDesktop,
    [switch]$SemDesktop
)
$ErrorActionPreference = 'Stop'

if (-not $Pacote) { $Pacote = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }   # <pacote>\skill\scripts
$Pacote = (Resolve-Path -LiteralPath $Pacote).Path
$arquivo = 'claude-export.zip', 'claude-export.tar.gz' | ForEach-Object { Join-Path $Pacote $_ } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $arquivo) { throw "Nao achei claude-export.zip nem claude-export.tar.gz em $Pacote. Use -Pacote <pasta do pacote>." }

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$homeNova = $env:USERPROFILE
$utf8 = New-Object Text.UTF8Encoding($false)
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'

Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue
function Ler-Json($caminho) { $js.DeserializeObject([IO.File]::ReadAllText($caminho, $utf8)) }

# Comparar arquivos byte a byte em PowerShell puro seria lento demais para conversas grandes
Add-Type -TypeDefinition @'
public static class MigraArquivos {
    // Abre deixando outros programas lerem e gravarem (o claude-mem mantem o banco aberto)
    static System.IO.FileStream Abrir(string caminho) {
        return new System.IO.FileStream(caminho, System.IO.FileMode.Open, System.IO.FileAccess.Read,
            System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete);
    }
    // true se o conteudo de "menor" e exatamente o comeco de "maior"
    public static bool ComecaCom(string maior, string menor) {
        using (var a = Abrir(maior))
        using (var b = Abrir(menor)) {
            if (b.Length > a.Length) return false;
            var ba = new byte[1 << 16]; var bb = new byte[1 << 16];
            int n;
            while ((n = b.Read(bb, 0, bb.Length)) > 0) {
                int lidos = 0;
                while (lidos < n) { int k = a.Read(ba, lidos, n - lidos); if (k <= 0) return false; lidos += k; }
                for (int i = 0; i < n; i++) if (ba[i] != bb[i]) return false;
            }
            return true;
        }
    }
    public static bool Iguais(string a, string b) {
        return new System.IO.FileInfo(a).Length == new System.IO.FileInfo(b).Length && ComecaCom(a, b);
    }
}
'@

$man = Ler-Json (Join-Path $Pacote 'manifesto.json')
$origemWindows = $man['origem']['so'] -eq 'windows'
$homeVelha = $man['origem']['home']
$sepVelho = if ($origemWindows) { '\' } else { '/' }
$cmp = if ($origemWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

# Troca a pasta de usuario antiga pela nova num texto JSON. Ela aparece como
# C:\\Users\\x (escapada) ou C:/Users/x em hooks, statusLine e servidores MCP.
function Trocar-Home($txt) {
    if (-not $homeVelha -or $homeVelha -eq $homeNova) { return $txt }
    $formas = if ($origemWindows) { @($homeVelha.Replace('\', '\\'), $homeVelha.Replace('\', '/')) } else { @($homeVelha) }
    foreach ($forma in $formas) {
        $troca = if ($forma.Contains('\\')) { $homeNova.Replace('\', '\\') } else { $homeNova.Replace('\', '/') }
        $txt = [regex]::Replace($txt, [regex]::Escape($forma) + '(?=\\\\|/|")', $troca.Replace('$', '$$'), 'IgnoreCase')
    }
    return $txt
}

# Pasta de dados do Claude Desktop nesta maquina (Microsoft Store ou instalador antigo)
function Achar-Desktop {
    $candidatos = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' }) + @(Join-Path $env:APPDATA 'Claude')
    $candidatos | Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending | Select-Object -First 1
}
function Desktop-Aberto {
    [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path -match '\\WindowsApps\\Claude_[^\\]+\\app\\claude\.exe$|\\AnthropicClaude\\.*claude\.exe$' })
}

# --- Caminhos ---------------------------------------------------------------------

function Normalizar($p) {
    if ($origemWindows) { $p = $p.Replace('/', '\') }
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }
    return $p
}

function Casa($caminho, $prefixo) {
    $caminho.Equals($prefixo, $cmp) -or $caminho.StartsWith($prefixo.TrimEnd('\', '/') + $sepVelho, $cmp)
}

# Regras @(antigo, novo, origem); a mais longa que casar vence
$regras = New-Object System.Collections.ArrayList
function Regra-Para($caminho) {
    $melhor = $null
    foreach ($r in $regras) {
        if ((Casa $caminho $r[0]) -and (-not $melhor -or $r[0].Length -gt $melhor[0].Length)) { $melhor = $r }
    }
    return $melhor
}
function Aplicar($regra, $caminho) {
    $resto = $caminho.Substring($regra[0].TrimEnd('\', '/').Length)
    if (-not $origemWindows) { $resto = $resto.Replace('/', '\') }
    # Um so separador na juncao: "E:\" + "\Projetos" daria "E:\\Projetos"
    if ($regra[1].EndsWith('\') -and $resto.StartsWith('\')) { $resto = $resto.Substring(1) }
    return $regra[1] + $resto
}
function Traduzir($caminho) {
    if (-not $caminho) { return $null }
    $r = Regra-Para $caminho
    if ($r) { return Aplicar $r $caminho }
    return $null
}

# Mesmo esquema que o Claude Code 2.1 usa para nomear as pastas em projects\: troca
# o que nao e letra ou numero por '-' e, acima de 200 caracteres, corta e soma um hash.
function Hash36($s) {
    [long]$h = 0
    foreach ($ch in $s.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 4294967296 }
    if ($h -ge 2147483648) { $h -= 4294967296 }
    $h = [Math]::Abs($h)
    $digitos = '0123456789abcdefghijklmnopqrstuvwxyz'
    $r = ''
    do { $r = $digitos.Substring([int]($h % 36), 1) + $r; $h = [long][Math]::Floor($h / 36) } while ($h -gt 0)
    return $r
}
function NomeDaPasta($caminho) {
    $nome = $caminho -replace '[^a-zA-Z0-9]', '-'
    if ($nome.Length -le 200) { return $nome }
    return $nome.Substring(0, 200) + '-' + (Hash36 $caminho)
}

# Procura pastas com o mesmo nome nos lugares onde projetos costumam ficar, ate 3
# niveis abaixo de cada um e por no maximo 20 segundos (discos de nuvem sao lentos)
$pularNaBusca = 'node_modules', 'AppData', 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
    '$Recycle.Bin', 'System Volume Information', 'Users'
function Sugerir($caminho) {
    $folha = ($caminho -split '[\\/]')[-1]
    $raizes = @($regras | ForEach-Object { $_[1] }) +
        @('Documents', 'Desktop', 'OneDrive', 'Projetos', 'Projects', 'source') | ForEach-Object { if ($_ -match '[\\/]') { $_ } else { Join-Path $homeNova $_ } }
    $raizes = @($raizes) + $homeNova + @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Root })
    $fila = New-Object System.Collections.Queue
    foreach ($r in $raizes) { if ($r -and (Test-Path -LiteralPath $r)) { $fila.Enqueue(@($r, 0)) } }
    $vistos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $achados = New-Object System.Collections.Generic.List[string]
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    while ($fila.Count -and $achados.Count -lt 5 -and $relogio.Elapsed.TotalSeconds -lt 20) {
        $dir, $nivel = $fila.Dequeue()
        if (-not $vistos.Add($dir)) { continue }
        try { $filhos = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($f in $filhos) {
            $nome = [IO.Path]::GetFileName($f)
            if ($nome -eq $folha -and -not $achados.Contains($f)) { $achados.Add($f) }
            if ($nivel -lt 3 -and $pularNaBusca -notcontains $nome -and -not $nome.StartsWith('.')) { $fila.Enqueue(@($f, ($nivel + 1))) }
        }
    }
    return @($achados)
}

$avisos = @()
if ($Mapa) {
    $Mapa = (Resolve-Path -LiteralPath $Mapa).Path
    $m = Ler-Json $Mapa
    foreach ($k in $m.Keys) {
        $v = ([string]$m[$k]).Replace('/', '\')
        if ($v.Length -gt 3) { $v = $v.TrimEnd('\') }
        [void]$regras.Add(@((Normalizar $k), $v, 'mapa'))
    }
}

# Resolve cada projeto. Pais antes dos filhos: um filho herda a regra da pasta mae,
# mas se a pasta herdada nao existe aqui, ele pode ter mudado de lugar sozinho.
$worktree = '[\\/](\.worktrees|\.claude[\\/]worktrees)[\\/]'
$plano = @()
foreach ($p in ($man['projetos'] | Sort-Object { if ($_['cwd']) { $_['cwd'].Length } else { 0 } })) {
    $velho = $p['cwd']
    $novo = $null; $situacao = $null; $sugestoes = @()
    if (-not $velho) {
        $situacao = 'sem caminho gravado (mantem o nome)'
    } else {
        $velho = Normalizar $velho
        $regra = Regra-Para $velho
        if ($regra) {
            $novo = Aplicar $regra $velho
            $herdada = -not $velho.Equals($regra[0], $cmp)
            if ($herdada -and -not (Test-Path -LiteralPath $novo) -and $velho -notmatch $worktree) { $novo = $null }
            elseif ($novo -eq $velho) { $situacao = 'mesmo caminho' }
            else { $situacao = 'mapeado' }
        }
        if (-not $novo -and $origemWindows -and (Test-Path -LiteralPath $velho)) {
            $novo = $velho; $situacao = 'mesmo caminho'
        } elseif (-not $novo -and $homeVelha -and (Casa $velho (Normalizar $homeVelha))) {
            $candidato = $homeNova + $velho.Substring((Normalizar $homeVelha).Length).Replace('/', '\')
            if (Test-Path -LiteralPath $candidato) { $novo = $candidato; $situacao = 'home trocada' }
        }
        if ($novo) {
            if (-not (Test-Path -LiteralPath $novo)) {
                if ($velho -match $worktree) { $situacao += ', pasta nao existe (normal para worktree apagado)' }
                else { $situacao = 'PASTA NAO EXISTE: confira o mapa' }   # mapa apontando para lugar errado
            }
            if (-not $regra -or $herdada) { [void]$regras.Add(@($velho, $novo, 'auto')) }
        } else {
            $situacao = 'NAO ENCONTRADO'
            $sugestoes = Sugerir $velho
        }
    }
    $plano += [pscustomobject]@{
        Pasta = $p['pasta']; Velho = $velho; Novo = $novo; Situacao = $situacao
        Sessoes = $p['sessoes']; Memorias = $p['memorias']; Sugestoes = $sugestoes
        Destino = if ($novo) { NomeDaPasta $novo } else { $p['pasta'] }
    }
}

Write-Host ''
Write-Host "Pacote de $($man['origem']['computador']) ($($man['origem']['so'])), criado em $($man['criadoEm'])"
foreach ($l in $plano) {
    $cor = if ($l.Situacao -match '^(NAO ENCONTRADO|PASTA NAO EXISTE)') { 'Yellow' } else { 'Gray' }
    Write-Host ("[{0}] {1} conversa(s), {2} memoria(s)" -f $l.Situacao, $l.Sessoes, $l.Memorias) -ForegroundColor $cor
    Write-Host "    antes: $($l.Velho)"
    if ($l.Novo) { Write-Host "    agora: $($l.Novo)" }
    foreach ($s in $l.Sugestoes) { Write-Host "    sugestao: $s" -ForegroundColor Cyan }
}
$faltando = @($plano | Where-Object { $_.Situacao -match '^(NAO ENCONTRADO|PASTA NAO EXISTE)' })
if ($faltando) {
    Write-Host ''
    Write-Host "$($faltando.Count) projeto(s) sem lugar nesta maquina. Crie um mapa.json, por exemplo:" -ForegroundColor Yellow
    Write-Host ('  { ' + $js.Serialize($faltando[0].Velho) + ': "<caminho nesta maquina>" }')
    Write-Host '  e rode de novo com -Mapa <arquivo>. Sem mapa, eles sao importados com o nome antigo.'
}
if ($man['desktop']) {
    $alvoD = Achar-Desktop
    $ondeD = if (-not $alvoD) { 'nao instalado nesta maquina' } elseif (Desktop-Aberto) { "$alvoD (aberto agora)" } else { $alvoD }
    Write-Host ''
    Write-Host ("Claude Desktop no pacote: {0} servidor(es) MCP, {1} extensao(oes), {2} tarefa(s) agendada(s). Aqui: {3}" -f
        @($man['desktop']['mcpServers']).Count, @($man['desktop']['extensoes']).Count, [int]$man['desktop']['tarefas'], $ondeD)
}
if ($Simular) {
    $avisos | ForEach-Object { Write-Host "Aviso: $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Simulacao: nada foi alterado.' -ForegroundColor Green
    exit 0
}

# --- Importacao -------------------------------------------------------------------

$backupDir = Join-Path $claudeDir "backup-migracao-$carimbo"
$guardados = 0
$emUso = @()

# Indice do que as importacoes anteriores instalaram (tamanho e data de cada arquivo do
# pacote). Com ele, rodar de novo nao traz de volta o que a pessoa apagou aqui, nem
# guarda em backup o que so mudou nesta maquina.
$indiceArq = Join-Path $claudeDir '.migra-claudinho-indice.json'
$indice = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $indiceArq) {
    try { $lido = Ler-Json $indiceArq; foreach ($k in $lido.Keys) { $indice[$k] = [string]$lido[$k] } } catch { }
}
function Assinatura($arquivo) { $i = Get-Item -LiteralPath $arquivo -Force; "$($i.Length)|$($i.LastWriteTimeUtc.Ticks)" }

# Copia por um arquivo temporario e so depois troca, para uma copia interrompida nunca
# deixar um arquivo pela metade com o nome certo. Mantem a data de modificacao.
function Copiar-Arquivo($de, $para) {
    $pasta = Split-Path $para -Parent
    if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Force -Path $pasta | Out-Null }
    $temp = "$para.migra-tmp"
    [IO.File]::Copy($de, $temp, $true)
    # [NullString]::Value e nao $null: o PowerShell passaria "" como caminho do backup
    if (Test-Path -LiteralPath $para) { [IO.File]::Replace($temp, $para, [NullString]::Value) } else { [IO.File]::Move($temp, $para) }
    [IO.File]::SetLastWriteTimeUtc($para, [IO.File]::GetLastWriteTimeUtc($de))
}

# Junta $de em $para sem perder nada:
#   - arquivo que so existe no pacote entra (a nao ser que uma importacao anterior ja o
#     tenha instalado e a pessoa o apagou aqui)
#   - se o daqui mudou e o do pacote e o mesmo da ultima importacao, fica o daqui
#   - se os dois lados mudaram, fica o mais novo e o outro vai para $backupDir\<nome>\...
#   - conversas so crescem: se uma e o comeco da outra, fica a maior, sem backup
# $pular aceita nomes com curinga, relativos a $de.
function Mesclar-Arvore($de, $para, $nome, $pular = @()) {
    if (-not (Test-Path -LiteralPath $de)) { return }
    $base = (Get-Item -LiteralPath $de).FullName.TrimEnd('\')
    foreach ($f in Get-ChildItem -LiteralPath $de -Recurse -File -Force) {
        $rel = $f.FullName.Substring($base.Length + 1)
        if ($pular | Where-Object { $rel -like $_ -or $rel -like "$_\*" }) { continue }
        $chave = "$nome\$rel"
        $alvo = Join-Path $para $rel
        try {
            $assinatura = Assinatura $f.FullName
            $antes = if ($indice.ContainsKey($chave)) { $indice[$chave] } else { $null }
            $jsonl = $rel -like '*.jsonl'
            if (-not (Test-Path -LiteralPath $alvo)) {
                # Se e igual ao que a ultima importacao instalou, a pessoa apagou aqui
                if ($antes -ne $assinatura) { Copiar-Arquivo $f.FullName $alvo }
            } elseif ($antes -eq $assinatura) {
                # O pacote nao mudou desde a ultima importacao: se o daqui esta diferente,
                # quem mudou foi a pessoa, aqui. Nem precisa abrir o arquivo.
            } elseif ([MigraArquivos]::Iguais($f.FullName, $alvo)) {
            } elseif ($jsonl -and [MigraArquivos]::ComecaCom($alvo, $f.FullName)) {
            } elseif ($jsonl -and [MigraArquivos]::ComecaCom($f.FullName, $alvo)) {
                Copiar-Arquivo $f.FullName $alvo
            } else {
                $pacoteGanha = $f.LastWriteTimeUtc -gt (Get-Item -LiteralPath $alvo -Force).LastWriteTimeUtc
                $perdedor = if ($pacoteGanha) { $alvo } else { $f.FullName }
                Copiar-Arquivo $perdedor (Join-Path (Join-Path $backupDir $nome) $rel)
                $script:guardados++
                if ($pacoteGanha) { Copiar-Arquivo $f.FullName $alvo }
            }
            $indice[$chave] = $assinatura   # so depois de dar certo
        } catch {
            $script:emUso += "$nome\$rel ($($_.Exception.Message.Trim()))"
        }
    }
}

# Reescreve caminhos gravados em campos JSON ("cwd", "project") de um arquivo. Primeiro as
# regras dos projetos, depois a troca da pasta de usuario: na ordem inversa, a troca
# esconderia o caminho antigo das regras. Mantem a data de modificacao: e ela que decide
# quem e mais novo quando a importacao roda de novo.
$avaliador = [Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $velho = Normalizar ([regex]::Unescape($m.Groups[3].Value))
    $novo = Traduzir $velho
    if (-not $novo) { return $m.Value }
    return '"' + $m.Groups[1].Value + '"' + $m.Groups[2].Value + $js.Serialize([string]$novo)
}
function Reescrever-Caminhos($arquivo, [switch]$TrocarHome) {
    $data = [IO.File]::GetLastWriteTimeUtc($arquivo)
    $txt = [IO.File]::ReadAllText($arquivo, $utf8)
    $novo = [regex]::Replace($txt, '"(cwd|project)"(\s*:\s*)"((?:[^"\\]|\\.)*)"', $avaliador)
    if ($TrocarHome) { $novo = Trocar-Home $novo }
    if ($novo -ne $txt) {
        [IO.File]::WriteAllText($arquivo, $novo, $utf8)
        [IO.File]::SetLastWriteTimeUtc($arquivo, $data)
    }
}

# Junta as linhas de dois arquivos sem repetir, mantendo as daqui primeiro
function Mesclar-Linhas($doPacote, $daqui) {
    if (-not (Test-Path -LiteralPath $doPacote)) { return }
    if (-not (Test-Path -LiteralPath $daqui)) { return }
    $vistas = New-Object 'System.Collections.Generic.HashSet[string]'
    $saida = New-Object System.Collections.Generic.List[string]
    foreach ($l in ([IO.File]::ReadAllLines($daqui, $utf8) + [IO.File]::ReadAllLines($doPacote, $utf8))) {
        if ($l.Trim() -eq '' -or $vistas.Add($l)) { $saida.Add($l) }
    }
    [IO.File]::WriteAllLines($daqui, $saida, $utf8)
    Remove-Item -LiteralPath $doPacote
}

# Tarefas agendadas do Desktop: o Desktop novo ja cria um scheduled-tasks.json vazio, entao
# o arquivo nao pode simplesmente ganhar ou perder. As tarefas do pacote que ainda nao
# existem aqui (pelo id) entram na lista daqui. Devolve quantas entraram.
function Mesclar-Tarefas($deDesktop, $alvo) {
    $adicionadas = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $deDesktop -Filter 'scheduled-tasks.json' -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($deDesktop.TrimEnd('\').Length + 1)
        $daqui = Join-Path $alvo $rel
        $doPacote = Ler-Json $f.FullName
        $tarefas = if ($doPacote -and $doPacote.ContainsKey('scheduledTasks')) { @($doPacote['scheduledTasks']) } else { @() }
        if (Test-Path -LiteralPath $daqui) {
            $local = Ler-Json $daqui
            if (-not $local) { $local = [System.Collections.Generic.Dictionary[string, object]]::new() }
            $lista = New-Object System.Collections.ArrayList
            if ($local.ContainsKey('scheduledTasks')) { foreach ($t in @($local['scheduledTasks'])) { [void]$lista.Add($t) } }
            $vistos = @($lista | ForEach-Object { if ($_ -is [System.Collections.IDictionary] -and $_.ContainsKey('id')) { [string]$_['id'] } else { $js.Serialize($_) } })
            $novas = 0
            foreach ($t in $tarefas) {
                $id = if ($t -is [System.Collections.IDictionary] -and $t.ContainsKey('id')) { [string]$t['id'] } else { $js.Serialize($t) }
                if ($vistos -notcontains $id) { [void]$lista.Add($t); $novas++ }
            }
            if ($novas) {
                $local['scheduledTasks'] = $lista.ToArray()
                # O backup vai para a pasta central, e nao ao lado: dentro da pasta do Desktop
                # ele viajaria no proximo pacote
                Copiar-Arquivo $daqui (Join-Path $backupDir "desktop\$rel")
                [IO.File]::WriteAllText($daqui, $js.Serialize($local), $utf8)
                $adicionadas += $novas
            }
        } else {
            Copiar-Arquivo $f.FullName $daqui
            $adicionadas += $tarefas.Count
        }
        Remove-Item -LiteralPath $f.FullName   # ja tratado; a mescla generica nao deve mexer
    }
    return $adicionadas
}

# Claude Desktop: mescla os servidores MCP do chat e copia extensoes e tarefas agendadas.
# Com o Desktop aberto, nao mexe em nada: ele regravaria a configuracao por cima.
function Importar-Desktop($deDesktop) {
    $alvo = Achar-Desktop
    if (-not $alvo) {
        return 'O pacote tem coisas do Claude Desktop, mas ele nao esta instalado aqui. Se a pessoa usa, instale, entre na conta, abra uma vez e rode de novo com -SoDesktop.'
    }
    if (Desktop-Aberto) {
        $comMapa = ''
        if ($Mapa) {
            $mapaNoPacote = Join-Path $Pacote 'mapa.json'
            if ($Mapa -ne $mapaNoPacote) { Copy-Item -LiteralPath $Mapa -Destination $mapaNoPacote -Force }
            $comMapa = ' -Mapa "%~dp0mapa.json"'
        }
        $bat = Join-Path $Pacote 'aplicar-claude-desktop.bat'
        $linhas = '@echo off', 'chcp 65001 >nul',
            'echo Antes de continuar, feche o Claude Desktop: icone do Claude perto do relogio, botao direito, Sair.', 'pause',
            ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0skill\scripts\importar.ps1" -Pacote "%~dp0." -SoDesktop' + $comMapa), 'pause'
        try {
            [IO.File]::WriteAllText($bat, (($linhas -join "`r`n") + "`r`n"), $utf8)
            return "O Claude Desktop esta aberto, entao a parte dele ficou para depois. Feche o Desktop (icone perto do relogio > Sair) e de dois cliques em: $bat"
        } catch {
            return "O Claude Desktop esta aberto, entao a parte dele ficou para depois. Feche-o e rode este script de novo com -SoDesktop."
        }
    }
    $msgs = @()
    $cfgVelho = Join-Path $deDesktop 'claude_desktop_config.json'
    $velho = if (Test-Path -LiteralPath $cfgVelho) { Ler-Json $cfgVelho } else { $null }
    if ($velho -and $velho.ContainsKey('mcpServers') -and $velho['mcpServers'].Count) {
        $cfgNovo = Join-Path $alvo 'claude_desktop_config.json'
        $novo = if (Test-Path -LiteralPath $cfgNovo) { Ler-Json $cfgNovo } else { $null }
        # ::new() e nao New-Object: o New-Object embrulha o dicionario num PSObject, e o
        # serializador quebra ("referencia circular") quando ele fica dentro de outro
        if (-not $novo) { $novo = [System.Collections.Generic.Dictionary[string, object]]::new() }
        if (-not $novo.ContainsKey('mcpServers')) { $novo['mcpServers'] = [System.Collections.Generic.Dictionary[string, object]]::new() }
        $adicionados = 0
        foreach ($nome in @($velho['mcpServers'].Keys)) {
            if ($novo['mcpServers'].ContainsKey($nome)) { continue }   # o daqui vence
            $novo['mcpServers'][$nome] = $js.DeserializeObject((Trocar-Home ($js.Serialize($velho['mcpServers'][$nome]))))
            $adicionados++
        }
        if ($adicionados) {
            if (Test-Path -LiteralPath $cfgNovo) { Copiar-Arquivo $cfgNovo (Join-Path $backupDir 'desktop\claude_desktop_config.json') }
            [IO.File]::WriteAllText($cfgNovo, $js.Serialize($novo), $utf8)
            Write-Host "Claude Desktop: $adicionados servidor(es) MCP adicionado(s)."
            if (-not $origemWindows) { $msgs += 'Os servidores MCP do Desktop vieram de Mac/Linux: confira os comandos em Configuracoes > Desenvolvedor.' }
        }
    }
    # Caminhos dentro das configuracoes de extensoes e das tarefas agendadas
    foreach ($sub in 'Claude Extensions Settings', 'claude-code-sessions', 'local-agent-mode-sessions') {
        $de = Join-Path $deDesktop $sub
        if (Test-Path -LiteralPath $de) {
            Get-ChildItem -LiteralPath $de -Filter *.json -Recurse -File | ForEach-Object { Reescrever-Caminhos $_.FullName -TrocarHome }
        }
    }
    $tarefas = Mesclar-Tarefas $deDesktop $alvo
    foreach ($sub in 'Claude Extensions', 'Claude Extensions Settings', 'claude-code-sessions', 'local-agent-mode-sessions') {
        Mesclar-Arvore (Join-Path $deDesktop $sub) (Join-Path $alvo $sub) "desktop\$sub"
    }
    $ext = @($man['desktop']['extensoes']).Count
    if ($ext) {
        $msgs += "Claude Desktop: $ext extensao(oes) copiada(s). Abra Configuracoes > Extensoes e preencha de novo as chaves e senhas que elas pedirem (ficam criptografadas na maquina antiga). Se alguma nao aparecer, reinstale."
    }
    if ($tarefas) {
        $msgs += "Claude Desktop: $tarefas tarefa(s) agendada(s) entraram aqui. Desligue-as na maquina antiga para nao rodarem duas vezes."
    }
    Write-Host 'Claude Desktop: pronto. Abra o Desktop de novo para ele ler as mudancas.'
    return $msgs
}

$mcp = $null
$tmp = Join-Path $env:TEMP "claude-import-$carimbo"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host ''
    Write-Host 'Descompactando...'
    $opcoes = if ($arquivo -like '*.tar.gz') { @('--options', 'hdrcharset=UTF-8') } else { @() }   # nomes com acento
    & "$env:SystemRoot\System32\tar.exe" @opcoes -x -f $arquivo -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "tar falhou ($LASTEXITCODE)" }
    $origem = Join-Path $tmp 'claude'
    $mcpArquivo = Join-Path $tmp 'mcp.json'
    if (Test-Path -LiteralPath $mcpArquivo) { $mcp = Ler-Json $mcpArquivo }

    # Marcas de uma importacao anterior NESTA maquina. Calculado antes de copiar qualquer
    # coisa, e as marcas que vierem no pacote (de uma migracao em cadeia) nao entram.
    $settings = Join-Path $claudeDir 'settings.json'
    $marca = Join-Path $claudeDir '.migra-claudinho-importado'
    $jaImportado = (Test-Path -LiteralPath $marca) -or [bool](Get-ChildItem -LiteralPath $claudeDir -Filter 'settings.json.antes-da-migracao*' -ErrorAction SilentlyContinue)
    $marcasDeMigracao = '.migra-claudinho-*', 'settings.json.antes-da-migracao*', 'backup-migracao-*'

    if (-not $SoDesktop) {
        Write-Host 'Ajustando caminhos e colocando as conversas no lugar...'
        New-Item -ItemType Directory -Force -Path (Join-Path $claudeDir 'projects') | Out-Null
        foreach ($l in $plano) {
            $de = Join-Path $origem "projects\$($l.Pasta)"
            if (-not (Test-Path -LiteralPath $de)) { continue }
            Get-ChildItem -LiteralPath $de -Filter *.jsonl -Recurse -File | ForEach-Object { Reescrever-Caminhos $_.FullName }
            $para = Join-Path $claudeDir "projects\$($l.Destino)"
            Mesclar-Linhas (Join-Path $de 'memory\MEMORY.md') (Join-Path $para 'memory\MEMORY.md')
            Mesclar-Arvore $de $para "projects\$($l.Destino)"
        }

        Write-Host 'Restaurando skills, configuracoes e historicos...'
        $historico = Join-Path $origem 'history.jsonl'
        if (Test-Path -LiteralPath $historico) { Reescrever-Caminhos $historico }
        Mesclar-Linhas $historico (Join-Path $claudeDir 'history.jsonl')
        Mesclar-Arvore $origem $claudeDir 'claude' (@('projects', 'settings.json') + $marcasDeMigracao)

        # claude-mem: a pasta de usuario aparece nas configuracoes dele, e o banco SQLite
        # (arquivo principal, -wal e -shm) so faz sentido inteiro, nunca misturado
        $mem = Join-Path $tmp 'home\.claude-mem'
        if (Test-Path -LiteralPath $mem) {
            Get-ChildItem -LiteralPath $mem -Filter *.json -File | ForEach-Object { Reescrever-Caminhos $_.FullName -TrocarHome }
            $bancoAqui = @(Get-ChildItem -LiteralPath (Join-Path $homeNova '.claude-mem') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(db|sqlite3?)$' })
            if ($bancoAqui) {
                $guardouBanco = $false
                foreach ($b in @(Get-ChildItem -LiteralPath $mem -File | Where-Object { $_.Name -match '\.(db|sqlite3?)(-wal|-shm|-journal)?$' })) {
                    $chave = "banco\$($b.Name)"; $sig = Assinatura $b.FullName
                    $antesB = if ($indice.ContainsKey($chave)) { $indice[$chave] } else { $null }
                    if ($antesB -ne $sig) {   # igual: o mesmo banco ja foi guardado numa rodada anterior
                        Copiar-Arquivo $b.FullName (Join-Path $backupDir "home\.claude-mem\$($b.Name)")
                        $indice[$chave] = $sig; $guardouBanco = $true
                    }
                    Remove-Item -LiteralPath $b.FullName
                }
                if ($guardouBanco) { $avisos += "O claude-mem desta maquina ja tem um banco proprio, entao o da maquina antiga nao foi misturado com ele. Ele ficou em $backupDir\home\.claude-mem. Para usar o antigo, feche o Claude (o claude-mem para junto) e copie os arquivos de la para $homeNova\.claude-mem." }
            }
        }
        Mesclar-Arvore (Join-Path $tmp 'home') $homeNova 'home'

        # settings.json: na primeira importacao vem o da maquina antiga (com backup do daqui).
        # Nas seguintes fica o daqui, para nao desfazer o que a pessoa mudou nesta maquina.
        $settingsPacote = Join-Path $origem 'settings.json'
        $atual = if (Test-Path -LiteralPath $settings) { [IO.File]::ReadAllText($settings, $utf8) } else { $null }
        if ((Test-Path -LiteralPath $settingsPacote) -and -not $jaImportado) {
            $txt = Trocar-Home ([IO.File]::ReadAllText($settingsPacote, $utf8))
            Write-Host 'settings.json: veio o da maquina antiga.'
            if (-not $origemWindows) { $avisos += 'O pacote veio de Mac/Linux: confira hooks e statusLine no settings.json, eles podem usar comandos que nao existem no Windows.' }
        } elseif ($null -ne $atual) {
            $txt = $atual
            if ($jaImportado -and (Test-Path -LiteralPath $settingsPacote)) { Write-Host 'settings.json: ja tinha sido importado antes; mantive o desta maquina.' }
        } else {
            $txt = '{}'
        }
        # O Claude apaga conversas mais velhas que cleanupPeriodDays (padrao: 30 dias).
        # As do Claude Desktop e do Cowork ficam fora dessa limpeza por padrao.
        if ($DiasHistorico -gt 0 -and $txt -notmatch '"cleanupPeriodDays"') {
            if ($txt -match '^\s*\{\s*\}\s*$') { $txt = "{ `"cleanupPeriodDays`": $DiasHistorico }" }
            else { $txt = ([regex]'\{').Replace($txt, "{`n  `"cleanupPeriodDays`": $DiasHistorico,", 1) }
            Write-Host "Conversas agora ficam guardadas por $DiasHistorico dias (cleanupPeriodDays)."
        }
        if ($txt -ne $atual) {
            if ($null -ne $atual) { Copy-Item -LiteralPath $settings -Destination "$settings.antes-da-migracao-$carimbo" }
            [IO.File]::WriteAllText($settings, $txt, $utf8)
        }
        [IO.File]::WriteAllText($marca, "Importado de $($man['origem']['computador']) em $carimbo`n", $utf8)
    }

    if (-not $SemDesktop -and (Test-Path -LiteralPath (Join-Path $tmp 'desktop'))) {
        $avisos += Importar-Desktop (Join-Path $tmp 'desktop')
    }
    $copiaIndice = @{}
    foreach ($k in $indice.Keys) { $copiaIndice[$k] = $indice[$k] }
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null   # quem so usa o Desktop pode nao ter ~/.claude ainda
    [IO.File]::WriteAllText($indiceArq, $js.Serialize($copiaIndice), $utf8)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($guardados) {
    $avisos += "$guardados arquivo(s) tinham versoes diferentes nos dois computadores. Ficou a mais nova; a outra foi guardada em $backupDir. Olhe com a pessoa se algo dali precisa voltar (memorias e CLAUDE.md primeiro) e apague a pasta depois."
}
if ($emUso) {
    $avisos += "Nao consegui juntar $($emUso.Count) arquivo(s). Ou estavam abertos por outro programa (feche o Claude e rode a importacao de novo), ou o caminho passa de 260 caracteres e o Windows nao esta com caminhos longos ligados (veja references/problemas.md):`n    " + ($emUso -join "`n    ")
}

if ($SoDesktop) {
    $avisos | ForEach-Object { Write-Host "Confira: $_" -ForegroundColor Yellow }
    exit 0
}

# --- Plugins e MCP pela CLI do Claude ---------------------------------------------

$ErrorActionPreference = 'Continue'   # uma falha aqui nao deve parar as outras

# So um .exe serve: os atalhos do npm (claude.ps1, claude.cmd) nao rodam por Process.Start
function Achar-Claude {
    $exe = Get-Command claude -All -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1 -ExpandProperty Source
    if (-not $exe -and (Test-Path (Join-Path $homeNova '.local\bin\claude.exe'))) { $exe = Join-Path $homeNova '.local\bin\claude.exe' }
    if (-not $exe -and $env:CLAUDE_PID) {   # o Claude que esta rodando esta importacao
        $p = (Get-Process -Id $env:CLAUDE_PID -ErrorAction SilentlyContinue).Path
        if ($p -like '*\claude.exe') { $exe = $p }
    }
    if (-not $exe) {
        $exe = Get-ChildItem "$homeNova\.*\extensions\anthropic.claude-code-*\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
    }
    if (-not $exe) {
        $dd = Achar-Desktop
        if ($dd) {
            $exe = Get-ChildItem "$dd\claude-code\*\*\claude.exe" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
        }
    }
    return $exe
}
$claude = Achar-Claude

# Monta a linha de comando com as regras de aspas do Windows. O PowerShell 5.1 nao
# escapa aspas dentro dos argumentos, e um JSON de MCP chegaria quebrado ao claude.exe.
function Citar([string]$s) {
    if ($s -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object Text.StringBuilder '"'
    $barras = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $barras++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * (2 * $barras + 1)) } else { [void]$sb.Append('\' * $barras) }
        [void]$sb.Append($ch)
        $barras = 0
    }
    [void]$sb.Append('\' * (2 * $barras)).Append('"')
    return $sb.ToString()
}
function Claude-Cli($pasta, [string[]]$argumentos) {
    $psi = New-Object Diagnostics.ProcessStartInfo $claude
    $psi.Arguments = ($argumentos | ForEach-Object { Citar $_ }) -join ' '
    $psi.WorkingDirectory = $pasta
    $psi.UseShellExecute = $false
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        return $p.ExitCode
    } catch {
        $script:falhas += "Nao consegui rodar o Claude ($claude): $($_.Exception.Message)"
        return -1
    }
}

$falhas = @()
if (-not $claude) {
    $falhas += 'Claude Code nao encontrado: plugins e MCP ficaram para depois. Instale o Claude e rode a importacao de novo.'
} else {
    if (-not $SemPlugins) {
        Write-Host 'Reinstalando marketplaces e plugins...'
        foreach ($nome in $man['marketplaces'].Keys) {
            $src = $man['marketplaces'][$nome]
            $alvo = foreach ($c in 'repo', 'url', 'path') { if ($src.ContainsKey($c)) { $src[$c]; break } }
            if (-not $alvo) { $falhas += "marketplace $nome (origem desconhecida)"; continue }
            [void](Claude-Cli $homeNova @('plugin', 'marketplace', 'add', $alvo))
        }
        foreach ($id in $man['plugins']) {
            if ((Claude-Cli $homeNova @('plugin', 'install', $id)) -ne 0) {
                $falhas += "plugin $id (se ele pedir para aprovar um comando, mostre o comando a pessoa e, com o OK dela, rode num terminal: `"$claude`" plugin install $id --yes)"
            }
        }
    }

    # As configuracoes dos servidores MCP (que podem ter chaves de API) vem do mcp.json
    # dentro do pacote compactado, nao do manifesto.
    if ($mcp) {
        if ($mcp['mcpUsuario'].Count -gt 0 -or @($mcp['mcpLocal']).Count -gt 0) { Write-Host 'Registrando servidores MCP...' }
        if (-not $origemWindows) { $avisos += 'Os servidores MCP vieram de Mac/Linux: confira os comandos com "claude mcp list".' }
        foreach ($nome in $mcp['mcpUsuario'].Keys) {
            $json = Trocar-Home ($js.Serialize($mcp['mcpUsuario'][$nome]))
            if ((Claude-Cli $homeNova @('mcp', 'add-json', '-s', 'user', $nome, $json)) -ne 0) { $falhas += "MCP $nome (talvez ja existisse)" }
        }
        foreach ($item in $mcp['mcpLocal']) {
            $pasta = Traduzir (Normalizar $item['projeto'])
            if (-not $pasta -and $origemWindows) { $pasta = Normalizar $item['projeto'] }
            if (-not $pasta -or -not (Test-Path -LiteralPath $pasta)) { $falhas += "MCPs locais de $($item['projeto']) (pasta nao existe aqui)"; continue }
            foreach ($nome in $item['servidores'].Keys) {
                $json = Trocar-Home ($js.Serialize($item['servidores'][$nome]))
                if ((Claude-Cli $pasta @('mcp', 'add-json', '-s', 'local', $nome, $json)) -ne 0) { $falhas += "MCP $nome em $pasta (talvez ja existisse)" }
            }
        }
    }

    # O doctor le o settings.json e diz se algo ficou invalido (o Claude ignoraria o arquivo)
    $doctor = (& $claude doctor 2>&1 | Out-String)
    if ($doctor -match 'Invalid settings') {
        $falhas += 'O claude doctor achou configuracoes invalidas. Rode "claude doctor" e corrija o settings.json:' + "`n" +
            (($doctor -split "`n" | Select-String -Pattern 'settings\.json' | ForEach-Object { '    ' + $_.Line.Trim() }) -join "`n")
    }
}

Write-Host ''
$avisos + $falhas | ForEach-Object { Write-Host "Confira: $_" -ForegroundColor Yellow }
$total = ($plano | ForEach-Object { $_.Sessoes } | Measure-Object -Sum).Sum
Write-Host "Importadas $total conversas. Feche e abra de novo o editor (ou o terminal) para ver o historico." -ForegroundColor Green
exit 0   # avisos e falhas ja foram listados acima
