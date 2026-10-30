# Máquina ligada 24h com Remote Control

`claude remote-control` roda o Claude nesta máquina como um servidor. A pessoa conversa pelo claude.ai/code ou pelo app do celular, e o trabalho acontece aqui. Para isso funcionar sem ninguém por perto, a máquina precisa ficar acordada, o comando precisa reabrir se cair, e ele precisa iniciar sozinho quando o computador liga.

Requisitos: plano Pro, Max, Team ou Enterprise (no Team e no Enterprise, um admin precisa liberar), login com conta do claude.ai e o Claude Code de terminal. O Remote Control fica indisponível com `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` ou `DISABLE_GROWTHBOOK` definidos (no ambiente ou no bloco `env` do `settings.json`): remova-os. `DISABLE_TELEMETRY` e `DO_NOT_TRACK` não atrapalham, a menos que a organização exija Trusted Devices.

Antes de automatizar, rode `claude remote-control` uma vez na mão, num terminal aberto na pasta do projeto, e responda o que ele perguntar. Só depois coloque para iniciar sozinho. Se ele disser "You must be logged in", o Claude de terminal ainda não entrou na conta. Isso acontece com quem só usava o Desktop. Rode `claude auth login` e entre com a mesma conta.

Quem usa o Claude Desktop também pode digitar `/remote-control` (ou `/rc`) na aba Code. O Dispatch (Pro e Max) deixa o celular mandar tarefas para o Cowork daquela máquina. Os dois só funcionam com o Desktop aberto e não reabrem sozinhos se ele fechar. Para uma máquina 24h, o servidor de terminal abaixo é mais confiável. Nada impede usar os dois.

Opções úteis: `--permission-mode` (por exemplo `acceptEdits`) para as sessões abertas pelo app, e `--spawn worktree` para cada sessão ganhar sua própria cópia git do projeto. Lembre a pessoa de que qualquer um com acesso à conta dela no claude.ai pode mandar essa máquina rodar comandos. Vale ativar a verificação em duas etapas da conta.

## Windows

Use `scripts/instalar-24h.ps1` (veja o SKILL.md). Ele:
- cria `%LOCALAPPDATA%\ClaudeRemoteControl\remote-control-24h.bat`, numa pasta local, porque uma pasta do Google Drive pode ainda não existir na hora do login
- espera a pasta do projeto aparecer, abre o Remote Control nela e o reabre se cair
- com `-Atalho`, põe o `.bat` na Inicialização
- com `-SemSuspensao`, impede que o PC durma, hiberne ou suspenda ao fechar a tampa quando estiver na tomada

Se o projeto estiver numa pasta sincronizada, o script avisa: bots 24h ali dentro costumam dar conflito.

A pasta Inicialização só roda depois que alguém faz login. Se o PC reiniciar por queda de luz ou atualização, ele fica parado na tela de login até alguém entrar. Há duas saídas, as duas com custo. Explique à pessoa antes:
- Login automático (Sysinternals Autologon ou `netplwiz`): qualquer um que ligar o PC entra na conta.
- Na BIOS, "Restore on AC power loss" = On, para ligar sozinho quando a luz volta. Ainda depende do login automático.

## macOS

O Claude não consegue digitar senha de administrador. Os comandos com `sudo` abaixo, a pessoa roda no app Terminal, e ele pede a senha do Mac.

1. Para não dormir: em Ajustes do Sistema → Bateria (ou Energia), marque "Impedir repouso automático com a tela desligada" quando estiver na tomada. Ou, no Terminal: `sudo pmset -c sleep 0`. Num MacBook, isso não vale para a tampa: fechar a tampa faz o Mac dormir. Deixe-a aberta, ou use monitor externo, teclado e carregador ligados (modo "clamshell").
2. Para iniciar no login e reabrir se cair, crie `~/Library/LaunchAgents/com.claude.remote-control.plist`. O `PATH` precisa estar ali, porque o launchd não carrega o do Terminal:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>Label</key><string>com.claude.remote-control</string>
     <key>ProgramArguments</key><array>
       <string>/Users/NOME/.local/bin/claude</string><string>remote-control</string>
     </array>
     <key>WorkingDirectory</key><string>/Users/NOME/PASTA-DO-PROJETO</string>
     <key>EnvironmentVariables</key><dict>
       <key>PATH</key><string>/Users/NOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
     </dict>
     <key>RunAtLoad</key><true/>
     <key>KeepAlive</key><true/>
     <key>StandardOutPath</key><string>/tmp/claude-remote-control.log</string>
     <key>StandardErrorPath</key><string>/tmp/claude-remote-control.log</string>
   </dict></plist>
   ```
   Ative com `launchctl load ~/Library/LaunchAgents/com.claude.remote-control.plist`.
3. O LaunchAgent só sobe depois que a pessoa entra na conta, e é isso que deixa o Claude achar o login no Keychain.

O comportamento do `remote-control` fora de um terminal interativo não foi testado. Se o log mostrar que ele pede um terminal, use o app Terminal com `caffeinate -dimsu claude remote-control`, aberto em "Itens de Início de Sessão".

## Linux

Os comandos com `sudo`, a pessoa roda num terminal, e ele pede a senha.

1. Para não dormir: `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
2. Serviço de usuário em `~/.config/systemd/user/claude-remote-control.service`:
   ```ini
   [Unit]
   Description=Claude Remote Control

   [Service]
   WorkingDirectory=%h/PASTA-DO-PROJETO
   Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
   ExecStart=%h/.local/bin/claude remote-control
   Restart=always
   RestartSec=15

   [Install]
   WantedBy=default.target
   ```
   Se os servidores MCP usam `npx` ou `node` instalados por nvm, acrescente ao `PATH` a pasta que `dirname $(which node)` mostrar. Ative com `systemctl --user daemon-reload && systemctl --user enable --now claude-remote-control`.
3. `sudo loginctl enable-linger $USER` faz o serviço subir no boot, sem login.

Como no macOS, rodar sem terminal não foi testado. Se falhar, use `tmux new -d -s claude 'claude remote-control'` num script de login.
