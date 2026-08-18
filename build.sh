#!/usr/bin/env bash
#
# Compila o TinyFingersJail.app. Precisa apenas das Command Line Tools da Apple
# (xcode-select --install) — não é necessário abrir o Xcode.
#
#   ./build.sh              # gera build/TinyFingersJail.app
#   ./build.sh --install    # gera e copia para /Applications
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TinyFingersJail"
OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/$APP_NAME.app"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Opção desconhecida: $arg" >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este app é para macOS." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc não encontrado. Instale as ferramentas de linha de comando com:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

echo "==> Montando o bundle em $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ícone é opcional: se existir Resources/AppIcon.icns (não versionado), entra no bundle.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

ARCH="$(uname -m)"
echo "==> Compilando ($ARCH)"
swiftc -O \
  -target "${ARCH}-apple-macos12.0" \
  -framework Cocoa -framework WebKit \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/TinyFingersJail/*.swift

echo "==> Assinando (ad-hoc)"
codesign --force --sign - "$APP" || echo "aviso: codesign falhou; o app continua funcionando."

if [[ $INSTALL -eq 1 ]]; then
  echo "==> Instalando em /Applications/$APP_NAME.app"
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  echo "Pronto: /Applications/$APP_NAME.app"
else
  echo "Pronto: $APP"
  echo "Para abrir: open \"$APP\""
fi

cat <<'EOF'

Lembretes:
  1. Na primeira execução, autorize o app em
     Ajustes do Sistema › Privacidade e Segurança › Acessibilidade.
     Sem isso o Spotlight (⌘Espaço) e o ⌘Tab continuam funcionando.
  2. Depois de recompilar, a assinatura muda: remova e adicione o app
     de novo na lista de Acessibilidade (botão − e depois +).
  3. Para sair do modo quiosque: segure ⌃⌥⌘ + Q por 3 segundos.
EOF
