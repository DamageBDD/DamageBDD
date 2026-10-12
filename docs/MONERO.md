# DamageBDD Monero payment step module

This package adds a local Monero payment adapter to DamageBDD:

- `apps/damage/src/monero.erl` — `monero-wallet-rpc` JSON-RPC client
- `apps/damage/src/steps_monero.erl` — Gherkin step definitions
- `apps/damage/test/monero_tests.erl` — pure EUnit tests
- `features/monero/monero_payment.feature` — example scenarios
- `config/sys.config.monero.fragment.config` — configuration fragment

## Architecture

`monerod` owns and validates the blockchain. It does not know which outputs belong
to your wallet. `monero-wallet-rpc` holds the wallet logic and scans your local
`monerod`. DamageBDD talks only to `monero-wallet-rpc` at `127.0.0.1:18083`.
Port `18083` is deliberately used so it does not collide with `monerod`'s
mainnet ZMQ RPC default on `18082` (`38082` on stagenet).

Each invoice gets a fresh subaddress. Payment status is checked with
`get_transfers`, filtered by that subaddress, and evaluated entirely in atomic
units. XMR amounts must be supplied as quoted decimal strings or binaries; the
module rejects floating-point amounts rather than silently rounding them. A transfer contributes to the observed amount only when it has a positive amount,
`unlock_time = 0`, and does not report `double_spend_seen = true`. The invoice is
marked paid only when enough of that value is confirmed to the requested threshold
and is not marked `locked` by the wallet.

## 1. Install into DamageBDD

From the DamageBDD repository root:

```bash
cp apps/damage/src/monero.erl /path/to/DamageBDD/apps/damage/src/
cp apps/damage/src/steps_monero.erl /path/to/DamageBDD/apps/damage/src/
cp apps/damage/test/monero_tests.erl /path/to/DamageBDD/apps/damage/test/
mkdir -p /path/to/DamageBDD/features/monero
cp features/monero/monero_payment.feature /path/to/DamageBDD/features/monero/
```

No central step registry change is required. DamageBDD discovers compiled modules
whose names match `steps_*.beam`.

Merge the values from `config/sys.config.monero.fragment.config` into the existing
`{damage, [...]}` section of your active sys.config.

## 2. Start a local Monero node

Mainnet example:

```bash
monerod \
  --data-dir /var/lib/monero \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port 18081
```

Wait until the daemon is fully synchronized before testing payments.

For development, use stagenet instead:

```bash
monerod \
  --stagenet \
  --data-dir /var/lib/monero-stagenet \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port 38081
```

## 3. Start `monero-wallet-rpc`

Create the wallet first with `monero-wallet-cli`, then create a password file
readable only by the wallet service account. Replace `monero:monero` below when
your service uses a different account:

```bash
install -d -m 700 /var/lib/monero /var/lib/monero-stagenet /var/log/monero
install -m 600 /dev/null /var/lib/monero/damage-wallet.password
install -m 600 /dev/null /var/lib/monero-stagenet/damage-wallet.password
printf '%s\n' 'YOUR-WALLET-PASSWORD' > /var/lib/monero/damage-wallet.password
printf '%s\n' 'YOUR-STAGENET-WALLET-PASSWORD' > /var/lib/monero-stagenet/damage-wallet.password
chown -R monero:monero /var/lib/monero /var/lib/monero-stagenet /var/log/monero
```

Mainnet:

```bash
monero-wallet-rpc \
  --wallet-file /var/lib/monero/damage-wallet \
  --password-file /var/lib/monero/damage-wallet.password \
  --daemon-address http://127.0.0.1:18081 \
  --trusted-daemon \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port 18083 \
  --disable-rpc-login \
  --log-file /var/log/monero/damage-wallet-rpc.log
```

Stagenet:

```bash
monero-wallet-rpc \
  --stagenet \
  --wallet-file /var/lib/monero-stagenet/damage-wallet \
  --password-file /var/lib/monero-stagenet/damage-wallet.password \
  --daemon-address http://127.0.0.1:38081 \
  --trusted-daemon \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port 38083 \
  --disable-rpc-login \
  --log-file /var/log/monero/damage-wallet-rpc-stagenet.log
```

Change `monero_wallet_rpc_port` to `38083` in DamageBDD for stagenet.

### Security boundary

This version intentionally uses unauthenticated HTTP only on loopback because
Monero RPC login uses HTTP Digest rather than Bitcoin Core's Basic authentication.
The client refuses a non-loopback host by default.

Do not bind this wallet RPC to `0.0.0.0`. Run `monero-wallet-rpc` and DamageBDD
under controlled service accounts. Any process that can reach an unrestricted
wallet RPC can inspect the wallet and, when spending is permitted, initiate a
transaction.

For production payment detection without refunds/payouts, use a view-only wallet.
The `transfer` Gherkin step remains disabled unless `{monero_allow_spend, true}`
is set.

## 4. Compile and test

```bash
cd /path/to/DamageBDD
rebar3 format
rebar3 eunit --module=monero_tests
rebar3 compile
```

The existing compile hook checks that step modules do not contain a catch-all
`step/6` clause. `steps_monero.erl` uses only exact token patterns.

## 5. Run the example feature

For a purely local developer run that does not inject a DamageBDD admin identity,
set this only in the developer sys.config:

```erlang
{monero_steps_require_admin, false}
```

Then run the feature with your normal DamageBDD feature runner. The module exposes
these steps:

```gherkin
Given the local Monero wallet RPC is available
Given I create a Monero invoice for "0.001" XMR in "invoice"
When I refresh the local Monero wallet
Then the Monero invoice in "invoice" should not be paid
Then the Monero invoice in "invoice" should be paid with "10" confirmations
Then I wait for the Monero invoice in "invoice" to be paid with "10" confirmations for up to "3600" seconds
Then I store the Monero wallet balance in "balance"
When I send "0.001" XMR to "{{destination}}" and store the transaction in "tx"
```

The invoice map contains:

```erlang
#{
  address => <<"...">>,
  account_index => 0,
  subaddress_index => 17,
  amount_atomic => 1000000000,
  amount_xmr => <<"0.001">>,
  label => <<"damagebdd:invoice">>,
  created_at => 1785970000
}
```

The corresponding status is stored as `invoice_status` and includes `paid`,
`payment_state`, exact received/confirmed amounts, effective invoice confirmations,
and transaction summaries. The effective confirmation count is calculated from only
the confirmed value needed to cover the invoice, so a later low-confirmation
overpayment does not reduce the reported depth. Pool or otherwise locked transfers may contribute to `received_atomic`
so they can be reported as seen, but they never contribute to `confirmed_atomic`
or `paid`. The bounded wait step polls at `monero_poll_interval_ms` (10 seconds by
default) and fails with the last observed status when its timeout expires.
