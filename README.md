# Liland

Uma Dynamic Island para o notch do MacBook, integrada ao **Spotify** e ao **Apple Music**.

- Com música tocando, o notch cresce e mostra a capa do álbum e um equalizador.
- Ao passar o mouse, abre um player com a música, o artista, a barra de progresso e os controles.
- Não precisa de login: o Liland lê direto dos apps do Spotify e do Música.

Deezer, Tidal, YouTube Music e players no navegador ainda não são suportados.

## Instalação

Requisitos: macOS 14 ou mais novo, [Xcode](https://apps.apple.com/app/xcode/id497799835) e [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/sacis/Liland.git
cd Liland
./scripts/build.sh --install
```

O Liland é instalado em `/Applications` e aparece como um ícone de cápsula na barra de menus.

## Primeiro uso

Na primeira vez que o Spotify ou o Música estiver aberto, o macOS pergunta se o Liland pode controlá-lo. Clique em **OK**.

Se você negar sem querer, libere depois em **Ajustes do Sistema › Privacidade e Segurança › Automação**.

## Opções

No ícone de cápsula da barra de menus:

- **Mostrar ao trocar de música**: abre a ilha por alguns segundos quando a faixa muda.
- **Abrir ao iniciar o Mac**
- **Sair do Liland**

O Liland segue o idioma do Mac e está disponível em 20 idiomas.
