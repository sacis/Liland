<p align="center">
  <img src="Liland/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="112" alt="">
</p>

<h1 align="center">Liland ♡(>ᴗ•)</h1>

<p align="center">
  Uma Dynamic Island no notch do MacBook, pra ver e controlar a música que está tocando.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Spotify-fbd3e4?style=flat-square" alt="Spotify">
  <img src="https://img.shields.io/badge/Apple_Music-fbd3e4?style=flat-square" alt="Apple Music">
  <img src="https://img.shields.io/badge/Deezer-fbd3e4?style=flat-square" alt="Deezer">
  <img src="https://img.shields.io/badge/YouTube-fbd3e4?style=flat-square" alt="YouTube">
  <img src="https://img.shields.io/badge/e_outros_sites-fbd3e4?style=flat-square" alt="e outros sites">
</p>

<p align="center">
  <a href="https://github.com/sacis/Liland/releases/latest/download/Liland.zip"><img src="docs/download.svg" height="52" alt="Baixar o Liland"></a>
</p>

<p align="center">
  <sub>macOS 14 (Sonoma) ou mais novo · em 20 idiomas · sem login</sub>
</p>

<br>

Quando tem música tocando, o notch cresce e mostra a capa do álbum com um equalizador do lado. Passando o mouse por cima, ele abre um player com a música, o artista, a barra de progresso e os controles, inclusive aleatório e repetir quando o app informa esses modos.

Não precisa fazer login em nada. O Liland lê direto do Spotify e do app Música e, pros outros apps e sites, do que o Mac mostra em *Tocando Agora* na Central de Controle.

O botão rosa ali em cima baixa o app pronto. O botão verde "Code" do GitHub baixa só o código-fonte, não é ele que você quer.

## Instalação

Precisa de **macOS 14 (Sonoma)** ou mais novo. Dá pra conferir em  › Sobre Este Mac.

1. [Baixe o Liland.zip](https://github.com/sacis/Liland/releases/latest/download/Liland.zip). Se ele não descompactar sozinho, dê dois cliques no arquivo dentro de Downloads.
2. Arraste o **Liland** pra pasta **Aplicativos**.
3. Abra o Liland. Como ele não vem da App Store, o Mac mostra um aviso dizendo que não pôde verificar o app. Feche o aviso, **sem** clicar em *Mover para o Lixo*.
4. Vá em Ajustes do Sistema › Privacidade e Segurança, role até o final e clique em **Abrir Mesmo Assim** ao lado da mensagem sobre o Liland. O Mac vai pedir sua senha.

Isso só precisa ser feito uma vez. Depois disso o Liland abre normalmente e fica na barra de menus, com um ícone de cápsula.

Na primeira vez que o Spotify ou o Música estiverem abertos, o macOS pergunta se o Liland pode controlá-los. É só clicar em OK. Se negar sem querer, dá pra liberar depois em Ajustes do Sistema › Privacidade e Segurança › Automação.

**Pra atualizar:** feche o Liland (ícone de cápsula › Sair do Liland), baixe o zip de novo e repita a partir do passo 2. Quando o Mac perguntar, escolha *Substituir*.

## Deezer, YouTube e outros sites

Spotify e Apple Music funcionam direto. Pro resto (Deezer, YouTube, TIDAL e o que mais tocar no navegador), o Liland usa uma peça extra, o NowPlayingHelper, que o Mac pede pra liberar do mesmo jeito que o próprio Liland:

1. Sem nada tocando, passe o mouse no notch e clique em **Ativar**. Também dá pelo ícone de cápsula, em *Ativar Deezer e navegadores…*.
2. Feche o aviso do Mac sobre o NowPlayingHelper, de novo sem mover pro Lixo.
3. Os Ajustes do Sistema abrem em Privacidade e Segurança. Role até o final e clique em **Abrir Mesmo Assim** ao lado do NowPlayingHelper.

Depois de atualizar o Liland, às vezes é preciso repetir isso.

Por que esse passo a mais: desde o macOS 15.4, só programas da Apple conseguem ver o que está tocando no sistema. O Liland contorna isso pedindo ao `perl`, que já vem instalado no Mac, pra fazer a leitura. Se alguma atualização do macOS fechar essa brecha, o Deezer e os navegadores param de aparecer, mas o Spotify e o Apple Music continuam funcionando.

## Opções

Ficam todas no ícone de cápsula da barra de menus.

**Mostrar ao trocar de música** abre a ilha por alguns segundos quando a faixa muda.

**Abrir só ao clicar** faz a ilha abrir só quando você clica no notch, e não mais quando o mouse passa por cima. Pra voltar, use *Abrir ao passar o mouse*.

**Equalizador acompanha a música** faz as barrinhas seguirem a batida de verdade (macOS 14.4 ou mais novo). Na primeira vez, o macOS pede permissão pro Liland acessar o áudio. Ele só mede o som na hora, não grava nem salva nada. Se você negar, as barrinhas continuam com a animação de sempre e aparece no menu a opção *Permitir acesso ao áudio nos Ajustes…* pra liberar depois.

**Avançado** coloca controles de som embaixo do player aberto (também macOS 14.4 ou mais novo, com a mesma permissão de áudio):

- **Voz**, **Baixo** e **Bateria** tocam só as partes que você escolher, no volume da música inteira. Dá pra combinar mais de uma. Clicar de novo numa parte tira ela, e tirando todas a música volta inteira.
- **Equalizador** de cinco faixas, dos graves (80 Hz) aos agudos (10 kHz), de −12 a +12 dB.
- **Tom** sobe ou desce a música até 6 semitons sem mudar a velocidade.
- **↺** volta tudo ao normal. Os ajustes ficam salvos pra próxima vez.

Com o Avançado ligado, quem toca a música é o Liland, já ajustada, no lugar do app. Por isso o som atrasa um pouquinho: cerca de um oitavo de segundo ao isolar partes e mais um décimo ao mudar o tom. Num vídeo, a boca pode ficar levemente fora de sincronia com a voz. Desligando o modo ou fechando o Liland, o som volta direto do app.

<details>
<summary>Como o Liland separa voz, baixo e bateria</summary>
<br>

É uma estimativa feita na hora, não uma separação perfeita. O Liland reconhece a voz e o baixo por estarem no centro da mixagem, então instrumentos que também estão no centro ainda aparecem um pouco, e um instrumento muito parecido com bateria (um violão bem batido, por exemplo) pode vazar nela.

Os agudos do baixo se perdem ao isolar, então, quando a voz não está junto, o Liland recria esses agudos a partir do próprio baixo pra ele não soar abafado. Numa música sem baixo, **Baixo** fica em silêncio em vez de tocar restos de outros instrumentos.

</details>

Também tem **Abrir ao iniciar o Mac** e **Sair do Liland**. O idioma segue o do Mac.

## Compilar a partir do código

Se você prefere montar o app no seu Mac em vez de baixar o pronto, os passos estão aqui. No fim, o Liland já fica instalado na pasta Aplicativos.

<details>
<summary>Ver o passo a passo</summary>
<br>

Primeiro instale o [Xcode pela App Store](https://apps.apple.com/app/xcode/id497799835). É gratuito, mas o download é grande. Quando terminar, abra o Xcode uma vez, aceite os termos e espere ele instalar os componentes. Depois pode fechar.

Agora abra o Terminal (<kbd>⌘</kbd> <kbd>Espaço</kbd>, digite *Terminal* e aperte <kbd>Enter</kbd>). Em cada passo abaixo, copie o comando, cole no Terminal e aperte <kbd>Enter</kbd>, esperando um terminar antes de colar o próximo. Se ele pedir senha, é a senha do Mac. É normal não aparecer nada na tela enquanto você digita.

**1.** Instale o Homebrew. Se você já tem, pule este passo.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Aperte <kbd>Enter</kbd> quando ele pedir pra continuar. Se no final aparecer uma parte chamada **Next steps** com mais comandos, rode esses também. Depois feche o Terminal e abra de novo.

**2.** Instale o XcodeGen.

```bash
brew install xcodegen
```

**3.** Baixe e instale o Liland. Pode colar as três linhas de uma vez.

```bash
git clone https://github.com/sacis/Liland.git
cd Liland
./scripts/build.sh --install
```

O código fica numa pasta `Liland` dentro da sua pasta pessoal. A montagem leva alguns minutos e termina com **✓ Instalado em /Applications/Liland.app**. O Liland abre sozinho e já aparece na barra de menus.

**Pra atualizar** depois:

```bash
cd ~/Liland
git pull
./scripts/build.sh --install
```

**Se der erro**

`command not found: brew` quer dizer que o Homebrew não terminou de instalar. Rode o comando do passo 1 de novo, sem esquecer os comandos do **Next steps**.

`xcodebuild requires Xcode` ou `xcode-select: error` quer dizer que o Terminal não está achando o Xcode. Confira se ele está na pasta Aplicativos e rode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`destination path 'Liland' already exists` quer dizer que você já baixou o Liland antes. Use os comandos de atualizar.

</details>

## Créditos

A leitura do Deezer e dos navegadores foi adaptada do [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), de Jonas van den Berg e colaboradores, sob a licença BSD de 3 cláusulas (veja [NowPlayingHelper/LICENSE](NowPlayingHelper/LICENSE)).
