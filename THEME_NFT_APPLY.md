# DamageBDD NFT themes — patch application

This changes only selected files in the DamageBDD, ECAI and Nosternity apps.
It is based on the three `latest-*.tar.gz` snapshots supplied with the request.

At the repository root (after backing up local edits):

```sh
git apply --check damage-theme-nft.patch
git apply damage-theme-nft.patch
rebar3 compile
rebar3 eunit --module=damage_theme_manifest_tests
node --check apps/damage/priv/static/js/theme-studio.js
```

Alternatively extract the targeted overlay archive at the repository root;
it has the same file paths but will overwrite existing files.

Read `apps/damage/docs/theme-nft-marketplace.md` for deployment prerequisites.
In particular, **deploy and configure the Sophia AEX-141 theme contract before
accepting live payments**. The contract was not compiled or deployed here.
