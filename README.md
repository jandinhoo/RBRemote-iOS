# RB Remote iOS

Este e o port inicial em SwiftUI do RB Remote para iPhone, preparado para GitHub e Codemagic.

## Estrutura

- `RBRemote/` contem o app SwiftUI, `Info.plist` e assets.
- `project.yml` gera o projeto Xcode usando XcodeGen.
- `codemagic.yaml` gera um `.ipa` unsigned para instalacao manual com Sideloadly/AltStore.
- `EncodedAssets/` guarda as imagens em base64 para subir pelo GitHub sem corromper PNG.
- `scripts/restore-assets.sh` recria os PNGs antes da build.
- `ios-version-example.json` mostra o formato do arquivo de atualizacao iOS.

## Como subir no GitHub

Suba a pasta `ios/RBRemote` como um repositorio Git separado ou coloque esta pasta na raiz de um repositorio.

Arquivos importantes que precisam ir para o GitHub:

- `RBRemote/RBRemoteApp.swift`
- `RBRemote/Info.plist`
- `RBRemote/Assets.xcassets`
- `EncodedAssets/`
- `scripts/restore-assets.sh`
- `project.yml`
- `codemagic.yaml`

## Como abrir no Xcode em um Mac

Se estiver em um Mac:

1. Instale o Xcode pela App Store.
2. Instale o XcodeGen:

```bash
brew install xcodegen
```

3. Entre na pasta do projeto:

```bash
cd RBRemote
```

4. Gere o projeto:

```bash
bash scripts/restore-assets.sh
xcodegen generate
```

5. Abra:

```bash
open RBRemote.xcodeproj
```

No Xcode, se quiser instalar direto no seu iPhone, configure `Signing & Capabilities`.

## Como gerar IPA no Codemagic

1. Conecte o repositorio GitHub no Codemagic.
2. Escolha usar o arquivo `codemagic.yaml`.
3. Rode o workflow `RB Remote iOS - IPA manual`.
4. Ao terminar, baixe o artefato `RBRemote-unsigned.ipa`.

Esse `.ipa` unsigned e para o usuario assinar/instalar manualmente com Sideloadly, AltStore ou ferramenta parecida.

## Atualizacao no iOS pelo navegador

O iOS nao instala o app automaticamente. O app apenas verifica um manifest JSON e abre o link de download no navegador.

Crie um arquivo `ios-version.json` no Drive ou outro servidor com este formato:

```json
{
  "versionCode": 2,
  "versionName": "1.1",
  "downloadUrl": "https://seu-link-de-download-do-ios",
  "notes": "Melhorias do RB Remote para iOS."
}
```

Depois, no arquivo `RBRemoteApp.swift`, altere:

```swift
static let updateManifestURLString = ""
```

para o link direto desse `ios-version.json`.

## Observacoes importantes

- O app usa HTTP local para falar com o RadioBoss, entao o `Info.plist` ja inclui permissao de rede local e App Transport Security.
- O pagamento abre o link do Mercado Pago no navegador.
- Conta FREE so usa `PROXIMA FAIXA`; o restante pede premium, igual no Android.
- Para compilar localmente ainda precisa de Mac com Xcode.
- Para instalar manualmente, o usuario ainda precisa assinar o `.ipa` com ferramenta externa.
