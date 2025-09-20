# DamageBDD

An Erlang OTP application to run BDD load tests at scale.  
Inspired by [behave](https://github.com/behave/behave).

📖 Read more: [https://damagebdd.com](https://damagebdd.com)

## Hosted Service

You can use the public server at [https://run.damagebdd.com](https://run.damagebdd.com) to run tests.  
Read [The Manual](https://damagebdd.com/manual) to get started quickly.  
Swagger API available at: [https://damagebdd.com/api/](https://damagebdd.com/api/)

---

## Running a Damage Node Locally

```bash
git clone https://github.com/DamageBDD/DamageBDD.git
cd DamageBDD
rebar3 shell
```

---

## Setup Secrets

The application uses an encrypted secrets store. Configure integrations using `secrets:encrypt_store/2`.

### Bitcoin RPC

```erlang
secrets:encrypt_store(bitcoin_rpc_password, "bitcoin rpc password").
```

Generate Bitcoin RPC auth:

```bash
./bin/bitcoin_rpcauth.py
```

### Nostr Integration

```erlang
secrets:encrypt_store(nostr_nsec, "nostr private key (nsec)").
```

### SMTP Auth

```erlang
secrets:encrypt_store(smtp_password, "password for smtp sending").
```

### Core Lightning Integration

Create Rune:

```bash
lightning-cli createrune
```

```erlang
secrets:encrypt_store(cln_rune, "rune for core lightning cln").
```

### LND Lightning Integration

```erlang
secrets:encrypt_store(lnd_macaroon, "macaroon for lnd").
```

---

## Configuration via `sys.config`

The Erlang `sys.config` file allows you to configure the runtime. A sample is provided in the repo.  
Typical settings include:

```erlang
[
  {damagebdd, [
    {port, 8080},
    {bind_addr, "0.0.0.0"},
    {log_dir, "/var/log/damagebdd"},
    {data_dir, "/var/lib/damagebdd"},
    {upstreams, ["http://127.0.0.1:8080"]},
    {secrets_backend, encrypted_store}
  ]}
].
```

- **port**: Port for the verification node to listen on.  
- **bind_addr**: Bind interface (default `0.0.0.0`).  
- **log_dir**: Path for runtime logs.  
- **data_dir**: Data storage directory.  
- **upstreams**: List of upstream URLs for distributed verification.  
- **secrets_backend**: Method for secrets management (default: encrypted store).

Adjust these to match your environment. Point the systemd service or release script to load the `sys.config` file via `-config /etc/damagebdd/sys.config`.

---

## Security

See [SECURITY.txt](SECURITY.txt) for important operator guidelines.
