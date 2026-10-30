# Onde o Claude Code guarda cada coisa

Leia quando precisar entender um caso fora do comum ou consertar algo à mão. Os scripts já cuidam do caso normal.

## Pasta do usuário

| Sistema | Pasta | Configuração global |
|---|---|---|
| Windows | `C:\Users\<nome>\.claude` | `C:\Users\<nome>\.claude.json` |
| macOS | `/Users/<nome>/.claude` | `/Users/<nome>/.claude.json` |
| Linux | `/home/<nome>/.claude` | `/home/<nome>/.claude.json` |

Com a variável `CLAUDE_CONFIG_DIR` definida, as duas ficam dentro dela, inclusive o `.claude.json`. Os scripts respeitam essa variável.

O terminal, a aba Code do Claude Desktop e a extensão do Claude Code usam essa mesma pasta. A extensão é a mesma no VS Code, no Cursor e no Antigravity, e roda o mesmo programa `claude`. A documentação oficial cita o VS Code e o Cursor; no Antigravity, isso foi visto na prática, e depois da importação vale abrir o painel do Claude nele para conferir. O agente próprio do Antigravity (Gemini) é outra coisa e não é migrado por esta skill.

## Conversas

- `projects/<pasta>/<id>.jsonl`: uma conversa por arquivo, uma linha JSON por mensagem. Cada linha tem `"cwd"`, o caminho de onde o Claude foi aberto.
- `projects/<pasta>/<id>/`: subagentes e resultados grandes de ferramentas daquela conversa.
- `projects/<pasta>/memory/`: memória automática do projeto (`MEMORY.md` é o índice).
- `<pasta>` é o caminho do projeto com todo caractere que não for `a-z`, `A-Z` ou `0-9` trocado por `-`. Por exemplo, `C:\Users\Ana\Documents\App` vira `C--Users-Ana-Documents-App`, e `/Users/ana/App` vira `-Users-ana-App`. No Windows, `c--` e `C--` são a mesma pasta, porque o NTFS não diferencia maiúsculas.
- Acima de 200 caracteres, o nome é cortado em 200 e ganha `-` mais um hash do caminho completo, em base 36. A documentação não descreve o hash. Os scripts reproduzem o do Claude Code 2.1, `h = (h*31 + código) | 0` sobre as unidades UTF-16 do caminho, e foram conferidos contra a função original. Se um dia o Claude mudar a fórmula, ele ainda acha pastas que começam com os mesmos 200 caracteres e têm conversas com o `cwd` certo, e a troca de `cwd` que o script faz garante isso.
- A lista do `/resume` e o histórico do painel do editor mostram as conversas da pasta do projeto aberto. `claude --resume <id>` também procura em outros projetos quando só um deles tem aquele id. `claude --resume <caminho completo do .jsonl>` abre qualquer arquivo.
- Testado no Claude Code 2.1.312: uma conversa movida para a pasta certa abre normalmente, mesmo com o `cwd` antigo dentro do arquivo. A troca do `cwd` que o script faz é para consistência, não para o resume funcionar.

## Limpeza automática

O Claude apaga conversas mais velhas que `cleanupPeriodDays` (padrão: 30 dias, mínimo: 1) no `settings.json`. A documentação não diz como mede a idade. A importação define 365 dias quando o valor não existe, para nenhuma conversa trazida sumir no primeiro início. As memórias e o `history.jsonl` não são apagados por essa limpeza.

As conversas do Claude Desktop e do Cowork ficam fora dessa limpeza por padrão. `desktopSessionCleanupPeriodDays` (padrão `0`, sem limite) cria um teto para elas. A importação não mexe nele, porque qualquer valor encurtaria a retenção.

## Configurações e personalizações do usuário

`settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `rules/`, `workflows/`, `output-styles/`, `themes/`, `agent-memory/`, `keybindings.json` e `history.jsonl` (comandos digitados, com o campo `"project"`). O exportar leva tudo da pasta, menos o que só faz sentido na máquina de origem: `.credentials.json`, `cache/`, `plugins/` (só `plugins/data/` vai), `sessions/`, `session-env/`, `shell-snapshots/`, `ide/`, `statsig/`, `telemetry/`, `backups/`, `state/`, `security/`, `debug/`, `local/`, `paste-cache/` e `image-cache/`.

Na importação, `MEMORY.md` e `history.jsonl` são juntados linha a linha. O resto entra arquivo por arquivo. Se um arquivo existe nos dois lados com conteúdo diferente, fica o mais novo, e o outro vai para `~/.claude/backup-migracao-<data>/`, com o mesmo caminho relativo. Conversa que só cresceu (uma versão é o começo da outra) não gera backup. As cópias passam por um arquivo `.migra-tmp` e só depois trocam de nome, para uma cópia interrompida nunca deixar um arquivo pela metade.

O arquivo `~/.claude/.migra-claudinho-indice.json` guarda o tamanho e a data de cada arquivo que a importação instalou. Numa nova rodada com o mesmo pacote, é por ele que o script sabe que um arquivo ausente foi apagado pela pessoa (e não o traz de volta) e que um arquivo diferente foi mudado só aqui (e o deixa como está, sem backup). Apagar esse índice faz a próxima rodada se comportar como a primeira.

Na primeira importação, o `settings.json` vem da máquina antiga, e um backup do que havia é guardado como `settings.json.antes-da-migracao-<data>`. As seguintes mantêm o daqui, e o arquivo `~/.claude/.migra-claudinho-importado` marca que ele já veio.

Migração em cadeia (A → B → C): o exportar não leva `.migra-claudinho-*`, `settings.json.antes-da-migracao-*` nem `backup-migracao-*`. Se levasse, a máquina C acharia que já tinha importado e não receberia o `settings.json` da B. O importar também ignora esses nomes se vierem num pacote antigo.

O `~/.claude-mem` guarda um banco SQLite (o arquivo `.db` e os `-wal` e `-shm` ao lado), que o claude-mem pode estar gravando durante a exportação. Com o `sqlite3` instalado, o exportar tira um retrato consistente do banco; sem ele, copia os três arquivos juntos, o que costuma bastar. Na importação, o banco nunca é misturado: se a máquina nova não tem banco, o da antiga entra inteiro; se já tem, o da antiga vai inteiro para o backup, e o relatório explica como trocar com o Claude fechado.

## Login

O Windows e o Linux guardam o login em `.claude/.credentials.json`; o macOS guarda no Keychain. Não copie: entre de novo com `/login` na máquina nova. O Remote Control exige login com conta do claude.ai (Pro, Max, Team ou Enterprise). Não funciona com chave de API nem com `CLAUDE_CODE_OAUTH_TOKEN`.

## Plugins

- `settings.json` → `enabledPlugins` lista os plugins ligados. `extraKnownMarketplaces` lista os marketplaces extras.
- `plugins/known_marketplaces.json` tem a origem de cada marketplace. `plugins/installed_plugins.json` registra o que foi instalado.
- `plugins/cache/` é baixado de novo. O Claude busca sozinho, logo depois de iniciar, os plugins ligados no `settings.json` do usuário. O `claude-plugins-official` entra sozinho na primeira abertura interativa. O importar também roda `claude plugin marketplace add` e `claude plugin install`, por garantia.
- Plugins ligados só no `.claude/settings.json` de um projeto não são baixados sozinhos numa máquina nova. Instale com `claude plugin install <nome>@<marketplace> --scope project`.

## Servidores MCP

| Escopo | Onde fica |
|---|---|
| user | `.claude.json` → `mcpServers` |
| local (um projeto, só nesta máquina) | `.claude.json` → `projects["<caminho>"].mcpServers` |
| project (compartilhado) | `.mcp.json` na raiz do projeto, que viaja com os arquivos |

O exportar guarda os dois primeiros em `mcp.json`, dentro do arquivo compactado. O `manifesto.json` só lista os nomes, para quem o lê não ver chaves de API. O importar os registra de novo com `claude mcp add-json`, trocando a pasta de usuário antiga pela nova. Vindo do Windows para Mac ou Linux, ele também tira o `cmd /c` da frente e avisa sobre o que ainda parecer do Windows. Chaves de API em `env` vão junto, e por isso o pacote é sensível. Logins OAuth não vão: refaça com `/mcp`.

## Claude Desktop

A aba **Code** do Desktop é o Claude Code: lê o mesmo `settings.json`, as mesmas skills de `~/.claude/skills` e grava as conversas no mesmo `~/.claude`. Ela mantém a própria lista de sessões na barra lateral. As que vieram de outro lugar se abrem com `/resume` na caixa de mensagem. Do terminal, `/desktop` ou `claude --desktop --resume <id>` leva uma sessão para o Desktop. As conversas do Desktop e do Cowork não entram na limpeza automática comum (veja acima).

Pasta de dados do app:

| Sistema | Pasta |
|---|---|
| Windows, instalador do site | `%APPDATA%\Claude` |
| Windows, Microsoft Store | `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`. Visto numa máquina real; a Anthropic não documenta. |
| macOS | `~/Library/Application Support/Claude` |
| Linux (beta, só Debian/Ubuntu) | `~/.config/Claude`, provável |

O que o exportar leva dessa pasta (lista fechada, porque o resto é cache, binário ou login):
- `claude_desktop_config.json`: servidores MCP do chat (`mcpServers`) e preferências. Na importação só os servidores entram, e só os que ainda não existem na máquina nova. As preferências ficam as daqui.
- `Claude Extensions/` e `Claude Extensions Settings/`: extensões (.mcpb/.dxt) e suas configurações. A instalação é por usuário, e os campos marcados como sensíveis são criptografados pelo sistema. Por isso, na máquina nova, chaves e senhas precisam ser digitadas de novo. Se uma extensão não aparecer, reinstale o arquivo `.mcpb`.
- `claude-code-sessions/` e `local-agent-mode-sessions/` (menos `skills-plugin/`, que são as skills embutidas): tarefas agendadas locais da aba Code e do Cowork, no arquivo `scheduled-tasks.json`. O Desktop novo já cria esse arquivo vazio, então a importação junta as listas: as tarefas do pacote cujo `id` ainda não existe aqui entram, e o resto do arquivo daqui fica como está. Tarefas novas do Cowork rodam na nuvem; as locais rodam no computador, e por isso precisam ser desligadas na máquina antiga.

Os backups do que a importação muda no Desktop (`claude_desktop_config.json`, `scheduled-tasks.json`) vão para `~/.claude/backup-migracao-<data>/desktop/`, e não para a pasta do Desktop. Ali dentro eles viajariam no próximo pacote.

Fica de fora: `config.json` (guarda o token de login em `oauth:tokenCache`), `Local Storage`, `IndexedDB`, `Network`, `Cache` e afins, `claude-code/` (o Claude Code embutido, que o Desktop baixa de novo) e arquivos de identidade do aparelho (`ant-did`, `ant-device-registry.json`).

O que vem pela conta: conversas do chat, Projects, sessões do Cowork salvas na nuvem e skills, plugins e conectores do Customize. Para Cowork local, o Desktop tem "Export your Cowork data" no card da tela inicial.

O Desktop guarda a configuração na memória e pode regravá-la ao fechar. Por isso a importação não mexe nele enquanto estiver aberto. Feche-o pelo ícone da bandeja (Sair) ou com Cmd+Q, não só fechando a janela.

## O que não tem jeito oficial

Não há comando oficial para levar conversas locais de uma máquina para outra. `--teleport` só puxa sessões da nuvem, e `/export` gera texto, não uma conversa que se possa abrir de novo. O formato dos `.jsonl` é interno e pode mudar entre versões. Mantenha o Claude Code atualizado nas duas pontas.
