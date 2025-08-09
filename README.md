Damage BDD
==========

An Erlang OTP application to run bdd load tests at scale.
Inspired by [https://github.com/behave/behave](behave).

Read more [https://damagebdd.com](here)

DamageBDD Hosted Service
------------------------

You can use the server at https://run.damagebdd.com to run tests

Read The Manual [https://damagebdd.com/manual](here) to get started quickly.

[https://damagebdd.com/api/](Swagger API) 

# Damage Node Setup

To run a damage node locally:

```
git clone https://github.com/DamageBDD/DamageBDD.git
rebar3 shell
```

## Setup Secrets

### Bitcoin RPC


```
secrets:encrypt_store(bitcoin_rpc_password, "bitcoin rpc password").

```
#### Generate Bitcoin RPC auth

```
 ./bin/bitcoin_rpcauth.py
```

### Nostr Integration

```
secrets:encrypt_store(nostr_nsec, "nostr private key (nsec)").
```

### SMTP Auth

```
secrets:encrypt_store(smtp_password, "password for smtp sending").
```
### Core Lightning Integration

Create Rune

```
lightning-cli createrune
```


```
secrets:encrypt_store(cln_rune, "rune for core lightning cln").
```

### LND Lightning Integration

```
secrets:encrypt_store(lnd_macaroon, "macaroon for lnd").
```


