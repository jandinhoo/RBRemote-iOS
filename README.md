# RB Remote iOS

Port oficial do RB Remote para iPhone.

## Sobre

RB Remote controla o RadioBOSS pela API remota na rede local.

O app permite configurar IP, porta e senha, usar comandos de reproducao, visualizar a faixa atual e a proxima faixa, alem de validar recursos premium pelo servidor do RB Remote.

## Build

Este repositorio esta preparado para build no Codemagic usando o arquivo:

```text
codemagic.yaml
```

Workflow:

```text
RB Remote iOS - IPA manual
```

Artefato gerado:

```text
RBRemote-unsigned.ipa
```

## Instalacao

O IPA gerado e destinado a instalacao manual.

No iOS, o usuario precisa assinar e instalar o app com uma ferramenta externa, como Sideloadly, AltStore ou similar.

## Assinatura futura

O Bundle ID padrao do app e:

```text
br.com.jandinho.rbremote
```

Antes de assinar com outro provisioning profile, gere o app usando `RBREMOTE_BUNDLE_ID` igual ao Bundle ID aceito por esse profile. Isso evita erro de assinatura por Bundle ID diferente.

## Atualizacoes

O iOS nao permite instalar atualizacoes automaticamente fora da App Store.

O app pode verificar se existe uma nova versao e abrir o link de download pelo navegador.

## Observacoes

- O RadioBOSS precisa estar rodando no computador.
- A API remota do RadioBOSS precisa estar ativada.
- O celular e o computador precisam estar na mesma rede.
- A porta configurada no app precisa ser a mesma configurada no RadioBOSS.
- Recursos premium dependem do servidor RB Remote.
