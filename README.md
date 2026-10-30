# Migra Claudinho

Uma skill do Claude Code que leva o seu Claude de um computador para outro sem perder as conversas.

Quem troca de máquina percebe que copiar a pasta do projeto não basta. O histórico do Claude Code fica na pasta do usuário, organizado pelo caminho de cada projeto. Numa máquina nova, ou com o projeto em outro lugar, as conversas antigas somem da lista. As sessões de Remote Control também não abrem em outro computador ("This Remote Control session's history can't be opened here").

Esta skill resolve isso. Na máquina antiga, ela monta um pacote. Na nova, restaura tudo e corrige os caminhos para as conversas voltarem a aparecer.

## O que ela leva

- conversas do Claude Code (terminal, VS Code, Antigravity, Cursor e aba Code do Claude Desktop) e as memórias de cada projeto
- `settings.json`, `CLAUDE.md`, skills, agents, commands, rules, plugins e servidores MCP
- do Claude Desktop: servidores MCP do chat, extensões e tarefas agendadas
- opcional: deixa a máquina nova ligada 24h com Remote Control, para usar pelo celular

O que não leva, de propósito: os logins (você entra de novo na conta), caches e ambientes como `.venv` e `node_modules`. Conversas do chat, Projects e Cowork na nuvem voltam sozinhas com o login.

Funciona em Windows, macOS e Linux, inclusive entre sistemas diferentes. No Windows usa PowerShell; no Mac e no Linux, Perl, que já vem instalado.

## Como instalar

Copie a pasta `migra-claudinho-adalton` para a pasta de skills do Claude:

| Sistema | Pasta |
|---|---|
| Windows | `C:\Users\<seu nome>\.claude\skills\` |
| macOS | `/Users/<seu nome>/.claude/skills/` |
| Linux | `/home/<seu nome>/.claude/skills/` |

Com git:

```bash
git clone https://github.com/seuadalton/migra-claudinho-adalton.git ~/.claude/skills/migra-claudinho-adalton
```

Feche e abra o Claude de novo.

## Como usar

Na máquina antiga, peça ao Claude com as suas palavras, por exemplo: *"Comprei um computador novo e quero levar meu Claude para lá."* Ele monta o pacote e explica como levá-lo.

Na máquina nova, instale o Claude e entre na mesma conta. Abra o `COLE-NO-CLAUDE.txt` que veio no pacote, copie o texto e cole no Claude. Ele simula antes, mostra o que vai fazer e pergunta antes de mudar qualquer configuração do computador.

No Claude Desktop, use a aba **Code**. O chat comum não roda comandos no computador.

## Cuidados

- **O pacote contém as suas conversas inteiras,** e nelas podem estar senhas e chaves que apareceram durante o trabalho. Guarde-o só em lugar privado, nunca em link público nem no GitHub, e apague-o depois que a máquina nova funcionar. O script se recusa a gravar o pacote dentro de um repositório git.
- **Não rode os mesmos bots e serviços nas duas máquinas ao mesmo tempo.**
- Esta skill mexe em arquivos internos do Claude, cujo formato pode mudar entre versões. Mantenha o Claude atualizado nas duas máquinas.

Projeto independente, sem relação oficial com a Anthropic.

## Licença

MIT. Veja [LICENSE](LICENSE).
