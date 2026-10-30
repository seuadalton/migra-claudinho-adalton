# Problemas comuns

## As conversas antigas não aparecem

1. **Pasta errada aberta.** As conversas aparecem na pasta em que foram feitas. Se a pessoa abriu `CLAUDE`, as de `CLAUDE\PROJETOS\App` só aparecem quando ela abrir `App`. A simulação mostra o caminho de cada projeto.
2. **Editor não reiniciado.** Feche todas as janelas do VS Code, do Cursor ou do Antigravity e abra de novo. No Antigravity, confira também se a extensão do Claude Code está instalada nele.
3. **Caminho diferente do mapeado.** Compare o nome da pasta em `~/.claude/projects` com o caminho que o editor abriu, trocando cada caractere que não for letra ou número por `-`. Se não bater (letra do disco diferente, nome com acento, pasta renomeada), rode a importação de novo com um `mapa.json` para o caminho certo. A segunda rodada não duplica nada.
4. **Para abrir uma conversa mesmo assim:** `claude --resume <caminho completo do .jsonl>`.

## O relatório falou de "backup-migracao"

Algum arquivo existia nas duas máquinas com conteúdo diferente: uma memória, o `CLAUDE.md`, uma skill, uma configuração. Ficou no lugar a versão mais nova, e a outra foi guardada em `~/.claude/backup-migracao-<data>/`, com o mesmo caminho relativo. Compare as duas com a pessoa, comece pelas memórias e pelo `CLAUDE.md` e junte o que precisar. Depois, a pasta pode ser apagada, se a pessoa quiser.

## O relatório disse "Não consegui juntar N arquivo(s)"

Esses arquivos estavam abertos por outro programa (o claude-mem, um editor, um antivírus) ou tinham um caminho longo demais para o Windows. Tudo o mais foi importado. Para os que faltaram:
- **Arquivo aberto:** feche o Claude (no editor e no Desktop) e rode a importação de novo pelo terminal. Ela só mexe no que ainda falta.
- **Caminho longo demais (Windows):** o PowerShell 5.1 não aceita caminhos acima de 260 caracteres, a menos que o Windows tenha os caminhos longos ligados. Com a pessoa de acordo, um administrador liga com `Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1` (PowerShell como administrador) e reinicia o computador. Depois, rode de novo.

## O relatório falou do banco do claude-mem

A máquina nova já tinha um banco do claude-mem, e o da antiga não foi misturado com ele, porque um banco SQLite misturado arquivo por arquivo pode corromper. O banco antigo está em `~/.claude/backup-migracao-<data>/home/.claude-mem/`. Se a pessoa quiser usar o antigo no lugar do novo: feche o Claude (o claude-mem para junto), troque os arquivos `.db`, `.db-wal` e `.db-shm` de `~/.claude-mem` pelos do backup e abra o Claude de novo.

## No Claude Desktop

- **As conversas importadas não aparecem na barra lateral da aba Code.** O Desktop lista só as sessões que ele mesmo criou. Digite `/resume` na caixa de mensagem da aba Code para ver as outras.
- **Os servidores MCP do chat não aparecem.** Feche o Desktop de verdade (ícone perto do relógio → Sair, ou Cmd+Q) e abra de novo. Confira em Configurações → Desenvolvedor. Se continuarem faltando, o Desktop estava aberto durante a importação e regravou a configuração por cima. Rode de novo só a parte dele, com o Desktop fechado: `importar.ps1 -Pacote "<pacote>" -SoDesktop` ou `perl migra.pl importar --pacote "<pacote>" --so-desktop`.
- **O script disse "o Claude Desktop está aberto".** Ele deixou `aplicar-claude-desktop.bat` (Mac: `.command`; Linux: `.sh`) dentro do pacote, já com o mapa, se houver. Feche o Desktop e rode o arquivo: dois cliques no Windows e no Mac, `bash aplicar-claude-desktop.sh` num terminal no Linux. Depois abra o Desktop de novo.
- **Uma extensão pede de novo chave ou senha.** É esperado: o sistema da máquina antiga criptografou esses campos. Preencha de novo em Configurações → Extensões.
- **O Desktop diz que não foi encontrado.** Ele precisa ter sido aberto pelo menos uma vez nesta máquina. Abra, entre na conta, feche e rode com `-SoDesktop`.
- **O Claude no chat do Desktop diz que não consegue rodar comandos.** O chat comum e o Cowork não mexem nos arquivos deste computador. Use a aba Code.

## "This Remote Control session's history can't be opened here"

A sessão roda na máquina onde começou, e o claude.ai só mostra a tela. Ela não abre em outro computador. Na máquina nova, abra a conversa importada pelo histórico do editor ou com `claude --resume`. Com `remoteControlAtStartup` ligado, ela volta a aparecer no app, agora vinda da máquina nova.

## PowerShell: "a execução de scripts foi desabilitada neste sistema"

Rode sempre com `powershell -NoProfile -ExecutionPolicy Bypass -File "<script>"`. Se o arquivo veio da internet e o Windows bloqueou, use também `Unblock-File "<script>"`.

## Google Drive

- **Aviso de vírus no download:** o Drive não verifica arquivos grandes. Clique em "Fazer o download assim mesmo".
- **A pasta baixou como vários .zip:** acima de cerca de 2 GB o Drive divide o download. Extraia todos na mesma pasta.
- **No app Google Drive para computador, o arquivo aparece mas não abre:** no modo "streaming", clique com o botão direito → "Disponibilizar off-line" e espere sincronizar.

## Plugin pediu confirmação ou falhou

- Plugins que instalam por comando pedem aprovação, e fora de um terminal interativo a instalação falha. Mostre à pessoa o que o plugin quer rodar e, com o OK dela, rode o comando que o relatório indica (`"<caminho do claude>" plugin install <id> --yes`, com o caminho completo, porque quem só usa o editor ou o Desktop não tem `claude` no terminal), ou use `/plugin` dentro do Claude. Nunca use `--yes` sem a pessoa ter visto o comando.
- Marketplaces do GitHub precisam de internet e, às vezes, do git instalado.
- Plugins ligados no `settings.json` costumam se instalar sozinhos alguns segundos depois de o Claude abrir. Erros aparecem na aba Errors do `/plugin`.

## MCP "já existe" ou não conecta

"Already exists" quer dizer que já estava registrado: pode ignorar. Servidores com login OAuth precisam de `/mcp` → autenticar. Servidores que rodam um programa local (`npx`, `uvx`, `python`) precisam dele instalado na máquina nova.

## "claude" não é reconhecido

A pessoa só tem a extensão do editor ou o Claude Desktop. Para os scripts, isso basta: eles acham o Claude dentro da extensão, do Desktop ou da sessão que está rodando. Para usar no terminal ou deixar a máquina 24h, instale a versão de terminal: rode `claude.exe install` a partir da extensão ou do Desktop (é o que o `instalar-24h.ps1` faz) ou o instalador oficial. Depois, abra um terminal novo.

## O Mac pediu permissão para acessar pastas

Ao ler Documentos, Mesa ou Downloads, o macOS pergunta se o Terminal ou o Claude pode acessar. Clique em Permitir. Se a pessoa negou, libere em Ajustes do Sistema → Privacidade e Segurança → Arquivos e Pastas (ou Acesso Total ao Disco) e rode de novo.

## Conversas sumiram dias depois

É a limpeza automática (`cleanupPeriodDays`, padrão de 30 dias). Confira se o `settings.json` da máquina nova tem um valor maior. A importação põe 365 quando não havia nada.

## Duas máquinas rodando ao mesmo tempo

Bots e serviços com sessão própria (WhatsApp, Telegram, filas, workers) não podem rodar nas duas máquinas. Desligue na antiga assim que a nova estiver no ar. Uma sessão de WhatsApp aberta em dois lugares cai nos dois.
