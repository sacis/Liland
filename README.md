# Liland

Uma Dynamic Island para o notch do MacBook, integrada ao **Spotify**, ao **Apple Music** e, depois de [um passo a mais](#deezer-e-navegadores), ao **Deezer**, ao **YouTube** e aos outros players do navegador.

**[⬇️ Baixar o Liland](https://github.com/sacis/Liland/releases/latest/download/Liland.zip)** (não use o botão verde "Code", ele baixa o código-fonte). Veja abaixo como [instalar](#instalação).

- Com música tocando, o notch cresce e mostra a capa do álbum e um equalizador.
- Ao passar o mouse, abre um player com a música, o artista, a barra de progresso e os controles, incluindo **aleatório** e **repetir** quando o app informa esses modos.
- Não precisa de login: o Liland lê direto dos apps do Spotify e do Música, e do que o Mac mostra em **Tocando Agora** na Central de Controle para os outros apps e sites.

## Instalação

Precisa de um Mac com **macOS 14 (Sonoma) ou mais novo**. Para conferir, vá em  **› Sobre Este Mac**.

### Passo 1 — Baixe o Liland

**[Clique aqui para baixar o Liland.zip](https://github.com/sacis/Liland/releases/latest/download/Liland.zip)**

### Passo 2 — Coloque na pasta Aplicativos

1. Abra a pasta **Downloads**.
2. Se o arquivo ainda estiver como **Liland.zip**, dê dois cliques nele para descompactar.
3. Arraste o **Liland** para a pasta **Aplicativos** (na barra lateral do Finder).

### Passo 3 — Abra pela primeira vez

Como o Liland não vem da App Store, na primeira vez o Mac pede para você confirmar que confia nele:

1. Dê dois cliques no **Liland** dentro de Aplicativos. Vai aparecer um aviso dizendo que a Apple não pôde verificar o app. Feche o aviso (**não** clique em *Mover para o Lixo*).
2. Abra **Ajustes do Sistema › Privacidade e Segurança**.
3. Role até o final. Ao lado da mensagem sobre o Liland, clique em **Abrir Mesmo Assim** e confirme com a senha do Mac.

Pronto! O Liland aparece como um ícone de cápsula na barra de menus. Esse passo só é preciso uma vez: das próximas vezes ele abre normalmente.

### Atualizar para uma versão nova

Feche o Liland (ícone de cápsula › **Sair do Liland**), baixe o Liland.zip de novo pelo link acima e repita os passos 2 e 3. Quando o Mac perguntar, escolha **Substituir**.

## Primeiro uso

Na primeira vez que o Spotify ou o Música estiver aberto, o macOS pergunta se o Liland pode controlá-lo. Clique em **OK**.

Se você negar sem querer, libere depois em **Ajustes do Sistema › Privacidade e Segurança › Automação**.

### Deezer e navegadores

Para mostrar o Deezer, o YouTube, o TIDAL e outros sites e apps, o Liland usa uma peça extra que o Mac pede para você liberar uma vez, do mesmo jeito que liberou o Liland:

1. Com nada tocando, passe o mouse no notch e clique em **Ativar** (ou, no ícone de cápsula, em **Ativar Deezer e navegadores…**).
2. O Mac avisa que não pôde verificar o "NowPlayingHelper". Feche o aviso (**não** clique em *Mover para o Lixo*).
3. Os **Ajustes do Sistema** abrem em **Privacidade e Segurança**. Role até o final e, ao lado da mensagem sobre o NowPlayingHelper, clique em **Abrir Mesmo Assim** e confirme com a senha do Mac.

Pronto: o que tocar no Deezer ou no navegador já aparece na ilha. Depois de atualizar o Liland, pode ser preciso repetir esses passos.

Essa parte depende de uma brecha do macOS: desde o macOS 15.4, só programas da Apple podem ver o que está tocando, então o Liland pede ao `perl`, que vem instalado no Mac, para fazer essa leitura. Se uma atualização do macOS fechar essa brecha, o Deezer e os navegadores param de aparecer, mas o Spotify e o Apple Music continuam funcionando normalmente.

## Opções

No ícone de cápsula da barra de menus:

- **Mostrar ao trocar de música**: abre a ilha por alguns segundos quando a faixa muda.
- **Abrir só ao clicar**: a ilha deixa de abrir quando o mouse passa por cima e só abre quando você clica no notch. Para voltar ao jeito anterior, clique em **Abrir ao passar o mouse**.
- **Equalizador acompanha a música**: as barrinhas passam a seguir a batida da música que está tocando (macOS 14.4 ou mais novo). Na primeira vez, o macOS pede permissão para o Liland acessar o áudio. O Liland só mede o som na hora, sem gravar nem salvar nada. Se você negar, as barrinhas continuam com a animação de antes, e o item **Permitir acesso ao áudio nos Ajustes…** aparece no menu para você liberar depois.
- **Avançado**: o player aberto ganha controles de som embaixo (macOS 14.4 ou mais novo, com a mesma permissão de áudio do item acima):
  - **Tudo / Voz / Baixo / Bateria**: deixa tocar só uma parte da música. É uma estimativa feita na hora, não uma separação perfeita: em **Voz**, outros instrumentos do centro da mixagem ainda aparecem um pouco, e em **Bateria** o começo de algumas notas pode vazar.
  - **Equalizador**: cinco faixas, dos graves (80) aos agudos (10k), de −12 a +12 dB.
  - **Tom**: sobe ou desce a música até 6 semitons, sem mudar a velocidade.
  - **↺** volta tudo ao normal. Os ajustes ficam salvos para a próxima vez.

  Com o modo ligado, o Liland toca a música no lugar do app, já ajustada. Ao isolar uma parte, o som chega uns 40 ms mais tarde. Desligando o modo ou fechando o Liland, o som volta direto do app.
- **Abrir ao iniciar o Mac**
- **Sair do Liland**

O Liland segue o idioma do Mac e está disponível em 20 idiomas.

## Créditos

A leitura do Deezer e dos navegadores foi adaptada do [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), de Jonas van den Berg e colaboradores, sob a licença BSD de 3 cláusulas (veja [NowPlayingHelper/LICENSE](NowPlayingHelper/LICENSE)).

## Compilar a partir do código

Para quem prefere montar o app no próprio Mac em vez de baixar o pronto. Os comandos abaixo baixam o código, montam o app e já o colocam na pasta Aplicativos.

### Passo 1 — Instale o Xcode

1. Abra a [página do Xcode na App Store](https://apps.apple.com/app/xcode/id497799835) e clique em **Obter**. É gratuito, mas o download é grande e pode demorar bastante.
2. Quando terminar, **abra o Xcode uma vez**, aceite os termos e espere ele terminar de instalar os componentes. Depois, pode fechá-lo.

### Passo 2 — Abra o Terminal

Aperte **⌘ Command + Espaço**, digite **Terminal** e aperte **Enter**.

Nos próximos passos, você vai **copiar cada comando, colar no Terminal (⌘ Command + V) e apertar Enter**. Espere um comando terminar antes de colar o próximo.

> Se o Terminal pedir sua senha, digite a senha do seu Mac e aperte Enter. É normal nada aparecer na tela enquanto você digita.

### Passo 3 — Instale o Homebrew

O Homebrew é um instalador de ferramentas para o Mac. Se você já tem o Homebrew, pule para o passo 4.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Aperte Enter quando ele pedir para continuar. Ao terminar, se aparecer uma seção **Next steps** com mais comandos, copie e cole esses comandos também. Depois, feche o Terminal e abra de novo.

### Passo 4 — Instale o XcodeGen

```bash
brew install xcodegen
```

### Passo 5 — Baixe e instale o Liland

Cole os três comandos de uma vez:

```bash
git clone https://github.com/sacis/Liland.git
cd Liland
./scripts/build.sh --install
```

O primeiro comando baixa o Liland para uma pasta chamada `Liland` na sua pasta pessoal. O último monta o app, o que leva alguns minutos. Quando aparecer **✓ Instalado em /Applications/Liland.app**, pronto: o Liland abre sozinho e aparece como um ícone de cápsula na barra de menus.

Depois disso, você pode fechar o Terminal.

### Atualizar para uma versão nova

Abra o Terminal e cole:

```bash
cd ~/Liland
git pull
./scripts/build.sh --install
```

### Se algo der errado

- **`command not found: brew`**: o passo 3 não terminou. Rode o comando do Homebrew de novo e não esqueça os comandos de **Next steps** do final.
- **`xcodebuild requires Xcode`** ou **`xcode-select: error`**: o Terminal não está achando o Xcode. Confira se o Xcode está na pasta Aplicativos e rode:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **`destination path 'Liland' already exists`**: você já baixou o Liland antes. Siga as instruções de **Atualizar para uma versão nova**.
