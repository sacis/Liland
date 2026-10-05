# Liland

Uma Dynamic Island para o notch do MacBook, integrada ao **Spotify** e ao **Apple Music**. Escrita em Swift (SwiftUI + AppKit), roda como app nativo na barra de menus, sem ícone no Dock.

- **Tocando música**: o notch cresce para os lados, com a capa do álbum à esquerda e um equalizador na cor da capa à direita.
- **Passou o mouse**: abre o player completo, com capa, nome, artista, barra de progresso (dá para arrastar) e os botões anterior, play/pause e próxima. O ícone no canto mostra de qual app vem a música.
- **Trocou de música**: a ilha continua minimizada e só troca a capa. Se quiser que ela abra sozinha por alguns segundos mostrando a nova faixa, ative "Mostrar ao trocar de música" no menu.
- **Nada tocando**: ao passar o mouse aparece um atalho para abrir o app de música usado por último.

Não precisa de login. O Liland conversa com os apps do Spotify e do Música via AppleScript, que já informa a faixa, a capa e a posição e aceita os comandos de controle. Os dois apps também avisam o sistema a cada play, pause e troca de faixa, então a ilha reage na hora.

## Vários players

Se mais de um app estiver aberto, a ilha mostra o que **começou a tocar por último**. Se nenhum estiver tocando, mostra o último usado, pausado.

Para adicionar outro player que tenha AppleScript, basta criar uma nova `PlayerDefinition` em [PlayerDefinition.swift](Liland/Players/PlayerDefinition.swift) e incluí-la em `NowPlayingController`.

Deezer, Tidal, YouTube Music e players no navegador **ainda não são suportados**. Eles não têm AppleScript. A única forma de lê-los é pelo "Reproduzindo" do sistema (MediaRemote), que a Apple fechou para apps de terceiros a partir do macOS 15.4.

## Idiomas

O Liland usa automaticamente o idioma do Mac (**Ajustes do Sistema › Geral › Idioma e Região**), inclusive o idioma escolhido só para ele em "Idiomas de Apps".

Idiomas incluídos: inglês (base), português do Brasil, português de Portugal, espanhol, francês, alemão, italiano, holandês, sueco, dinamarquês, norueguês, finlandês, polonês, russo, ucraniano, turco, japonês, coreano, chinês simplificado e chinês tradicional. Em qualquer outro idioma, o Liland aparece em inglês.

As traduções ficam em `Liland/Resources/<idioma>.lproj/Localizable.strings`. O texto pedido ao macOS na hora de pedir permissão fica em `InfoPlist.strings`.

## Compilar e instalar

Requisitos: macOS 14 ou mais novo, Xcode e [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/build.sh            # compila em build/Liland.app
./scripts/build.sh --install  # compila, instala em /Applications e abre
```

Para mexer no código pelo Xcode: `xcodegen generate` e depois abra o `Liland.xcodeproj`.

### Primeira vez

Na primeira vez que o Spotify ou o Música estiver aberto, o macOS pergunta se o Liland pode controlá-lo: clique em **OK**. A pergunta é feita uma vez para cada app. Se você negar, a ilha mostra um botão que leva para **Ajustes do Sistema › Privacidade e Segurança › Automação**, onde dá para liberar depois.

O app é assinado localmente (ad-hoc). Se o macOS voltar a pedir a permissão depois de recompilar, é por isso: a assinatura muda a cada build. Para evitar, escolha seu time em *Signing & Capabilities* no Xcode.

## Menu

O ícone de cápsula na barra de menus tem:

- Mostrar ao trocar de música
- Abrir ao iniciar o Mac
- Abrir Spotify / Abrir Música
- Sair do Liland

## Estrutura

```
Liland/
  App/        ponto de entrada, menu da barra e preferências
  Notch/      janela flutuante, geometria do notch, forma e lógica de abrir/fechar
  Players/    Spotify e Apple Music via AppleScript, escolha do player ativo, cor da capa
  Views/      visual compacto, player expandido, progresso e equalizador
  Resources/  ícone, Info.plist e traduções (*.lproj)
scripts/
  build.sh         compila (e instala)
  make-icon.swift  gera o ícone do app
```

### Como funciona

- A janela é um `NSPanel` transparente e sem bordas, acima da barra de menus e presente em todos os Spaces, inclusive com apps em tela cheia. Ela nunca rouba o foco do app que você está usando.
- O tamanho do notch vem de `NSScreen.safeAreaInsets` e `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. Em Macs sem notch, a ilha aparece como uma pílula no topo da tela.
- A janela ignora o mouse, exceto quando a ilha está aberta e o cursor está em cima dela. Assim os cliques em volta do notch continuam chegando à barra de menus.
- Além das notificações dos apps, o Liland consulta o estado a cada 5 segundos enquanto o player está aberto, para pegar mudanças feitas em outro aparelho (Spotify Connect, AirPlay).
- Rádios e transmissões ao vivo não têm duração; nesse caso a barra de progresso dá lugar a "Ao vivo".
