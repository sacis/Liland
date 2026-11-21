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

> *english version at the end of the page → [read in english](#english)*

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
- **volume de cada parte**: o botão ao lado do ↺ troca o equalizador por um controle de volume pra cada parte e um pra **outros**, que é o resto da música (teclados, cordas, sopros…), de 0 a 200%. dá pra tirar a voz pra cantar junto ou deixar o baixo mais alto pra tirar de ouvido. com alguma parte isolada, os volumes valem só entre as partes escolhidas. o volume geral continua o da música inteira.
- **equalizador** de cinco faixas, dos graves (80 hz) aos agudos (10 khz), de −12 a +12 db.
- **tom** sobe ou desce a música até 6 semitons sem mudar a velocidade.
- **↺** volta tudo ao normal. os ajustes ficam salvos pra próxima vez.

com o avançado ligado, quem toca a música é o liland, já ajustada, no lugar do app. por isso o som atrasa um pouco: cerca de três décimos de segundo ao isolar partes ou mudar o volume delas (um oitavo nos macs com intel) e mais um décimo ao mudar o tom. num vídeo, a boca fica um pouco fora de sincronia com a voz. desligando o modo ou fechando o liland, o som volta direto do app.

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

a separação de instrumentos usa o [htdemucs](https://github.com/facebookresearch/demucs) (incluindo o htdemucs_6s, que separa a guitarra), de alexandre défossez, simon rouard e colaboradores da meta ai research, sob a licença mit. os modelos foram convertidos pra core ml pra rodar no próprio mac.

<br>

<a id="english"></a>

<details>
<summary><b>english version</b></summary>
<br>

<p align="center">
  a dynamic island in the macbook notch, to see and control the music that's playing.
</p>

<p align="center">
  <sub>macos 14 (sonoma) or newer · in 20 languages · no login</sub>
</p>

when music is playing, the notch grows and shows the album cover with an equalizer next to it. hover over it and it opens a player with the song, the artist, the progress bar and the controls, including shuffle and repeat when the app reports those modes.

no need to log in to anything. liland reads straight from spotify and the music app and, for other apps and sites, from what the mac shows under *now playing* in control center.

the pink button up top downloads the ready-made app. github's green "code" button only downloads the source code, which isn't what you want.

## ★ installation

requires **macos 14 (sonoma)** or newer. you can check under  › about this mac.

1. [download liland.zip](https://github.com/sacis/Liland/releases/latest/download/Liland.zip). if it doesn't unzip on its own, double-click the file in downloads.
2. drag **liland** into the **applications** folder.
3. open liland. since it doesn't come from the app store, the mac shows a warning saying it couldn't verify the app. close the warning **without** clicking *move to trash*.
4. go to system settings › privacy & security, scroll to the bottom and click **open anyway** next to the message about liland. the mac will ask for your password.

this only needs to be done once. after that liland opens normally and sits in the menu bar, with a capsule icon.

the first time spotify or music is open, macos asks whether liland can control them. just click ok. if you deny it by accident, you can allow it later in system settings › privacy & security › automation.

**to update:** quit liland (capsule icon › quit liland), download the zip again and repeat from step 2. when the mac asks, choose *replace*.

## ★ deezer, youtube and other sites

spotify and apple music work right away. for the rest (deezer, youtube, tidal and anything else playing in the browser), liland uses an extra piece, nowplayinghelper, which the mac asks you to allow the same way as liland itself:

1. with nothing playing, hover over the notch and click **turn on**. you can also do it from the capsule icon, under *turn on deezer and browsers…*.
2. close the mac's warning about nowplayinghelper, again without moving it to the trash.
3. system settings opens at privacy & security. scroll to the bottom and click **open anyway** next to nowplayinghelper.

after updating liland, you may sometimes need to repeat this.

why the extra step: since macos 15.4, only apple programs can see what's playing on the system. liland works around this by asking `perl`, which comes preinstalled on the mac, to do the reading. if a macos update closes that loophole, deezer and browsers stop showing up, but spotify and apple music keep working.

## ★ options

they're all in the capsule icon in the menu bar.

**show when the song changes** opens the island for a few seconds when the track changes.

**open only on click** makes the island open only when you click the notch, and no longer when the mouse hovers over it. to go back, use *open on hover*.

**equalizer follows the music** makes the bars follow the actual beat (macos 14.4 or newer). the first time, macos asks permission for liland to access audio. it only measures the sound in the moment, it doesn't record or save anything. if you deny it, the bars keep their usual animation and the menu shows *allow audio access in settings…* so you can allow it later.

**advanced** adds sound controls below the open player (also macos 14.4 or newer, with the same audio permission):

- **vocals**, **guitar**, **bass** and **drums** play only the parts you pick, at the volume of the full song. you can combine more than one. clicking a part again removes it, and removing all of them brings back the full song. guitar only shows up on macs with apple silicon and, since it uses a separate model, takes a moment to kick in when picked.
- **part volumes**: the button next to ↺ swaps the equalizer for a volume control for each part plus one for **others**, which is the rest of the song (keys, strings, horns…), from 0 to 200%. you can remove the vocals to sing along or turn the bass up to learn it by ear. with any part isolated, the volumes only apply among the chosen parts. the overall volume is still that of the full song.
- five-band **equalizer**, from lows (80 hz) to highs (10 khz), from −12 to +12 db.
- **pitch** raises or lowers the song up to 6 semitones without changing the speed.
- **↺** resets everything. your settings are saved for next time.

with advanced on, liland plays the music, already adjusted, instead of the app. that's why the sound lags a little: about three tenths of a second when isolating parts or changing their volume (an eighth on intel macs) and another tenth when changing pitch. in a video, lips look slightly out of sync with the voice. turn the mode off or quit liland and the sound goes back to coming straight from the app.

<details>
<summary>how liland separates vocals, guitar, bass and drums</summary>
<br>

on macs with apple silicon, liland uses htdemucs, a neural network from meta trained on songs recorded part by part. it runs on the mac itself, without sending anything to the internet. vocals, bass and drums come from one model. guitar is the rest of the song in that model, filtered by a second model that recognizes guitar and only runs while it's selected: that way it comes through with its full body. the network needs to hear a chunk of the song to separate it, which is where the three-tenths-of-a-second delay comes from. it's much cleaner than an estimate, but it isn't perfect: in a very busy passage a bit of the other instruments still comes through, and the guitar may bring along a keyboard or synth with a similar sound.

on intel macs, which can't run the network fast enough, the separation is an estimate made on the fly. liland recognizes vocals and bass because they sit in the center of the mix, so instruments that are also in the center still come through a little, and an instrument that sounds a lot like drums (a hard-strummed acoustic guitar, for example) can leak into them.

</details>

there's also **open at login** and **quit liland**. the language follows the mac's.

## ★ building from source

if you'd rather build the app on your mac instead of downloading the ready-made one, the steps are here. at the end, liland is already installed in the applications folder.

<details>
<summary>see the step by step</summary>
<br>

first install [xcode from the app store](https://apps.apple.com/app/xcode/id497799835). it's free, but the download is big. when it's done, open xcode once, accept the terms and wait for it to install its components. then you can close it.

now open terminal (<kbd>⌘</kbd> <kbd>space</kbd>, type *terminal* and press <kbd>return</kbd>). for each step below, copy the command, paste it into terminal and press <kbd>return</kbd>, waiting for one to finish before pasting the next. if it asks for a password, it's your mac password. it's normal for nothing to show on screen while you type.

**1.** install homebrew. if you already have it, skip this step.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

press <kbd>return</kbd> when it asks to continue. if a section called **next steps** with more commands shows up at the end, run those too. then close terminal and open it again.

**2.** install xcodegen.

```bash
brew install xcodegen
```

**3.** download and install liland. you can paste all three lines at once.

```bash
git clone https://github.com/sacis/Liland.git
cd Liland
./scripts/build.sh --install
```

the code goes into a `Liland` folder inside your home folder. the build takes a few minutes and ends with **✓ instalado em /applications/liland.app** ("installed in", in portuguese). liland opens on its own and shows up in the menu bar.

**to update** later:

```bash
cd ~/Liland
git pull
./scripts/build.sh --install
```

**if something goes wrong**

`command not found: brew` means homebrew didn't finish installing. run the command from step 1 again, and don't forget the **next steps** commands.

`xcodebuild requires Xcode` or `xcode-select: error` means terminal can't find xcode. check that it's in the applications folder and run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`destination path 'Liland' already exists` means you've already downloaded liland before. use the update commands.

</details>

## ★ credits

reading deezer and browsers was adapted from [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), by jonas van den berg and contributors, under the 3-clause bsd license (see [nowplayinghelper/license](NowPlayingHelper/LICENSE)).

instrument separation uses [htdemucs](https://github.com/facebookresearch/demucs) (including htdemucs_6s, which separates guitar), by alexandre défossez, simon rouard and contributors at meta ai research, under the mit license. the models were converted to core ml to run on the mac itself.

</details>
