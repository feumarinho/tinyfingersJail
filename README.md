# TinyFingersJail

App de macOS que abre o [TinyFingers](https://tinyfingers.net/) em tela cheia, num navegador
embutido, e **tranca o Mac** enquanto a criança brinca: o teclado continua funcionando para o
site, mas Spotlight (⌘Espaço), ⌘Tab, Mission Control, ⌘Q, teclas de função e gestos do trackpad
param de funcionar.

Para sair: **segure ⌃⌥⌘ + Q por 3 segundos** (aparece uma barrinha de progresso na tela).

---

## Instalação

Precisa apenas das ferramentas de linha de comando da Apple (não precisa abrir o Xcode):

```bash
xcode-select --install   # só na primeira vez
git clone https://github.com/feumarinho/tinyfingersjail.git
cd tinyfingersjail
./build.sh --install     # gera e copia para /Applications
```

Sem `--install`, o app fica em `build/TinyFingersJail.app`.

### Primeira execução: liberar a Acessibilidade

Na primeira vez o macOS vai pedir permissão de **Acessibilidade**. Vá em:

> Ajustes do Sistema › Privacidade e Segurança › **Acessibilidade** → ligue o `TinyFingersJail`

Sem essa permissão o app **ainda funciona** (tela cheia, sem Dock, sem barra de menu, sem ⌘Tab),
mas o Spotlight e alguns atalhos do sistema continuam ativos. Assim que você autoriza, o app
detecta sozinho (em até 2 segundos) e ativa a trava completa — não precisa reabrir.

> Depois de **recompilar** o app, a assinatura muda e o macOS trata como se fosse outro programa:
> remova (`−`) e adicione (`+`) de novo na lista de Acessibilidade.

---

## Como usar

1. Abra o `TinyFingersJail` (Launchpad, Spotlight ou `open /Applications/TinyFingersJail.app`).
2. A tela toda vira o TinyFingers. Se você tiver mais de um monitor, os outros ficam pretos.
3. A criança bate no teclado e mexe o mouse à vontade.
4. Para sair, segure **⌃⌥⌘ + Q** (Control + Option + Command + Q) por 3 segundos.

Enquanto a combinação está pressionada aparece um painel com a barra de progresso. Se soltar
qualquer tecla antes do fim, a contagem zera — é isso que impede a criança de sair por acidente.

---

## O que fica bloqueado

| Bloqueado | Como |
| --- | --- |
| Spotlight (⌘Espaço), ⌘Tab, ⌘Q, ⌘W, ⌘H, ⌃setas, atalhos com ⌘/⌃ | Event tap do sistema |
| Mission Control, Exposé, teclas F1–F20, Esc | Event tap do sistema |
| Teclas de mídia e volume | Event tap do sistema |
| Gestos do trackpad (swipe entre Spaces, pinça, Mission Control) | Event tap do sistema |
| Dock, barra de menus, menu Apple | Modo de apresentação do macOS |
| Forçar Encerramento (⌘⌥Esc) | Modo de apresentação do macOS |
| Sair do site (links, anúncios, pop-ups, janelas novas) | O navegador embutido só carrega `tinyfingers.net` |
| Menu de contexto, seleção de texto, arrastar imagens | Script injetado na página |

Letras, números e setas **continuam passando** para o site — é com elas que a brincadeira funciona.

### O que não dá para bloquear

- **Botão de força / desligar** e a tela de login: são tratados pelo próprio sistema.
- **Trackpad/mouse físico**: a criança pode mover o cursor à vontade (é a graça do site), mas
  como só existe uma janela em tela cheia, não há nada para clicar fora dela.
- **Touch ID / Ctrl+⌘+Q (bloquear tela)** em algumas versões do macOS.

Se algum dia o app travar e a combinação não responder, a saída de emergência é segurar o botão
de força do Mac por alguns segundos.

---

## Configuração

Na primeira execução o app cria:

```
~/Library/Application Support/TinyFingersJail/config.json
```

```json
{
  "url": "https://tinyfingers.net/",
  "allowedHosts": [],
  "exitKey": "q",
  "exitModifiers": ["control", "option", "command"],
  "exitHoldSeconds": 3,
  "blockForceQuit": true,
  "blockSessionTermination": false
}
```

| Campo | O que faz |
| --- | --- |
| `url` | Site que abre. Pode trocar por qualquer outro (ex.: outro joguinho). |
| `allowedHosts` | Domínios extras liberados para navegação, além do domínio da `url`. |
| `exitKey` | Tecla da combinação de saída (`a`–`z`, `0`–`9`, `space`, `escape`…). |
| `exitModifiers` | Modificadores obrigatórios: `command`, `control`, `option`, `shift`. |
| `exitHoldSeconds` | Quantos segundos segurar (entre 0,5 e 15). |
| `blockForceQuit` | Bloqueia ⌘⌥Esc (Forçar Encerramento). |
| `blockSessionTermination` | Bloqueia desligar/reiniciar/encerrar sessão. Deixe `false` a menos que queira mesmo travar tudo. |

Se a combinação ficar sem nenhum modificador, o app volta ao padrão ⌃⌥⌘Q por segurança.

Para testar rapidinho sem editar o arquivo:

```bash
TFJ_URL="https://exemplo.com" TFJ_HOLD_SECONDS=1 ./build/TinyFingersJail.app/Contents/MacOS/TinyFingersJail
```

---

## Como está feito

```
Sources/TinyFingersJail/
  main.swift              ponto de entrada
  AppDelegate.swift       janelas, modo quiosque, permissão, saída
  KioskWindow.swift       janela sem bordas cobrindo a tela
  BrowserController.swift WKWebView preso ao site
  EventGuard.swift        event tap: engole atalhos e detecta a combinação de saída
  OverlayView.swift       dica no topo e barra do "segure para sair"
  Config.swift            config.json + combinação de teclas
Resources/Info.plist
build.sh
```

Detalhe importante: além do event tap, existe um monitor local de teclado dentro do app. Ou seja,
**a combinação de saída funciona mesmo sem a permissão de Acessibilidade** — você nunca fica preso.
