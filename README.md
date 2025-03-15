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

# Setup

# Secrets

> secrets:encrypt_store(bitcoin_rpc_pass, "bitcoin rpc password").
> secrets:encrypt_store(nostr_nsec, "nostr private key (nsec)").
> secrets:encrypt_store(smtp_pass, "password for smtp sending").
> secrets:encrypt_store(lnd_macaroon_pass, "macaroon for lnd").
> secrets:encrypt_store(cln_rune_pass, "rune for core lightning cln").
