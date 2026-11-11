# TinyFingersJail

App de macOS que abre o [TinyFingers](https://tinyfingers.net/) em tela cheia, num navegador
embutido, e **tranca o Mac** enquanto a criança brinca: o teclado continua funcionando para o
site, mas Spotlight (⌘Espaço), ⌘Tab, Mission Control, ⌘Q, teclas de função e gestos do trackpad
param de funcionar.

**Duas formas de sair** (qualquer uma serve):

| Saída | Como |
| --- | --- |
| Teclado | Segure **⌃⌥⌘ + Q** por 3 segundos |
| Mouse | **Clique e segure o canto superior direito** da tela por 5 segundos |

Nas duas aparece uma barra de progresso. Soltar antes do fim zera a contagem — é isso que
impede a criança de sair por acidente.

A área de clique do canto fica **desenhada na tela** (um quadrado translúcido com a palavra
"sair") nos primeiros 12 segundos e depois desaparece, para a criança não ficar com um alvo na
tela. Ela acende de novo sozinha quando você pressiona ali. Dá para deixá-la sempre visível, ou
nunca, com `cornerExitMarker`.

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
4. Para sair: **⌃⌥⌘Q por 3s** ou **clique e segure o canto superior direito por 5s**.

As três teclas modificadoras ficam vizinhas no canto inferior esquerdo do teclado (Control,
Option, Command) — dá para apertar as três com a mão esquerda e o Q com a outra.

---

## O que fica bloqueado

| Bloqueado | Como |
| --- | --- |
| Spotlight (⌘Espaço), ⌘Tab, ⌘Q, ⌘W, ⌘H, ⌃setas, atalhos com ⌘/⌃ | Event tap do sistema |
| Mission Control, Exposé, teclas F1–F20, Esc, fn/globo | Event tap do sistema |
| Teclas de mídia e volume | Event tap do sistema |
| Gestos do trackpad (swipe entre Spaces, pinça, Mission Control) | Event tap do sistema |
| Dock, barra de menus, menu Apple | Modo de apresentação do macOS |
| Sair do site (links, anúncios, pop-ups, janelas novas) | O navegador embutido só carrega `tinyfingers.net` |
| Menu de contexto, seleção de texto, arrastar imagens | Script injetado na página |

Letras, números e setas **continuam passando** para o site — é com elas que a brincadeira funciona.

### Liberado de propósito

**⌘⌥Esc (Forçar Encerramento)** passa de propósito: nenhuma criança acerta isso sem querer, e é
uma saída de emergência garantida. Para bloquear também, use `"blockForceQuit": true` na
configuração.

### O que não dá para bloquear

- **Botão de força / desligar** e a tela de login: são tratados pelo próprio sistema.
- **Trackpad/mouse físico**: o cursor se move à vontade (é a graça do site), mas como só existe
  uma janela em tela cheia, não há nada para clicar fora dela.

---

## Proteções contra travamento

Um event tap de teclado é **síncrono**: o sistema espera a resposta do app antes de entregar
cada tecla. Se o app travar, o teclado do Mac inteiro para junto — e sem teclado não há como
sair. Três camadas evitam isso:

1. **O tap roda numa thread própria**, com run loop dedicado. Ele não depende da interface:
   mesmo com a página consumindo 100% da main thread, as teclas continuam sendo processadas.
   O callback do tap não faz nada de UI.
2. **Watchdog**: a interface manda um "sinal de vida" a cada segundo. Se parar por **6
   segundos**, o tap é desligado e o teclado volta inteiro para o sistema. Se a interface
   voltar a responder, a trava religa sozinha.
3. **Encerramento automático**: se a interface ficar travada por **20 segundos**, o app se
   encerra sozinho. Dock e barra de menus voltam, e o Mac fica usável. Nunca é preciso
   reiniciar a máquina por causa deste app.

O watchdog ignora pausas do próprio sistema (Mac dormindo, carga alta) para não confundir sono
com travamento. A contagem de saída também roda fora da main thread — a saída funciona mesmo
com a tela congelada.

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
  "cornerExit": true,
  "cornerExitPosition": "topRight",
  "cornerExitSeconds": 5,
  "cornerExitSize": 72,
  "cornerExitMarker": "startup",
  "blockForceQuit": false,
  "blockSessionTermination": false
}
```

| Campo | O que faz |
| --- | --- |
| `url` | Site que abre. Pode trocar por qualquer outro (ex.: outro joguinho). |
| `allowedHosts` | Domínios extras liberados para navegação, além do domínio da `url`. |
| `exitKey` | Tecla da combinação de saída (`a`–`z`, `0`–`9`, `space`, `escape`…). |
| `exitModifiers` | Modificadores obrigatórios: `command`, `control`, `option`, `shift`. |
| `exitHoldSeconds` | Quantos segundos segurar a combinação (entre 0,5 e 15). |
| `cornerExit` | Liga/desliga a saída pelo canto da tela. |
| `cornerExitPosition` | `topRight`, `topLeft`, `bottomRight` ou `bottomLeft`. O TinyFingers usa o canto **superior esquerdo** para o painel dos pais, então o padrão aqui é o direito. |
| `cornerExitSeconds` | Quantos segundos segurar no canto (entre 1 e 20). |
| `cornerExitSize` | Tamanho da área do canto, em pontos (entre 24 e 400). |
| `cornerExitMarker` | Quando a área de clique aparece: `startup` (ao abrir e depois some), `always` ou `never`. |
| `blockForceQuit` | `true` bloqueia também ⌘⌥Esc (Forçar Encerramento). |
| `blockSessionTermination` | Bloqueia desligar/reiniciar/encerrar sessão. Deixe `false` a menos que queira mesmo travar tudo. |

Se a combinação ficar sem nenhum modificador, o app volta ao padrão ⌃⌥⌘Q por segurança.

Para testar rapidinho sem editar o arquivo:

```bash
TFJ_URL="https://exemplo.com" TFJ_HOLD_SECONDS=1 TFJ_CORNER_SECONDS=2 \
  ./build/TinyFingersJail.app/Contents/MacOS/TinyFingersJail
```

---

## Como está feito

```
Sources/TinyFingersJail/
  main.swift                ponto de entrada
  AppDelegate.swift         janelas, modo quiosque, permissão, sinal de vida, saída
  KioskWindow.swift         janela sem bordas cobrindo a tela
  BrowserController.swift   WKWebView preso ao site
  EventGuard.swift          event tap em thread própria + watchdog + combinação de saída
  CornerExitWatcher.swift   saída por clique-e-segure no canto da tela
  HoldTracker.swift         contagem do "segure para sair", fora da main thread
  OverlayView.swift         dica no topo e barra de progresso da saída
  Config.swift              config.json, combinação de teclas, canto de saída
Resources/Info.plist
build.sh
```

Detalhe importante: além do event tap existe um monitor local de teclado dentro do app. Ou seja,
**a combinação de saída funciona mesmo sem a permissão de Acessibilidade** — você nunca fica preso.

---

## Licença

Domínio público ([The Unlicense](LICENSE)). Use, copie, modifique e distribua à vontade,
para qualquer fim, sem pedir permissão e sem precisar dar crédito.

Este projeto não tem afiliação com o TinyFingers.
