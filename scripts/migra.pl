#!/usr/bin/env perl
# Migra Claudinho para macOS e Linux: o mesmo trabalho que exportar.ps1 e importar.ps1 fazem no Windows.
#   perl migra.pl exportar [--destino PASTA]
#   perl migra.pl importar [--pacote PASTA] [--mapa ARQUIVO] [--simular] [--sem-plugins] [--dias-historico N]
#                          [--so-desktop] [--sem-desktop]
# Usa so o Perl e os modulos que vem com ele, mais tar (e unzip, bsdtar ou python3 para pacotes .zip do Windows).
# Caminhos e JSON sao tratados como bytes do comeco ao fim, para nao estragar acentos.
# A importacao pode rodar quantas vezes for preciso: quando o mesmo arquivo mudou nos dois lados,
# o mais novo fica no lugar e o outro vai para ~/.claude/backup-migracao-<data>.
use strict;
use warnings;
use JSON::PP;
use Encode qw(decode_utf8);
use File::Find;
use File::Copy qw(copy cp);
use File::Glob qw(bsd_glob);   # o glob comum quebra em caminhos com espaco
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use Getopt::Long;
use POSIX qw(strftime);
use Sys::Hostname;

my $HOME = $ENV{HOME} or die "HOME nao definido\n";
my $CLAUDE_DIR = $ENV{CLAUDE_CONFIG_DIR} || "$HOME/.claude";
my $CONFIG_GLOBAL = $ENV{CLAUDE_CONFIG_DIR} ? "$ENV{CLAUDE_CONFIG_DIR}/.claude.json" : "$HOME/.claude.json";
my $SKILL_DIR = dirname(dirname(abs_path($0)));
my $J = JSON::PP->new->canonical->pretty;
my $J1 = JSON::PP->new->allow_nonref;
my $CARIMBO = strftime('%Y%m%d-%H%M%S', localtime);

# Coisas desta maquina que nao fazem sentido em outra (sessoes abertas, travas, caches, login)
my %NAO_LEVAR = map { $_ => 1 } qw(cache plugins shell-snapshots session-env sessions ide statsig telemetry
    backups state security debug local paste-cache image-cache .credentials.json .last-cleanup
    mcp-needs-auth-cache.json .claude.json);

# Marcas e backups de uma migracao anterior: nao viajam, senao a proxima maquina acharia
# que a importacao ja tinha rodado ali
my $MARCAS = qr/^(\.migra-claudinho-|settings\.json\.antes-da-migracao|backup-migracao-)/;

# O que e do usuario no Claude Desktop. O resto da pasta e cache, binario ou login
# (o config.json, por exemplo, guarda o token em oauth:tokenCache).
my @DESKTOP_PASTAS = ('Claude Extensions', 'Claude Extensions Settings', 'claude-code-sessions', 'local-agent-mode-sessions');

# Interrompido (Ctrl+C, terminal fechado, tempo esgotado): sai pelo caminho normal, para a
# pasta temporaria ser apagada. Restos de execucoes mortas a forca sao limpos ao comecar.
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { exit 130 };
for my $resto (bsd_glob("$HOME/.migra-claudinho-export-*"), bsd_glob("$HOME/.migra-claudinho-import-*")) {
    File::Path::remove_tree($resto) if -d $resto && -M $resto > 1;
}

my $acao = shift(@ARGV) // '';
if    ($acao eq 'exportar') { exportar() }
elsif ($acao eq 'importar') { importar() }
else  { die "Uso: perl migra.pl exportar|importar [opcoes]\n" }
exit 0;

# --- Utilidades -------------------------------------------------------------------

sub ler_arquivo {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "Nao consegui ler $f: $!\n";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

sub gravar_arquivo {
    my ($f, $t) = @_;
    open my $fh, '>:raw', $f or die "Nao consegui gravar $f: $!\n";
    print $fh $t;
    close $fh;
}

sub ler_json { my ($f) = @_; return -f $f ? $J->decode(ler_arquivo($f)) : undef }
sub json_desescapar { my ($s) = @_; return $J1->decode(qq("$s")) }
sub json_escapar { my ($s) = @_; return $J1->encode($s) }
sub existe_comando { my ($c) = @_; return system("command -v '$c' >/dev/null 2>&1") == 0 }

# cp (e nao copy) mantem as permissoes: hooks e statusline continuam executaveis. Copia
# por um temporario e renomeia, para uma copia interrompida nunca deixar arquivo pela metade.
sub copiar_arquivo {
    my ($de, $para) = @_;
    make_path(dirname($para));
    cp($de, "$para.migra-tmp") or die "Falha copiando $de: $!\n";
    rename("$para.migra-tmp", $para) or die "Falha copiando $de: $!\n";
    my $mtime = (stat $de)[9];
    utime $mtime, $mtime, $para;
}

# Copia a arvore $de para $para (que esta vazia), seguindo links. Pula, no primeiro
# nivel, os nomes em %$excluir e os que casarem com $excluir_re.
sub copiar_arvore {
    my ($de, $para, $excluir, $excluir_re) = @_;
    return unless -d $de;
    $de = abs_path($de) // $de;
    $excluir ||= {};
    no warnings 'File::Find';
    find({ no_chdir => 1, follow => 1, follow_skip => 2, wanted => sub {
        my $rel = substr($File::Find::name, length $de);
        $rel =~ s{^/}{};
        return if $rel eq '';
        my ($primeiro) = split m{/}, $rel;
        if ($excluir->{$primeiro} || ($excluir_re && $primeiro =~ $excluir_re)) { $File::Find::prune = 1; return }
        if (-d $_) { make_path("$para/$rel"); return }
        copiar_arquivo($_, "$para/$rel") if -f $_;
    } }, $de);
}

# O conteudo de $menor e exatamente o comeco de $maior?
sub comeca_com {
    my ($maior, $menor) = @_;
    return 0 if -s $menor > -s $maior;
    open my $fa, '<:raw', $maior or return 0;
    open my $fb, '<:raw', $menor or return 0;
    my ($ba, $bb);
    while ((my $n = read($fb, $bb, 65536)) > 0) {
        my $k = read($fa, $ba, $n);
        return 0 unless defined $k && $k == $n && $ba eq $bb;
    }
    return 1;
}
sub iguais { my ($x, $y) = @_; return -s $x == -s $y && comeca_com($x, $y) }

# Indice do que as importacoes anteriores instalaram (tamanho e data de cada arquivo do
# pacote). Com ele, rodar de novo nao traz de volta o que a pessoa apagou aqui, nem guarda
# em backup o que so mudou nesta maquina.
my %INDICE;
my @EM_USO;
sub assinatura { my @s = stat $_[0]; return "$s[7]|$s[9]" }

# Junta $de em $para sem perder nada:
#   - arquivo que so existe no pacote entra (a nao ser que uma importacao anterior ja o
#     tenha instalado e a pessoa o apagou aqui)
#   - se o daqui mudou e o do pacote e o mesmo da ultima importacao, fica o daqui
#   - se os dois lados mudaram, fica o mais novo e o outro vai para $backup/$nome/...
#   - conversas so crescem: se uma e o comeco da outra, fica a maior, sem backup
# Devolve quantos arquivos foram para o backup.
sub mesclar_arvore {
    my ($de, $para, $nome, $backup, $pular, $pular_re) = @_;
    return 0 unless -d $de;
    $pular ||= {};
    $de =~ s{/+$}{};
    my $guardados = 0;
    no warnings 'File::Find';
    find({ no_chdir => 1, wanted => sub {
        my $rel = substr($File::Find::name, length $de);
        $rel =~ s{^/}{};
        return if $rel eq '';
        my ($primeiro) = split m{/}, $rel;
        if ($pular->{$primeiro} || ($pular_re && $primeiro =~ $pular_re)) { $File::Find::prune = 1; return }
        return unless -f $_;
        my ($f, $alvo, $chave) = ($_, "$para/$rel", "$nome/$rel");
        my $ok = eval {
            my $sig = assinatura($f);
            my $antes = $INDICE{$chave};
            my $jsonl = $rel =~ /\.jsonl$/;
            if (!-e $alvo) {
                # Se e igual ao que a ultima importacao instalou, a pessoa apagou aqui
                copiar_arquivo($f, $alvo) unless defined $antes && $antes eq $sig;
            } elsif (defined $antes && $antes eq $sig) {
                # O pacote nao mudou desde a ultima importacao: se o daqui esta diferente,
                # quem mudou foi a pessoa, aqui. Nem precisa abrir o arquivo.
            } elsif (iguais($f, $alvo)) {
            } elsif ($jsonl && comeca_com($alvo, $f)) {
            } elsif ($jsonl && comeca_com($f, $alvo)) {
                copiar_arquivo($f, $alvo);
            } else {
                my $pacote_ganha = (stat $f)[9] > (stat $alvo)[9];
                copiar_arquivo($pacote_ganha ? $alvo : $f, "$backup/$nome/$rel");
                $guardados++;
                copiar_arquivo($f, $alvo) if $pacote_ganha;
            }
            $INDICE{$chave} = $sig;   # so depois de dar certo
            1;
        };
        push @EM_USO, "$nome/$rel (" . ($@ =~ s/\s+$//r) . ")" unless $ok;
    } }, $de);
    return $guardados;
}

sub listar {
    my ($d, $re) = @_;
    opendir my $dh, $d or return wantarray ? () : 0;
    my @r = sort grep { $_ ne '.' && $_ ne '..' && /$re/ } readdir $dh;
    closedir $dh;
    return wantarray ? @r : scalar @r;
}

sub ler_cwd {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    while (my $l = <$fh>) {
        if ($l =~ /"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/) { close $fh; return json_desescapar($1) }
    }
    close $fh;
    return undef;
}

# Junta as linhas de dois arquivos sem repetir, mantendo as daqui primeiro
sub mesclar_linhas {
    my ($do_pacote, $daqui) = @_;
    return unless -f $do_pacote && -f $daqui;
    my (%visto, @saida);
    for my $l (split /\r?\n/, ler_arquivo($daqui) . "\n" . ler_arquivo($do_pacote)) {
        push @saida, $l if $l =~ /^\s*$/ || !$visto{$l}++;
    }
    gravar_arquivo($daqui, join("\n", @saida) . "\n");
    unlink $do_pacote;
}

sub nome_do_so { return $^O eq 'darwin' ? 'macos' : $^O eq 'MSWin32' ? 'windows' : $^O }

# Mesmo esquema que o Claude Code 2.1 usa para nomear as pastas em projects/: troca o que
# nao e letra ou numero por '-' (por unidade UTF-16, como o JavaScript) e, acima de 200
# caracteres, corta e soma um hash do caminho em base 36.
sub hash36 {
    my ($s) = @_;
    my @cu = map { my $o = ord; $o > 0xFFFF ? (0xD800 + (($o - 0x10000) >> 10), 0xDC00 + (($o - 0x10000) & 0x3FF)) : $o } split //, $s;
    my $h = 0;
    $h = ($h * 31 + $_) % 4294967296 for @cu;
    $h -= 4294967296 if $h >= 2147483648;
    $h = abs $h;
    my $b36 = '';
    do { $b36 = (0 .. 9, 'a' .. 'z')[$h % 36] . $b36; $h = int($h / 36) } while $h > 0;
    return $b36;
}
sub nome_da_pasta {
    my ($caminho) = @_;
    my $s = $caminho =~ /[^\x00-\xff]/ ? $caminho : decode_utf8($caminho);
    (my $n = $s) =~ s/([^a-zA-Z0-9])/ord($1) > 0xFFFF ? '--' : '-'/ge;
    return length($n) <= 200 ? $n : substr($n, 0, 200) . '-' . hash36($s);
}

# Pasta de dados do Claude Desktop (no Linux ele ainda e beta, so Debian/Ubuntu)
sub achar_desktop {
    my $d = $ENV{MIGRA_DESKTOP_DIR} || ($^O eq 'darwin' ? "$HOME/Library/Application Support/Claude" : "$HOME/.config/Claude");
    return -d $d ? $d : undef;
}
sub desktop_aberto {
    return 0 if $ENV{MIGRA_DESKTOP_DIR};   # testes
    # Os colchetes evitam que o pgrep ache o proprio shell que o chamou
    my $padrao = $^O eq 'darwin' ? '[C]laude.app/Contents/MacOS/Claude' : '[c]laude-desktop';
    return system("pgrep -f '$padrao' >/dev/null 2>&1") == 0;
}

# Pasta para o trabalho temporario: na home, e nao no /tmp, que em varias distros fica na memoria
sub pasta_temporaria {
    my $modelo = ".migra-claudinho-$_[0]-XXXXXX";
    return -d $HOME && -w $HOME ? tempdir($modelo, DIR => $HOME, CLEANUP => 1) : tempdir($modelo, TMPDIR => 1, CLEANUP => 1);
}

# --- Exportar ---------------------------------------------------------------------

sub exportar {
    my $mesa = "$HOME/Desktop";
    if ($^O ne 'darwin' && existe_comando('xdg-user-dir')) {   # "Area de Trabalho" etc.
        my $x = `xdg-user-dir DESKTOP 2>/dev/null`;
        $x =~ s/\s+$//;
        $mesa = $x if $x && -d $x;
    }
    $mesa = $HOME unless -d $mesa;
    my $destino = "$mesa/Migracao-Claude";
    GetOptions('destino=s' => \$destino) or die "Opcao invalida\n";
    die "Nao achei conversas em $CLAUDE_DIR/projects. O Claude Code ja foi usado neste usuario?\n" unless -d "$CLAUDE_DIR/projects";
    make_path($destino);
    $destino = abs_path($destino);
    for (my $p = $destino; ; $p = dirname($p)) {
        die "$destino fica dentro de um repositorio git ($p). O pacote tem conversas inteiras e nao pode ir para o git. Escolha outra pasta.\n" if -e "$p/.git";
        last if $p eq dirname($p);
    }

    my $tmp = pasta_temporaria('export');
    print "Copiando conversas, memorias e configuracoes...\n";
    copiar_arvore($CLAUDE_DIR, "$tmp/claude", \%NAO_LEVAR, $MARCAS);
    copiar_arvore("$CLAUDE_DIR/plugins/data", "$tmp/claude/plugins/data");
    copiar_arvore("$HOME/.claude-mem", "$tmp/home/.claude-mem");
    # O banco do claude-mem pode estar sendo gravado agora. Com o sqlite3 instalado, troca a
    # copia por um retrato consistente dele; sem o sqlite3, o -wal copiado junto costuma bastar.
    if (existe_comando('sqlite3')) {
        for my $db (grep { /\.db$/ && -f "$HOME/.claude-mem/$_" } listar("$HOME/.claude-mem", qr/./)) {
            my $copia = "$tmp/home/.claude-mem/$db";
            my @partes = map { "$copia$_" } ('', '-wal', '-shm');
            unlink @partes;
            next if system('sqlite3', "$HOME/.claude-mem/$db", ".backup '" . ($copia =~ s/'/''/gr) . "'") == 0;
            -f "$HOME/.claude-mem/$db$_" and copiar_arquivo("$HOME/.claude-mem/$db$_", "$copia$_") for ('', '-wal', '-shm');
        }
    }

    my $desktop;
    if (my $dd = achar_desktop()) {
        print "Copiando o que e seu no Claude Desktop...\n";
        make_path("$tmp/desktop");
        copiar_arquivo("$dd/claude_desktop_config.json", "$tmp/desktop/claude_desktop_config.json") if -f "$dd/claude_desktop_config.json";
        for my $sub (@DESKTOP_PASTAS) {
            # skills-plugin sao as skills embutidas, que o Desktop recria sozinho
            copiar_arvore("$dd/$sub", "$tmp/desktop/$sub", $sub eq 'local-agent-mode-sessions' ? { 'skills-plugin' => 1 } : undef);
        }
        my $cfg = ler_json("$dd/claude_desktop_config.json") || {};
        my $tarefas = 0;
        find({ no_chdir => 1, wanted => sub {
            return unless basename($_) eq 'scheduled-tasks.json';
            my $t = eval { ler_json($_) };
            $tarefas += @{ $t->{scheduledTasks} } if ref $t eq 'HASH' && ref $t->{scheduledTasks} eq 'ARRAY';
        } }, "$tmp/desktop");
        $desktop = {
            pasta      => $dd,
            mcpServers => [sort keys %{ $cfg->{mcpServers} || {} }],
            extensoes  => [grep { -d "$dd/Claude Extensions/$_" } listar("$dd/Claude Extensions", qr/./)],
            tarefas    => $tarefas,
        };
    }

    print "Montando o manifesto...\n";
    my (@projetos, $total);
    $total = 0;
    for my $nome (listar("$CLAUDE_DIR/projects", qr/./)) {
        my $dir = "$CLAUDE_DIR/projects/$nome";
        next unless -d $dir;
        my @jsonl;
        find({ no_chdir => 1, follow => 1, follow_skip => 2, wanted => sub { push @jsonl, $_ if /\.jsonl$/ && -f $_ } }, $dir);
        my $cwd;
        for my $f (sort { length($a) <=> length($b) } @jsonl) { last if defined($cwd = ler_cwd($f)) }
        my $sessoes = 0 + grep({ -f "$dir/$_" } listar($dir, qr/\.jsonl$/));
        $total += $sessoes;
        push @projetos, { pasta => $nome, cwd => $cwd, sessoes => $sessoes, memorias => 0 + listar("$dir/memory", qr/\.md$/) };
    }
    my $copiadas = 0;
    for my $p (@projetos) {
        my $dir = "$tmp/claude/projects/$p->{pasta}";
        $copiadas += 0 + grep({ -f "$dir/$_" } listar($dir, qr/\.jsonl$/));
    }
    die "A copia saiu incompleta ($copiadas de $total conversas). Confira se ~/.claude ou alguma pasta dentro dele e um link quebrado.\n"
        if $copiadas != $total;

    my $settings = ler_json("$CLAUDE_DIR/settings.json") || {};
    my $ligados = $settings->{enabledPlugins} || {};
    my @plugins = sort grep { $ligados->{$_} && JSON::PP::is_bool($ligados->{$_}) } keys %$ligados;
    my $conhecidos = ler_json("$CLAUDE_DIR/plugins/known_marketplaces.json") || {};
    my %marketplaces = map { $_ => $conhecidos->{$_}{source} } keys %$conhecidos;

    my $global = ler_json($CONFIG_GLOBAL) || {};
    my @mcp_local;
    for my $proj (sort keys %{ $global->{projects} || {} }) {
        my $srv = $global->{projects}{$proj}{mcpServers};
        push @mcp_local, { projeto => $proj, servidores => $srv } if ref $srv eq 'HASH' && %$srv;
    }
    my $mcp_usuario = ref $global->{mcpServers} eq 'HASH' ? $global->{mcpServers} : {};

    my $manifesto = {
        formato      => 'migra-claudinho/1',
        criadoEm     => strftime('%Y-%m-%dT%H:%M:%S', localtime),
        origem       => { so => nome_do_so(), computador => hostname(), home => $HOME, claudeDir => $CLAUDE_DIR },
        projetos     => \@projetos,
        plugins      => \@plugins,
        marketplaces => \%marketplaces,
        # So os nomes: as configuracoes (que podem ter chaves de API) vao em mcp.json,
        # dentro do pacote compactado, para nao aparecerem a quem so le o manifesto
        mcpUsuario   => [sort keys %$mcp_usuario],
        mcpLocal     => [map { { projeto => $_->{projeto}, servidores => [sort keys %{ $_->{servidores} }] } } @mcp_local],
        desktop      => $desktop,
    };
    gravar_arquivo("$destino/manifesto.json", $J->encode($manifesto));
    gravar_arquivo("$tmp/mcp.json", $J->encode({ mcpUsuario => $mcp_usuario, mcpLocal => \@mcp_local }));

    print "Compactando...\n";
    {
        local $ENV{COPYFILE_DISABLE} = 1;   # sem os arquivos ._ do macOS
        system('tar', '-czf', "$destino/claude-export.tar.gz", '-C', $tmp, '.') == 0 or die "tar falhou\n";
    }
    copiar_arvore($SKILL_DIR, "$destino/skill", { '.git' => 1 });
    copiar_arquivo("$SKILL_DIR/assets/COLE-NO-CLAUDE.txt", "$destino/COLE-NO-CLAUDE.txt");

    my $mb = int((-s "$destino/claude-export.tar.gz") / 1048576 + 0.5);
    print "\nPronto: $total conversas de " . scalar(@projetos) . " pastas de projeto, $mb MB.\n";
    printf "Claude Desktop: %d servidor(es) MCP, %d extensao(oes), %d tarefa(s) agendada(s).\n",
        scalar @{ $desktop->{mcpServers} }, scalar @{ $desktop->{extensoes} }, $desktop->{tarefas} if $desktop;
    print "Pacote: $destino\n";
    print "Leve a pasta inteira para a maquina nova. Ela tem conversas completas: guarde so em lugar privado e apague depois.\n";
}

# --- Importar ---------------------------------------------------------------------

# Claude Desktop: mescla os servidores MCP do chat e copia extensoes e tarefas agendadas.
# Com o Desktop aberto, nao mexe em nada: ele regravaria a configuracao por cima.
sub importar_desktop {
    my ($de, $man, $pacote, $mapa, $origem_win, $trocar_home, $reescrever, $backup, $guardados) = @_;
    my $alvo = achar_desktop();
    return 'O pacote tem coisas do Claude Desktop, mas ele nao esta instalado aqui. Se a pessoa usa, instale, entre na conta, abra uma vez e rode de novo com --so-desktop.'
        unless $alvo;
    if (desktop_aberto()) {
        my $com_mapa = '';
        if ($mapa) {
            my $no_pacote = "$pacote/mapa.json";
            copy($mapa, $no_pacote) unless (abs_path($mapa) // '') eq (abs_path($no_pacote) // '');
            $com_mapa = ' --mapa mapa.json';
        }
        my ($arq, $como_fechar, $como_rodar) = $^O eq 'darwin'
            ? ("$pacote/aplicar-claude-desktop.command", 'Cmd+Q', 'de dois cliques em')
            : ("$pacote/aplicar-claude-desktop.sh", 'menu do Claude > Sair', 'rode num terminal: bash');
        if (open my $fh, '>:raw', $arq) {
            print $fh "#!/bin/bash\ncd \"\$(dirname \"\$0\")\"\n",
                "echo 'Antes de continuar, feche o Claude Desktop ($como_fechar) e aperte Enter.'; read\n",
                "perl skill/scripts/migra.pl importar --pacote . --so-desktop$com_mapa\n",
                "read -p 'Pronto. Aperte Enter para fechar.'\n";
            close $fh;
            chmod 0755, $arq;
            return "O Claude Desktop esta aberto, entao a parte dele ficou para depois. Feche o Desktop e $como_rodar $arq";
        }
        return 'O Claude Desktop esta aberto, entao a parte dele ficou para depois. Feche-o e rode de novo com --so-desktop.';
    }
    my @msgs;
    my $velho = -f "$de/claude_desktop_config.json" ? ler_json("$de/claude_desktop_config.json") : undef;
    if (ref $velho eq 'HASH' && ref $velho->{mcpServers} eq 'HASH' && %{ $velho->{mcpServers} }) {
        my $arq = "$alvo/claude_desktop_config.json";
        my $novo = (-f $arq ? ler_json($arq) : undef) || {};
        $novo->{mcpServers} ||= {};
        my $adicionados = 0;
        for my $nome (sort keys %{ $velho->{mcpServers} }) {
            next if exists $novo->{mcpServers}{$nome};   # o daqui vence
            $novo->{mcpServers}{$nome} = $J1->decode($trocar_home->($J1->encode($velho->{mcpServers}{$nome})));
            $adicionados++;
        }
        if ($adicionados) {
            copiar_arquivo($arq, "$backup/desktop/claude_desktop_config.json") if -f $arq;
            gravar_arquivo($arq, $J->encode($novo));
            print "Claude Desktop: $adicionados servidor(es) MCP adicionado(s).\n";
            push @msgs, 'Os servidores MCP do Desktop vieram do Windows: confira os comandos em Configuracoes > Desenvolvedor.' if $origem_win;
        }
    }
    # Caminhos dentro das configuracoes de extensoes e das tarefas agendadas
    for my $sub ('Claude Extensions Settings', 'claude-code-sessions', 'local-agent-mode-sessions') {
        next unless -d "$de/$sub";
        find({ no_chdir => 1, wanted => sub { $reescrever->($_, 1) if /\.json$/ && -f $_ } }, "$de/$sub");
    }
    # Tarefas agendadas: o Desktop novo ja cria um scheduled-tasks.json vazio, entao o arquivo
    # nao pode simplesmente ganhar ou perder. As do pacote que ainda nao existem aqui (pelo
    # id) entram na lista daqui.
    my $tarefas = 0;
    my @arquivos_tarefas;
    find({ no_chdir => 1, wanted => sub { push @arquivos_tarefas, $_ if basename($_) eq 'scheduled-tasks.json' && -f $_ } }, $de);
    my $jc = JSON::PP->new->canonical;
    my $chave_tarefa = sub { my $t = shift; return ref $t eq 'HASH' && defined $t->{id} ? "id:$t->{id}" : $jc->encode($t) };
    for my $f (@arquivos_tarefas) {
        (my $rel = $f) =~ s{^\Q$de\E/}{};
        my $daqui = "$alvo/$rel";
        my $pacote_t = eval { ler_json($f) } || {};
        my @do_pacote = ref $pacote_t->{scheduledTasks} eq 'ARRAY' ? @{ $pacote_t->{scheduledTasks} } : ();
        if (-f $daqui) {
            my $local = eval { ler_json($daqui) } || {};
            $local->{scheduledTasks} = [] unless ref $local->{scheduledTasks} eq 'ARRAY';
            my %visto = map { $chave_tarefa->($_) => 1 } @{ $local->{scheduledTasks} };
            my @novas = grep { !$visto{ $chave_tarefa->($_) } } @do_pacote;
            if (@novas) {
                push @{ $local->{scheduledTasks} }, @novas;
                # O backup vai para a pasta central, e nao ao lado: dentro da pasta do Desktop
                # ele viajaria no proximo pacote
                copiar_arquivo($daqui, "$backup/desktop/$rel");
                gravar_arquivo($daqui, $J->encode($local));
                $tarefas += @novas;
            }
        } else {
            copiar_arquivo($f, $daqui);
            $tarefas += @do_pacote;
        }
        unlink $f;   # ja tratado; a mescla generica nao deve mexer
    }
    $$guardados += mesclar_arvore("$de/$_", "$alvo/$_", "desktop/$_", $backup) for @DESKTOP_PASTAS;
    my $ext = scalar @{ $man->{desktop}{extensoes} || [] };
    push @msgs, "Claude Desktop: $ext extensao(oes) copiada(s). Abra Configuracoes > Extensoes e preencha de novo as chaves e senhas que elas pedirem (ficam criptografadas na maquina antiga). Se alguma nao aparecer, reinstale."
        if $ext;
    push @msgs, "Claude Desktop: $tarefas tarefa(s) agendada(s) entraram aqui. Desligue-as na maquina antiga para nao rodarem duas vezes."
        if $tarefas;
    print "Claude Desktop: pronto. Abra o Desktop de novo para ele ler as mudancas.\n";
    return @msgs;
}

sub importar {
    my ($pacote, $mapa, $simular, $sem_plugins, $dias, $so_desktop, $sem_desktop) = (undef, undef, 0, 0, 365, 0, 0);
    GetOptions('pacote=s' => \$pacote, 'mapa=s' => \$mapa, 'simular' => \$simular, 'sem-plugins' => \$sem_plugins,
        'dias-historico=i' => \$dias, 'so-desktop' => \$so_desktop, 'sem-desktop' => \$sem_desktop) or die "Opcao invalida\n";
    $pacote //= dirname(dirname(dirname(abs_path($0))));   # <pacote>/skill/scripts/migra.pl
    $pacote = abs_path($pacote);
    my ($arquivo) = grep { -f $_ } map { "$pacote/$_" } qw(claude-export.tar.gz claude-export.zip);
    die "Nao achei claude-export.tar.gz nem claude-export.zip em $pacote. Use --pacote <pasta do pacote>.\n" unless $arquivo;

    my $man = ler_json("$pacote/manifesto.json") or die "Nao achei $pacote/manifesto.json\n";
    my $origem_win = $man->{origem}{so} eq 'windows';
    my $home_velha = $man->{origem}{home};
    my $sep = $origem_win ? '\\' : '/';
    my $worktree = qr{[\\/](\.worktrees|\.claude[\\/]worktrees)[\\/]};
    my @avisos;

    my $normalizar = sub {
        my $p = shift;
        $p =~ s{/}{\\}g if $origem_win;
        $p =~ s{[\\/]+$}{} if length($p) > 3;
        return $p;
    };
    my $casa = sub {
        my ($c, $p) = @_;
        $p =~ s{[\\/]+$}{};
        ($c, $p) = (lc $c, lc $p) if $origem_win;
        return $c eq $p || index($c, $p . $sep) == 0;
    };
    my $igual = sub {
        my ($x, $y) = @_;
        s{[\\/]+$}{} for $x, $y;
        return $origem_win ? lc $x eq lc $y : $x eq $y;
    };
    # Troca a pasta de usuario antiga pela nova num texto JSON (hooks, statusLine, MCP)
    my $trocar_home = sub {
        my $txt = shift;
        return $txt unless defined $home_velha && $home_velha ne $HOME;
        if ($origem_win) {
            # C:\\Users\\ana\\Documents (escapado no JSON): troca a home e as barras do resto,
            # para nao sobrar /Users/ana\Documents
            my $escapada = quotemeta($home_velha =~ s{\\}{\\\\}gr);
            $txt =~ s{$escapada((?:\\\\[^\\"]+)*)(?=\\\\|")}{ $HOME . ($1 =~ s{\\\\}{/}gr) }gie;
            my $barras = quotemeta($home_velha =~ s{\\}{/}gr);
            $txt =~ s{$barras(?=/|")}{$HOME}gi;
        } else {
            my $re = quotemeta($home_velha);
            $txt =~ s{$re(?=/|")}{$HOME}g;
        }
        return $txt;
    };

    # Regras [antigo, novo]; a mais longa que casar vence
    my @regras;
    my $regra_para = sub {
        my $c = shift;
        my $melhor;
        for my $r (@regras) {
            $melhor = $r if $casa->($c, $r->[0]) && (!$melhor || length($r->[0]) > length($melhor->[0]));
        }
        return $melhor;
    };
    my $aplicar = sub {
        my ($r, $c) = @_;
        (my $base = $r->[0]) =~ s{[\\/]+$}{};
        my $resto = substr($c, length $base);
        $resto =~ s{\\}{/}g if $origem_win;
        (my $novo = $r->[1]) =~ s{(?<=.)/+$}{};
        $resto =~ s{^/}{} if $novo =~ m{/$};   # "/" + "/x" daria "//x"
        return $novo . $resto;
    };
    my $traduzir = sub {
        my $c = shift;
        return undef unless defined $c;
        my $r = $regra_para->($c);
        return $r ? $aplicar->($r, $c) : undef;
    };
    # O Claude nomeia a pasta pelo caminho real (sem links e com as maiusculas do disco)
    my $canonico = sub {
        my $p = shift;
        return $p unless -d $p;
        my $antes = getcwd();
        return $p unless chdir $p;
        my $real = getcwd();
        chdir $antes;
        return $real // $p;
    };

    # Procura pastas com o mesmo nome nos lugares onde projetos costumam ficar, ate 3
    # niveis abaixo de cada um e por no maximo 20 segundos (discos de rede e nuvem sao lentos)
    my $sugerir = sub {
        my ($folha) = @_;
        my @fila = map { [$_, 0] } grep { defined && -d $_ } ((map { $_->[1] } @regras),
            "$HOME/Documents", "$HOME/Desktop", "$HOME/Projects", "$HOME/projetos", $HOME,
            bsd_glob('/Volumes/*'), bsd_glob('/mnt/*'), bsd_glob('/media/' . ($ENV{USER} // '') . '/*'));
        my (@achados, %visto);
        my $inicio = time;
        while (@fila && @achados < 5 && time - $inicio < 20) {
            my ($dir, $nivel) = @{ shift @fila };
            next if $visto{$dir}++;
            opendir my $dh, $dir or next;
            my @filhos = grep { $_ ne '.' && $_ ne '..' && -d "$dir/$_" && !-l "$dir/$_" } readdir $dh;
            closedir $dh;
            for my $nome (@filhos) {
                my $f = $dir eq '/' ? "/$nome" : "$dir/$nome";
                push @achados, $f if $nome eq $folha && !grep { $_ eq $f } @achados;
                push @fila, [$f, $nivel + 1] if $nivel < 3 && $nome !~ /^(node_modules|Library|\..*)$/;
            }
        }
        return @achados;
    };

    if ($mapa) {
        $mapa = abs_path($mapa) // $mapa;
        my $m = ler_json($mapa) or die "Nao consegui ler o mapa $mapa\n";
        push @regras, [$normalizar->($_), $m->{$_} =~ s{^~(?=/|$)}{$HOME}r] for keys %$m;   # aceita ~/...
    }

    # Resolve cada projeto. Pais antes dos filhos: um filho herda a regra da pasta mae,
    # mas se a pasta herdada nao existe aqui, ele pode ter mudado de lugar sozinho.
    my @plano;
    for my $p (sort { length($a->{cwd} // '') <=> length($b->{cwd} // '') } @{ $man->{projetos} }) {
        my ($velho, $novo, $sit, @sug) = ($p->{cwd});
        if (!defined $velho) {
            $sit = 'sem caminho gravado (mantem o nome)';
        } else {
            $velho = $normalizar->($velho);
            my $regra = $regra_para->($velho);
            my $herdada = $regra && !$igual->($velho, $regra->[0]);
            if ($regra) {
                $novo = $aplicar->($regra, $velho);
                if ($herdada && !-d $novo && $velho !~ $worktree) { $novo = undef }
                else { $sit = $novo eq $velho ? 'mesmo caminho' : 'mapeado' }
            }
            if (!defined $novo && !$origem_win && -d $velho) {
                ($novo, $sit) = ($velho, 'mesmo caminho');
            } elsif (!defined $novo && defined $home_velha && $casa->($velho, $normalizar->($home_velha))) {
                my $resto = substr($velho, length $normalizar->($home_velha));
                $resto =~ s{\\}{/}g if $origem_win;
                ($novo, $sit) = ("$HOME$resto", 'home trocada') if -d "$HOME$resto";
            }
            if (defined $novo) {
                $novo = $canonico->($novo);
                if (!-d $novo) {
                    if ($velho =~ $worktree) { $sit .= ', pasta nao existe (normal para worktree apagado)' }
                    else { $sit = 'PASTA NAO EXISTE: confira o mapa' }   # mapa apontando para lugar errado
                }
                push @regras, [$velho, $novo] if !$regra || $herdada;
            } else {
                $sit = 'NAO ENCONTRADO';
                @sug = $sugerir->((split /[\\\/]/, $velho)[-1]);
                splice @sug, 5 if @sug > 5;
            }
        }
        push @plano, { pasta => $p->{pasta}, velho => $velho, novo => $novo, sit => $sit, sessoes => $p->{sessoes},
            memorias => $p->{memorias}, sug => \@sug, destino => defined $novo ? nome_da_pasta($novo) : $p->{pasta} };
    }

    print "\nPacote de $man->{origem}{computador} ($man->{origem}{so}), criado em $man->{criadoEm}\n";
    for my $l (@plano) {
        print "[$l->{sit}] $l->{sessoes} conversa(s), $l->{memorias} memoria(s)\n";
        print "    antes: " . ($l->{velho} // '?') . "\n";
        print "    agora: $l->{novo}\n" if defined $l->{novo};
        print "    sugestao: $_\n" for @{ $l->{sug} };
    }
    my @faltando = grep { $_->{sit} =~ /^(NAO ENCONTRADO|PASTA NAO EXISTE)/ } @plano;
    if (@faltando) {
        print "\n" . scalar(@faltando) . " projeto(s) sem lugar nesta maquina. Crie um mapa.json, por exemplo:\n";
        print '  { ' . json_escapar($faltando[0]{velho}) . ': "<caminho nesta maquina>" }' . "\n";
        print "  e rode de novo com --mapa <arquivo>. Sem mapa, eles sao importados com o nome antigo.\n";
    }
    if (my $md = $man->{desktop}) {
        my $dd = achar_desktop();
        my $onde = !$dd ? 'nao instalado nesta maquina' : desktop_aberto() ? "$dd (aberto agora)" : $dd;
        printf "\nClaude Desktop no pacote: %d servidor(es) MCP, %d extensao(oes), %d tarefa(s) agendada(s). Aqui: %s\n",
            scalar @{ $md->{mcpServers} || [] }, scalar @{ $md->{extensoes} || [] }, $md->{tarefas} || 0, $onde;
    }
    if ($simular) {
        print "Aviso: $_\n" for @avisos;
        print "\nSimulacao: nada foi alterado.\n";
        return;
    }

    # Reescreve caminhos gravados em campos JSON ("cwd", "project"). Primeiro as regras dos
    # projetos, depois a troca da pasta de usuario: na ordem inversa, a troca esconderia o
    # caminho antigo das regras. Mantem a data de modificacao: e ela que decide quem e mais
    # novo quando a importacao roda de novo.
    my $reescrever = sub {
        my ($f, $com_home) = @_;
        my $mtime = (stat $f)[9];
        my $t = ler_arquivo($f);
        (my $n = $t) =~ s{"(cwd|project)"(\s*:\s*)"((?:[^"\\]|\\.)*)"}{
            my ($k, $s, $v) = ($1, $2, $3);
            my $novo = $traduzir->($normalizar->(json_desescapar($v)));
            defined $novo ? qq("$k"$s) . json_escapar($novo) : qq("$k"$s"$v");
        }ge;
        $n = $trocar_home->($n) if $com_home;
        if ($n ne $t) {
            gravar_arquivo($f, $n);
            utime $mtime, $mtime, $f;
        }
    };

    my $tmp = pasta_temporaria('import');
    my $backup = "$CLAUDE_DIR/backup-migracao-$CARIMBO";
    my $guardados = 0;
    print "\nDescompactando...\n";
    my ($ok, $usado);
    if ($arquivo =~ /\.tar\.gz$/) { $usado = 'tar'; $ok = system('tar', '-xzf', $arquivo, '-C', $tmp) == 0 }
    elsif ($^O eq 'darwin') { $usado = 'tar (bsdtar)'; $ok = system('tar', '-xf', $arquivo, '-C', $tmp) == 0 }
    elsif (existe_comando('unzip')) { $usado = 'unzip'; $ok = system('unzip', '-q', '-o', $arquivo, '-d', $tmp) == 0 }
    elsif (existe_comando('bsdtar')) { $usado = 'bsdtar'; $ok = system('bsdtar', '-xf', $arquivo, '-C', $tmp) == 0 }
    elsif (existe_comando('python3')) {
        # o "python3 -m zipfile" poe a data de agora em tudo; aqui a data original e mantida
        $usado = 'python3';
        $ok = system('python3', '-I', '-c', join("\n",
            'import zipfile, os, sys, time',
            'z = zipfile.ZipFile(sys.argv[1])',
            'for i in z.infolist():',
            '    p = z.extract(i, sys.argv[2])',
            '    t = time.mktime(i.date_time + (0, 0, -1))',
            '    os.utime(p, (t, t))'), $arquivo, $tmp) == 0;
    }
    die "Nao consegui descompactar $arquivo" . ($usado ? " com $usado" : '') . ". Instale o unzip (por exemplo: sudo apt install unzip) e rode de novo.\n" unless $ok;
    my $origem = "$tmp/claude";
    my $mcp = -f "$tmp/mcp.json" ? ler_json("$tmp/mcp.json") : undef;

    # Marcas de uma importacao anterior NESTA maquina. Calculado antes de copiar qualquer
    # coisa, e as marcas que vierem no pacote (de uma migracao em cadeia) nao entram.
    my $settings = "$CLAUDE_DIR/settings.json";
    my $marca = "$CLAUDE_DIR/.migra-claudinho-importado";
    my $ja = -e $marca || listar($CLAUDE_DIR, qr/^settings\.json\.antes-da-migracao/);
    my $indice_arq = "$CLAUDE_DIR/.migra-claudinho-indice.json";
    if (-f $indice_arq) { my $i = eval { ler_json($indice_arq) }; %INDICE = %$i if ref $i eq 'HASH' }

    PRINCIPAL: {
    last PRINCIPAL if $so_desktop;
    print "Ajustando caminhos e colocando as conversas no lugar...\n";
    make_path("$CLAUDE_DIR/projects");
    for my $l (@plano) {
        my $de = "$origem/projects/$l->{pasta}";
        next unless -d $de;
        find({ no_chdir => 1, wanted => sub { $reescrever->($_) if /\.jsonl$/ && -f $_ } }, $de);
        my $para = "$CLAUDE_DIR/projects/$l->{destino}";
        mesclar_linhas("$de/memory/MEMORY.md", "$para/memory/MEMORY.md");
        $guardados += mesclar_arvore($de, $para, "projects/$l->{destino}", $backup);
    }

    print "Restaurando skills, configuracoes e historicos...\n";
    $reescrever->("$origem/history.jsonl") if -f "$origem/history.jsonl";
    mesclar_linhas("$origem/history.jsonl", "$CLAUDE_DIR/history.jsonl");
    $guardados += mesclar_arvore($origem, $CLAUDE_DIR, 'claude', $backup, { projects => 1, 'settings.json' => 1 }, $MARCAS);

    # claude-mem: a pasta de usuario aparece nas configuracoes dele, e o banco SQLite
    # (arquivo principal, -wal e -shm) so faz sentido inteiro, nunca misturado
    my $mem = "$tmp/home/.claude-mem";
    if (-d $mem) {
        $reescrever->("$mem/$_", 1) for grep { /\.json$/ && -f "$mem/$_" } listar($mem, qr/./);
        if (grep { /\.(db|sqlite3?)$/ } listar("$HOME/.claude-mem", qr/./)) {
            my $guardou = 0;
            for my $b (grep { /\.(db|sqlite3?)(-wal|-shm|-journal)?$/ } listar($mem, qr/./)) {
                my $sig = assinatura("$mem/$b");
                if (($INDICE{"banco/$b"} // '') ne $sig) {   # igual: o mesmo banco ja foi guardado antes
                    copiar_arquivo("$mem/$b", "$backup/home/.claude-mem/$b");
                    $INDICE{"banco/$b"} = $sig;
                    $guardou = 1;
                }
                unlink "$mem/$b";
            }
            push @avisos, "O claude-mem desta maquina ja tem um banco proprio, entao o da maquina antiga nao foi misturado com ele. Ele ficou em $backup/home/.claude-mem. Para usar o antigo, feche o Claude (o claude-mem para junto) e copie os arquivos de la para $HOME/.claude-mem."
                if $guardou;
        }
    }
    $guardados += mesclar_arvore("$tmp/home", $HOME, 'home', $backup);

    # settings.json: na primeira importacao vem o da maquina antiga (com backup do daqui).
    # Nas seguintes fica o daqui, para nao desfazer o que a pessoa mudou nesta maquina.
    my $atual = -f $settings ? ler_arquivo($settings) : undef;
    my $txt;
    if (-f "$origem/settings.json" && !$ja) {
        $txt = $trocar_home->(ler_arquivo("$origem/settings.json"));
        print "settings.json: veio o da maquina antiga.\n";
        push @avisos, 'O pacote veio do Windows: confira hooks e statusLine no settings.json, eles podem usar comandos que nao existem aqui.' if $origem_win;
    } elsif (defined $atual) {
        $txt = $atual;
        print "settings.json: ja tinha sido importado antes; mantive o desta maquina.\n" if $ja && -f "$origem/settings.json";
    } else {
        $txt = '{}';
    }
    # O Claude apaga conversas mais velhas que cleanupPeriodDays (padrao: 30 dias).
    # As do Claude Desktop e do Cowork ficam fora dessa limpeza por padrao.
    if ($dias > 0 && $txt !~ /"cleanupPeriodDays"/) {
        if ($txt =~ /^\s*\{\s*\}\s*$/) { $txt = "{ \"cleanupPeriodDays\": $dias }\n" }
        else { $txt =~ s/\{/{\n  "cleanupPeriodDays": $dias,/ }
        print "Conversas agora ficam guardadas por $dias dias (cleanupPeriodDays).\n";
    }
    if (!defined $atual || $txt ne $atual) {
        copy($settings, "$settings.antes-da-migracao-$CARIMBO") if defined $atual;
        gravar_arquivo($settings, $txt);
    }
    gravar_arquivo($marca, "Importado de $man->{origem}{computador} em $CARIMBO\n");
    }   # fim de PRINCIPAL

    push @avisos, importar_desktop("$tmp/desktop", $man, $pacote, $mapa, $origem_win, $trocar_home, $reescrever, $backup, \$guardados)
        if !$sem_desktop && -d "$tmp/desktop";
    make_path($CLAUDE_DIR);   # quem so usa o Desktop pode nao ter ~/.claude ainda
    gravar_arquivo($indice_arq, JSON::PP->new->canonical->encode(\%INDICE));
    push @avisos, "$guardados arquivo(s) tinham versoes diferentes nos dois computadores. Ficou a mais nova; a outra foi guardada em $backup. Olhe com a pessoa se algo dali precisa voltar (memorias e CLAUDE.md primeiro) e apague a pasta depois."
        if $guardados;
    push @avisos, "Nao consegui juntar " . scalar(@EM_USO) . " arquivo(s), provavelmente abertos por outro programa ou sem permissao. Feche o Claude e rode a importacao de novo para eles (veja references/problemas.md):\n    " . join("\n    ", @EM_USO)
        if @EM_USO;
    if ($so_desktop) {
        print "Confira: $_\n" for @avisos;
        return;
    }

    # --- Plugins e MCP pela CLI do Claude ---
    my @falhas;
    my @candidatos;
    # O "2>/dev/null" faz o Perl passar pelo shell: "command" e um comando do shell, nao um programa
    push @candidatos, scalar(`command -v claude 2>/dev/null` =~ s/\s+$//r) if existe_comando('claude');
    push @candidatos, "$HOME/.local/bin/claude";
    if (($ENV{CLAUDE_PID} // '') =~ /^\d+$/) {   # o Claude que esta rodando esta importacao
        my $p = $^O eq 'linux' ? readlink("/proc/$ENV{CLAUDE_PID}/exe") : scalar(`ps -o comm= -p $ENV{CLAUDE_PID} 2>/dev/null` =~ s/\s+$//r);
        push @candidatos, $p if $p && basename($p) eq 'claude';
    }
    push @candidatos, (sort { (stat $a)[9] <=> (stat $b)[9] } bsd_glob("$HOME/.*/extensions/anthropic.claude-code-*/resources/native-binary/claude"))[-1];
    if (my $dd = achar_desktop()) {
        push @candidatos, (sort { (stat $a)[9] <=> (stat $b)[9] } bsd_glob("$dd/claude-code/*/*/claude"), bsd_glob("$dd/claude-code/*/claude"))[-1];
    }
    my ($claude) = grep { defined && -f $_ && -x $_ } @candidatos;

    # Configuracao de MCP que veio do Windows: troca a home, tira o "cmd /c" e avisa do resto
    my $ajustar_mcp = sub {
        my ($nome, $cfg) = @_;
        my $c = $J1->decode($trocar_home->($J1->encode($cfg)));
        if ($origem_win && ref $c eq 'HASH' && ($c->{command} // '') =~ /^cmd(\.exe)?$/i
            && ref $c->{args} eq 'ARRAY' && lc($c->{args}[0] // '') eq '/c' && @{ $c->{args} } > 1) {
            shift @{ $c->{args} };
            $c->{command} = shift @{ $c->{args} };
        }
        my $j = $J1->encode($c);
        push @avisos, "O servidor MCP $nome ainda tem caminho ou programa do Windows: confira com \"claude mcp get $nome\"."
            if $origem_win && $j =~ /[A-Za-z]:[\\\/]|\\\\|\.(exe|cmd|bat|ps1)\b/i;
        return $j;
    };
    push @avisos, 'Os servidores MCP vieram do Windows: confira os comandos com "claude mcp list".'
        if $origem_win && $mcp && (%{ $mcp->{mcpUsuario} || {} } || @{ $mcp->{mcpLocal} || [] });

    if (!$claude) {
        push @falhas, 'Claude Code nao encontrado: plugins e MCP ficaram para depois. Instale o Claude e rode a importacao de novo.';
    } else {
        if (!$sem_plugins) {
            print "Reinstalando marketplaces e plugins...\n";
            for my $nome (sort keys %{ $man->{marketplaces} || {} }) {
                my $src = $man->{marketplaces}{$nome} || {};
                my ($alvo) = grep { defined } @{$src}{qw(repo url path)};
                if (!$alvo) { push @falhas, "marketplace $nome (origem desconhecida)"; next }
                system($claude, 'plugin', 'marketplace', 'add', $alvo);
            }
            for my $id (@{ $man->{plugins} || [] }) {
                push @falhas, "plugin $id (se ele pedir para aprovar um comando, mostre o comando a pessoa e, com o OK dela, rode num terminal: \"$claude\" plugin install $id --yes)"
                    if system($claude, 'plugin', 'install', $id) != 0;
            }
        }
        if ($mcp) {
            for my $nome (sort keys %{ $mcp->{mcpUsuario} || {} }) {
                push @falhas, "MCP $nome (talvez ja existisse)"
                    if system($claude, 'mcp', 'add-json', '-s', 'user', $nome, $ajustar_mcp->($nome, $mcp->{mcpUsuario}{$nome})) != 0;
            }
            my $aqui = getcwd();
            for my $item (@{ $mcp->{mcpLocal} || [] }) {
                my $pasta = $traduzir->($normalizar->($item->{projeto}));
                $pasta //= $item->{projeto} unless $origem_win;
                if (!defined $pasta || !-d $pasta) { push @falhas, "MCPs locais de $item->{projeto} (pasta nao existe aqui)"; next }
                chdir $pasta;
                for my $nome (sort keys %{ $item->{servidores} }) {
                    push @falhas, "MCP $nome em $pasta (talvez ja existisse)"
                        if system($claude, 'mcp', 'add-json', '-s', 'local', $nome, $ajustar_mcp->($nome, $item->{servidores}{$nome})) != 0;
                }
                chdir $aqui;
            }
        }

        # O doctor le o settings.json e diz se algo ficou invalido (o Claude ignoraria o arquivo)
        if (open(my $doc, '-|', $claude, 'doctor')) {
            my @linhas = <$doc>;
            close $doc;
            push @falhas, "O claude doctor achou configuracoes invalidas. Rode \"claude doctor\" e corrija o settings.json:\n"
                . join('', map { "    $_" } grep { /settings\.json/ } @linhas)
                if grep { /Invalid settings/ } @linhas;
        }
    }

    print "\n";
    print "Confira: $_\n" for @avisos, @falhas;
    my $total = 0;
    $total += $_->{sessoes} for @plano;
    print "Importadas $total conversas. Feche e abra de novo o editor (ou o terminal) para ver o historico.\n";
}
