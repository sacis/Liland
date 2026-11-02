<h1 align="center">
  <img src="Liland/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="72" align="absmiddle" alt="">
  liland ♡(>ᴗ•)
</h1>

<p align="center">
  uma dynamic island no notch do macbook, pra ver e controlar a música que está tocando.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/spotify-fbd3e4?style=flat-square" alt="spotify">
  <img src="https://img.shields.io/badge/apple_music-fbd3e4?style=flat-square" alt="apple music">
  <img src="https://img.shields.io/badge/deezer-fbd3e4?style=flat-square" alt="deezer">
  <img src="https://img.shields.io/badge/youtube-fbd3e4?style=flat-square" alt="youtube">
  <img src="https://img.shields.io/badge/e_outros_sites-fbd3e4?style=flat-square" alt="e outros sites">
</p>

<p align="center">
  <a href="https://github.com/sacis/Liland/releases/latest/download/Liland.zip"><img src="docs/download.svg" height="52" alt="baixar o liland"></a>
</p>

<p align="center">
  <sub>macos 14 (sonoma) ou mais novo · em 20 idiomas · sem login</sub>
</p>

<br>

quando tem música tocando, o notch cresce e mostra a capa do álbum com um equalizador do lado. passando o mouse por cima, ele abre um player com a música, o artista, a barra de progresso e os controles, inclusive aleatório e repetir quando o app informa esses modos.

não precisa fazer login em nada. o liland lê direto do spotify e do app música e, pros outros apps e sites, do que o mac mostra em *tocando agora* na central de controle.

o botão rosa ali em cima baixa o app pronto. o botão verde "code" do github baixa só o código-fonte, não é ele que você quer.

## ★ instalação

precisa de **macos 14 (sonoma)** ou mais novo. dá pra conferir em  › sobre este mac.

1. [baixe o liland.zip](https://github.com/sacis/Liland/releases/latest/download/Liland.zip). se ele não descompactar sozinho, dê dois cliques no arquivo dentro de downloads.
2. arraste o **liland** pra pasta **aplicativos**.
3. abra o liland. como ele não vem da app store, o mac mostra um aviso dizendo que não pôde verificar o app. feche o aviso, **sem** clicar em *mover para o lixo*.
4. vá em ajustes do sistema › privacidade e segurança, role até o final e clique em **abrir mesmo assim** ao lado da mensagem sobre o liland. o mac vai pedir sua senha.

isso só precisa ser feito uma vez. depois disso o liland abre normalmente e fica na barra de menus, com um ícone de cápsula.

na primeira vez que o spotify ou o música estiverem abertos, o macos pergunta se o liland pode controlá-los. é só clicar em ok. se negar sem querer, dá pra liberar depois em ajustes do sistema › privacidade e segurança › automação.

**pra atualizar:** feche o liland (ícone de cápsula › sair do liland), baixe o zip de novo e repita a partir do passo 2. quando o mac perguntar, escolha *substituir*.

## ★ deezer, youtube e outros sites

spotify e apple music funcionam direto. pro resto (deezer, youtube, tidal e o que mais tocar no navegador), o liland usa uma peça extra, o nowplayinghelper, que o mac pede pra liberar do mesmo jeito que o próprio liland:

1. sem nada tocando, passe o mouse no notch e clique em **ativar**. também dá pelo ícone de cápsula, em *ativar deezer e navegadores…*.
2. feche o aviso do mac sobre o nowplayinghelper, de novo sem mover pro lixo.
3. os ajustes do sistema abrem em privacidade e segurança. role até o final e clique em **abrir mesmo assim** ao lado do nowplayinghelper.

depois de atualizar o liland, às vezes é preciso repetir isso.

por que esse passo a mais: desde o macos 15.4, só programas da apple conseguem ver o que está tocando no sistema. o liland contorna isso pedindo ao `perl`, que já vem instalado no mac, pra fazer a leitura. se alguma atualização do macos fechar essa brecha, o deezer e os navegadores param de aparecer, mas o spotify e o apple music continuam funcionando.

## ★ opções

ficam todas no ícone de cápsula da barra de menus.

**mostrar ao trocar de música** abre a ilha por alguns segundos quando a faixa muda.

**abrir só ao clicar** faz a ilha abrir só quando você clica no notch, e não mais quando o mouse passa por cima. pra voltar, use *abrir ao passar o mouse*.

**equalizador acompanha a música** faz as barrinhas seguirem a batida de verdade (macos 14.4 ou mais novo). na primeira vez, o macos pede permissão pro liland acessar o áudio. ele só mede o som na hora, não grava nem salva nada. se você negar, as barrinhas continuam com a animação de sempre e aparece no menu a opção *permitir acesso ao áudio nos ajustes…* pra liberar depois.

**avançado** coloca controles de som embaixo do player aberto (também macos 14.4 ou mais novo, com a mesma permissão de áudio):

- **voz**, **guitarra**, **baixo** e **bateria** tocam só as partes que você escolher, no volume da música inteira. dá pra combinar mais de uma. clicar de novo numa parte tira ela, e tirando todas a música volta inteira. a guitarra só aparece nos macs com chip apple e, como usa uma separação à parte, leva um instante pra entrar quando é escolhida.
- **equalizador** de cinco faixas, dos graves (80 hz) aos agudos (10 khz), de −12 a +12 db.
- **tom** sobe ou desce a música até 6 semitons sem mudar a velocidade.
- **↺** volta tudo ao normal. os ajustes ficam salvos pra próxima vez.

com o avançado ligado, quem toca a música é o liland, já ajustada, no lugar do app. por isso o som atrasa um pouco: cerca de três décimos de segundo ao isolar partes (um oitavo nos macs com intel) e mais um décimo ao mudar o tom. num vídeo, a boca fica um pouco fora de sincronia com a voz. desligando o modo ou fechando o liland, o som volta direto do app.

<details>
<summary>como o liland separa voz, guitarra, baixo e bateria</summary>
<br>

nos macs com chip apple, o liland usa o htdemucs, uma rede neural da meta treinada com músicas gravadas parte por parte. ela roda no próprio mac, sem mandar nada pra internet. voz, baixo e bateria vêm de um modelo. a guitarra é o resto da música nesse modelo, filtrado por um segundo modelo que reconhece guitarra e só liga enquanto ela está escolhida: assim ela vem com o corpo inteiro. a rede precisa ouvir um pedaço da música pra separar, e é daí que vem o atraso de três décimos de segundo. é bem mais limpo que uma estimativa, mas não é perfeito: num trecho muito cheio ainda aparece um pouco dos outros instrumentos, e a guitarra pode trazer junto um teclado ou sintetizador de som parecido.

nos macs com intel, que não rodam a rede rápido o bastante, a separação é uma estimativa feita na hora. o liland reconhece a voz e o baixo por estarem no centro da mixagem, então instrumentos que também estão no centro ainda aparecem um pouco, e um instrumento muito parecido com bateria (um violão bem batido, por exemplo) pode vazar nela.

</details>

também tem **abrir ao iniciar o mac** e **sair do liland**. o idioma segue o do mac.

## ★ compilar a partir do código

se você prefere montar o app no seu mac em vez de baixar o pronto, os passos estão aqui. no fim, o liland já fica instalado na pasta aplicativos.

<details>
<summary>ver o passo a passo</summary>
<br>

primeiro instale o [xcode pela app store](https://apps.apple.com/app/xcode/id497799835). é gratuito, mas o download é grande. quando terminar, abra o xcode uma vez, aceite os termos e espere ele instalar os componentes. depois pode fechar.

agora abra o terminal (<kbd>⌘</kbd> <kbd>espaço</kbd>, digite *terminal* e aperte <kbd>enter</kbd>). em cada passo abaixo, copie o comando, cole no terminal e aperte <kbd>enter</kbd>, esperando um terminar antes de colar o próximo. se ele pedir senha, é a senha do mac. é normal não aparecer nada na tela enquanto você digita.

**1.** instale o homebrew. se você já tem, pule este passo.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

aperte <kbd>enter</kbd> quando ele pedir pra continuar. se no final aparecer uma parte chamada **next steps** com mais comandos, rode esses também. depois feche o terminal e abra de novo.

**2.** instale o xcodegen.

```bash
brew install xcodegen
```

**3.** baixe e instale o liland. pode colar as três linhas de uma vez.

```bash
git clone https://github.com/sacis/Liland.git
cd Liland
./scripts/build.sh --install
```

o código fica numa pasta `Liland` dentro da sua pasta pessoal. a montagem leva alguns minutos e termina com **✓ instalado em /applications/liland.app**. o liland abre sozinho e já aparece na barra de menus.

**pra atualizar** depois:

```bash
cd ~/Liland
git pull
./scripts/build.sh --install
```

**se der erro**

`command not found: brew` quer dizer que o homebrew não terminou de instalar. rode o comando do passo 1 de novo, sem esquecer os comandos do **next steps**.

`xcodebuild requires Xcode` ou `xcode-select: error` quer dizer que o terminal não está achando o xcode. confira se ele está na pasta aplicativos e rode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`destination path 'Liland' already exists` quer dizer que você já baixou o liland antes. use os comandos de atualizar.

</details>

## ★ créditos

a leitura do deezer e dos navegadores foi adaptada do [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), de jonas van den berg e colaboradores, sob a licença bsd de 3 cláusulas (veja [nowplayinghelper/license](NowPlayingHelper/LICENSE)).
