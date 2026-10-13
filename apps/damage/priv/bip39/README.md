# BIP-39 English wordlist

`english.txt` is the 2048-word English list from bitcoin/bips, in the
specified order with one word per line and a final LF.

Source: https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt
Specification: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
BIP-39 authors: Marek Palatinus, Pavol Rusnak, Aaron Voisine, Sean Bowe.
The BIP identifies its license as MIT. The list is retained as interoperability
data, not modified or replaced by a project-specific dictionary.

SHA-256 of the exact file bytes:

```
2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda
```

`damage_ae_wallet` checks this digest before using the list. Keep this directory
in packaged releases; there is no network download or unverified fallback.
The local `.gitattributes` entry prevents automatic CRLF conversion.
