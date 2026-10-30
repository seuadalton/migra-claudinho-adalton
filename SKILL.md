---
name: migra-claudinho-adalton
description: Leva o Claude inteiro de um computador para outro (conversas e sessões antigas do Claude Code, memórias, skills, configurações, plugins, servidores MCP e o que é local do Claude Desktop), ajustando os caminhos para o histórico aparecer na máquina nova, e opcionalmente deixa a máquina nova ligada 24h com Remote Control. Use sempre que alguém disser que trocou de computador, comprou um PC ou notebook novo, vai formatar ou formatou, quer levar, copiar, transferir ou migrar o Claude, o Claude Code, o Claude Desktop, as sessões, o histórico ou as memórias para outra máquina, quer "não depender mais desta máquina", ou viu a mensagem "This Remote Control session's history can't be opened here". Serve para quem usa o terminal, o VS Code, o Cursor, o Antigravity ou o Claude Desktop, em Windows, macOS e Linux, inclusive entre sistemas diferentes, e funciona tanto na máquina antiga (exportar) quanto na nova (importar).
---

# Migra Claudinho

Esta skill leva o Claude de uma pessoa da máquina antiga para a nova, sem perder as conversas. Quem pede isso normalmente não é técnico. Faça você o trabalho técnico e fale com a pessoa em linguagem simples, um passo por vez, no idioma em que ela escreve. Quando precisar que ela faça algo com as mãos (baixar um arquivo, fechar um programa, clicar num botão), diga exatamente onde clicar.

## Por que copiar a pasta do projeto não basta

O Claude Code guarda o histórico fora da pasta do projeto, na pasta do usuário (`~/.claude` no Mac e no Linux, `C:\Users\<nome>\.claude` no Windows). Cada conversa fica num arquivo `.jsonl` dentro de `projects\<nome-da-pasta>`, e esse nome é o caminho do projeto com todo caractere que não é letra ou número trocado por `-`. Se o projeto muda de lugar, ou o nome do usuário muda, as conversas antigas param de aparecer na lista, mesmo que os arquivos estejam lá.

A mesma pasta é usada pelo terminal, pela extensão do Claude Code (no VS Code, no Cursor ou no Antigravity) e pela aba **Code** do Claude Desktop.

Remote Control é o mesmo caso: o Claude roda de verdade no computador onde a sessão começou, e o claude.ai e o app só mostram a tela. Por isso aparece "This Remote Control session's history can't be opened here" em outra máquina. Esses itens antigos na lista do claude.ai continuam presos à máquina antiga. Depois da migração, a pessoa reabre as conversas na máquina nova, e elas aparecem de novo no app por lá.

## O que vai, o que volta sozinho e o que não vai

Vai, dentro do pacote:
- todas as conversas do Claude Code (inclusive as de subagentes e as da aba Code do Desktop) e as memórias de cada projeto
- `settings.json`, `CLAUDE.md` do usuário, skills, agents, commands, rules, workflows, output styles, temas, atalhos de teclado e o histórico de comandos digitados
- o histórico de arquivos usado pelo `/rewind`, os dados de plugins e a pasta `~/.claude-mem`, se existir
- a lista de plugins, marketplaces e servidores MCP (os de usuário e os locais de cada projeto)
- do Claude Desktop: os servidores MCP do chat (`claude_desktop_config.json`), as extensões instaladas e as tarefas agendadas locais do Cowork e da aba Code

Volta sozinho, só de entrar na mesma conta: as conversas do chat, os Projects, os artefatos, as sessões do Cowork salvas na nuvem, os conectores (Gmail, Drive, Calendar etc.) e as skills e plugins do menu Customize.

Não vai, de propósito:
- os logins: o `.credentials.json` do Claude Code e o `config.json` do Claude Desktop, que guarda o token. A pessoa entra de novo na máquina nova, com a mesma conta.
- caches e programas que o Claude baixa de novo sozinho (cache de plugins, o Claude Code embutido no Desktop)
- chaves e senhas digitadas nas extensões do Desktop: o sistema as criptografa na máquina antiga, e elas precisam ser preenchidas de novo
- os logins de servidores MCP com OAuth. Refaça com `/mcp`.
- os arquivos do projeto em si. A pessoa copia à parte; muitas vezes já copiou.
- `.venv`, `node_modules` e outros ambientes instalados. Eles não funcionam copiados e precisam ser recriados.

## Passo 0: entenda a situação

Descubra o sistema operacional você mesmo. Pergunte à pessoa só o que não dá para descobrir:
1. Estamos na máquina antiga ou na nova? Ou é o mesmo computador, que vai ser formatado?
2. Como ela vai levar o pacote: Google Drive, OneDrive, pen drive, HD externo, rede?
3. Os arquivos do projeto já estão na máquina nova? Em que pasta?

Se a pessoa colou o texto do `COLE-NO-CLAUDE.txt`, você está na máquina nova. Vá direto para "Na máquina nova".

**Formatar o mesmo computador:** é o mesmo processo, em dois momentos. Exporte antes de formatar, para um lugar que sobreviva à formatação (pen drive, HD externo, Google Drive ou OneDrive), nunca para o disco que vai ser apagado. Lembre a pessoa de salvar também as pastas dos projetos (Documentos etc.), que não vão no pacote. Confira com ela que tudo chegou lá antes de formatar. Depois da reinstalação, ela devolve as pastas dos projetos, instala o Claude e segue "Na máquina nova".

**Já formatou sem exportar:** no Windows, procure `C:\Windows.old\Users\<nome>\.claude` e `C:\Windows.old\Users\<nome>\.claude.json`, ou um backup da pasta do usuário. Se achar, rode o exportar apontando para eles, com o Claude fechado: defina `CLAUDE_CONFIG_DIR` para a pasta `.claude` encontrada. Depois importe normalmente. Sem isso, as conversas do Claude Code não têm como voltar; o chat, os Projects e o Cowork voltam com o login.

Os scripts precisam rodar comandos neste computador. Se você está num lugar que não roda comandos (o chat comum do Claude Desktop, o claude.ai ou o Cowork), diga à pessoa para abrir a aba **Code** do Claude Desktop, ou o Claude no editor, e pedir lá.

Os scripts ficam na pasta `scripts` ao lado deste arquivo. Abaixo, `<skill>` é a pasta deste SKILL.md.

## Na máquina antiga: exportar

1. Escolha onde o pacote vai ficar, conforme o meio de transporte: uma pasta do Google Drive ou do OneDrive, o pen drive, ou a Área de Trabalho. Não pode ser dentro de um repositório git, porque o pacote contém conversas inteiras e não deve ir para o GitHub. O script se recusa a gravar dentro de um.
2. Rode:
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\exportar.ps1" -Destino "<pasta>"`
   - macOS/Linux: `perl "<skill>/scripts/migra.pl" exportar --destino "<pasta>"`

   No Mac, o sistema pode perguntar se o Terminal ou o Claude pode acessar Documentos, Mesa ou Downloads. Peça à pessoa para clicar em **Permitir**.
3. O script cria em `<pasta>`: `claude-export.zip` (ou `.tar.gz`), `manifesto.json`, uma cópia desta skill em `skill/` e o `COLE-NO-CLAUDE.txt`. Conte à pessoa o tamanho e onde ficou. Se ela usa o Claude Desktop, o resumo também diz quantos servidores MCP, extensões e tarefas agendadas dele foram junto.
4. Explique como levar o pacote:
   - Google Drive ou OneDrive com o aplicativo instalado: grave o pacote direto numa pasta dele e espere o ícone mostrar que terminou de enviar antes de desligar este computador.
   - Google Drive ou OneDrive só pelo site: abra drive.google.com (ou onedrive.live.com), clique em **Novo** → **Upload de pasta**, escolha a pasta do pacote e espere terminar.
   - Na máquina nova, pelo site, clique com o botão direito na pasta e escolha **Fazer download**. Se aparecer o aviso de vírus, clique em **Fazer o download assim mesmo**. Pastas grandes podem vir em mais de um `.zip`.
   - Pen drive ou HD externo: copie a pasta inteira e use "Ejetar" antes de tirar.
5. Avise que o histórico levado termina agora. O que for conversado aqui depois não vai junto, a menos que se exporte de novo.
6. Diga à pessoa o que fazer na máquina nova, nesta ordem:
   1. instalar o Claude e entrar na mesma conta
   2. trazer a pasta do pacote
   3. abrir o `COLE-NO-CLAUDE.txt`, copiar todo o texto e colar no Claude de lá

   Avise que, se o Claude dela for o Desktop, é para colar na aba Code.
7. Não desligue nada na máquina antiga ainda. Espere a nova funcionar.

## Na máquina nova: importar

Antes, as pastas dos projetos já devem estar nesta máquina, no lugar onde vão ficar; pergunte onde. E a pessoa precisa ter o Claude instalado e logado com a mesma conta:
- quem usa editor: a extensão do Claude Code no VS Code, no Cursor ou no Antigravity já basta para começar
- quem usa o Claude Desktop: instale, entre na conta e abra uma vez, para ele criar a pasta dele. Rode esta skill pela aba **Code**.
- quem não usa nenhum dos dois: os instaladores oficiais são `irm https://claude.ai/install.ps1 | iex` (PowerShell) e `curl -fsSL https://claude.ai/install.sh | bash` (macOS/Linux)

1. **Ache o pacote**: a pasta com `claude-export.*` e `manifesto.json`. Procure em Downloads, no Drive, no OneDrive e no pen drive. Se ele chegou dentro de outro `.zip` (o Google Drive faz isso), extraia antes. Abaixo, `<pacote>` é essa pasta. No Mac, o sistema pode perguntar se o Terminal, o editor ou o Claude pode acessar Downloads, Documentos, Mesa ou o pen drive: peça para clicar em **Permitir**.
2. **Simule primeiro.** Nada muda nesta etapa, e o resultado já mostra cada projeto e quantas conversas ele tem:
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<pacote>\skill\scripts\importar.ps1" -Pacote "<pacote>" -Simular`
   - macOS/Linux: `perl "<pacote>/skill/scripts/migra.pl" importar --pacote "<pacote>" --simular`

   Para cada projeto antigo aparecem o caminho proposto aqui e a situação:
   - `mesmo caminho` ou `home trocada`: está certo.
   - `mapeado`: veio do seu mapa ou de uma pasta mãe já resolvida.
   - `pasta nao existe (normal para worktree apagado)`: worktrees antigos que não existem mais. Pode seguir.
   - `NAO ENCONTRADO`: o projeto não está onde se esperava, nem dentro da pasta mãe já mapeada. O script mostra sugestões de pastas com o mesmo nome. Confirme com a pessoa onde aquele projeto está agora.
   - `PASTA NAO EXISTE: confira o mapa`: o mapa manda o projeto para uma pasta que não existe aqui (erro de digitação, pasta ainda não copiada). Corrija o mapa ou copie a pasta antes de importar.

   No fim aparece uma linha sobre o Claude Desktop: o que veio no pacote, onde ele está nesta máquina e se está aberto agora.
3. **Monte o mapa** quando houver `NAO ENCONTRADO`, ou quando a pessoa disser que um projeto mudou de lugar. É um JSON com o caminho antigo à esquerda e o novo à direita. Cada regra vale para a pasta e tudo dentro dela, então mapear a pasta raiz já resolve os subprojetos que estão dentro dela. Grave o mapa como `<pacote>\mapa.json`:
   ```json
   {
     "C:\\Users\\maria\\Documents\\CLAUDE": "D:\\Projetos\\CLAUDE",
     "C:\\Users\\maria\\Documents\\CLAUDE_CODE": "D:\\Projetos\\CLAUDE\\CLAUDE_CODE"
   }
   ```
   Simule de novo com `-Mapa "<pacote>\mapa.json"` (`--mapa` no Mac e no Linux) até não sobrar `NAO ENCONTRADO` importante. Um projeto que não for encontrado também é importado, com o nome antigo. As conversas não se perdem e continuam abrindo com `claude --resume <caminho do .jsonl>`, mas não aparecem na lista.
4. **Importe de verdade**: o mesmo comando, sem `-Simular`. O script:
   - corrige os caminhos dentro das conversas e as coloca nas pastas certas, com o mesmo nome de pasta que o Claude usa, inclusive para caminhos muito longos
   - junta o índice de memórias (`MEMORY.md`) e o histórico de comandos das duas máquinas
   - nunca perde arquivo: se o mesmo arquivo mudou nas duas máquinas, fica o mais novo, e o outro vai para `~/.claude/backup-migracao-<data>`. O relatório avisa quando isso acontece; olhe com a pessoa se algo dali precisa voltar (memórias e `CLAUDE.md` primeiro). Ao rodar de novo, o que a pessoa apagou ou mudou só nesta máquina continua como ela deixou.
   - não mistura o banco do claude-mem: se esta máquina já tem um, o da antiga vai inteiro para o backup, e o relatório explica como trocar.
   - na primeira vez, traz o `settings.json` da máquina antiga, com um backup do que havia aqui, e troca dentro dele o caminho da pasta de usuário antiga pelo da nova. Nas vezes seguintes, mantém o desta máquina.
   - define 365 dias para o Claude guardar as conversas (`cleanupPeriodDays`), se ninguém tinha definido. O padrão do Claude é apagar as que têm mais de 30 dias. As conversas do Claude Desktop e do Cowork já ficam fora dessa limpeza. Use `-DiasHistorico <n>` para outro valor, ou `0` para não mexer.
   - reinstala marketplaces e plugins, registra os servidores MCP (com a pasta de usuário trocada) e confere o `settings.json` com `claude doctor`
   - no Claude Desktop: acrescenta os servidores MCP do chat que ainda não existem aqui (os daqui nunca são trocados), copia as extensões, junta as tarefas agendadas às que já existem aqui e troca os caminhos dentro delas

   Pode rodar de novo quantas vezes precisar, por exemplo depois de corrigir o mapa ou trazer um pacote mais novo.

   **Se o Claude Desktop estiver aberto**, o script não mexe nele, porque o Desktop regravaria a configuração por cima. No lugar disso, ele deixa no pacote um `aplicar-claude-desktop.bat` (Mac: `.command`; Linux: `.sh`) e avisa. Peça à pessoa que feche o Desktop de verdade (Windows: ícone do Claude perto do relógio → Sair; Mac: Cmd+Q), rode esse arquivo (no Windows e no Mac, com dois cliques) e abra o Desktop de novo. Se você estiver rodando dentro do Desktop, faça antes o passo 6, porque esta conversa vai fechar junto. Ela continua depois na barra lateral da aba Code; diga à pessoa para voltar e escrever "pronto".
5. **Confira o relatório.** Se um plugin pedir aprovação de um comando, mostre à pessoa o que ele quer rodar e, com o OK dela, rode o comando que o relatório indica (`"<caminho do claude>" plugin install <id> --yes`). O caminho completo importa: quem só usa o editor ou o Desktop não tem `claude` no terminal. Se o relatório disser que não conseguiu juntar algum arquivo por estar aberto, feche o Claude e rode a importação de novo pelo terminal. Servidores MCP com login precisam de `/mcp`. Extensões do Desktop podem pedir de novo as chaves e senhas. Se a CLI não estava disponível, o script avisa; plugins listados no `settings.json` costumam se instalar sozinhos no próximo início.
6. **Antes de a pessoa reiniciar o editor ou o Desktop**, passe o que falta, porque esta conversa pode fechar junto:
   - como achar as conversas antigas (passo 7)
   - o que desligar e apagar na máquina antiga ("Fechando a máquina antiga", abaixo)
   - se ela quiser, a máquina 24h
7. **Mostre o resultado à pessoa**: ela fecha e abre de novo o editor ou o Desktop (todas as janelas) e abre a pasta do projeto.
   - No editor: ícone de histórico do painel do Claude.
   - No terminal: `claude --resume` dentro da pasta.
   - No Claude Desktop: a barra lateral da aba Code mostra só as sessões dele. Para achar as importadas, digite `/resume` na caixa de mensagem.

   As conversas aparecem na pasta em que foram feitas. A de um subprojeto só aparece quando o subprojeto é aberto.

Se algo não bater, veja [references/problemas.md](references/problemas.md). Para detalhes de onde cada coisa fica, veja [references/o-que-fica-onde.md](references/o-que-fica-onde.md).

## Máquina ligada 24h (opcional)

Se a máquina nova vai ficar ligada direto para a pessoa usar o Claude pelo celular ou pelo claude.ai, configure o Remote Control em modo servidor. Ele exige plano Pro, Max, Team ou Enterprise, não funciona com chave de API e precisa do Claude Code de terminal. O Claude Desktop também tem `/remote-control` na aba Code, mas só enquanto ele estiver aberto. O modo servidor do terminal reinicia sozinho e é mais confiável para 24h.

- Windows: pergunte à pessoa se pode impedir o PC de dormir na tomada (inclusive ao fechar a tampa, se for notebook) e abrir o Claude ao ligar. Depois rode `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\instalar-24h.ps1" -Pasta "<pasta do projeto>" -Atalho -SemSuspensao`.
  - Se faltar o Claude de terminal, o script o instala, usando o Claude da extensão do editor ou do Desktop. Se ele ainda não entrou na conta (é o caso de quem só usava o Desktop), o script avisa. A pessoa precisa rodar uma vez `"<caminho do claude>" auth login` num terminal e entrar com a mesma conta.
  - Ele cria `%LOCALAPPDATA%\ClaudeRemoteControl\remote-control-24h.bat`. Esse arquivo espera a pasta do projeto aparecer (o Google Drive monta o `G:` só depois do login) e reabre o Remote Control se ele cair.
  - Peça à pessoa que dê dois cliques nele uma vez e responda o que ele perguntar. Depois disso, ele abre sozinho a cada login.
  - Se o PC reiniciar por queda de luz ou atualização, ele só volta depois que alguém entrar na conta do Windows. As saídas para isso estão em [references/maquina-24h.md](references/maquina-24h.md).
- macOS/Linux: siga [references/maquina-24h.md](references/maquina-24h.md).

A configuração `"remoteControlAtStartup": true` no `settings.json` (em `/config`: "Enable Remote Control for all sessions") faz qualquer sessão aberta naquela máquina aparecer no app. Se ela já existia na máquina antiga, veio junto.

## Fechando a máquina antiga

Só depois que a nova estiver funcionando:
1. Desligue na máquina antiga os bots, workers, conexões de WhatsApp, tarefas agendadas do Claude Desktop (Cowork e aba Code) e o Remote Control. Dois computadores rodando o mesmo serviço brigam entre si: sessões de WhatsApp caem, mensagens saem duplicadas, tarefas rodam duas vezes.
2. Apague o pacote do Drive, do OneDrive ou do pen drive. Ele contém as conversas inteiras, e nelas pode haver senhas e chaves que apareceram durante o trabalho. Até ser apagado, ele só pode ficar em lugar privado, nunca em link público nem no GitHub.
3. A pasta `.claude` da máquina antiga pode ficar como backup.

## Cuidados que valem a pena dizer à pessoa

- Projetos que rodam 24h (bots, workers, bancos locais) não devem rodar de dentro de uma pasta sincronizada (Google Drive, OneDrive, Dropbox). O `.git`, a `.venv` e os dados mudam o tempo todo, e a sincronização gera conflitos e arquivos corrompidos. Prefira uma pasta local, com git privado para guardar o código.
- Mantenha o Claude atualizado nas duas máquinas. O formato interno das conversas pode mudar entre versões.

## Para outra pessoa usar esta skill

A skill está em https://github.com/seuadalton/migra-claudinho-adalton, com instruções no README. Basta copiar a pasta `migra-claudinho-adalton` para `~/.claude/skills/` (Windows: `C:\Users\<nome>\.claude\skills\`) na máquina antiga e reabrir o Claude. Na máquina nova não precisa instalar nada: o pacote já leva uma cópia da skill.
