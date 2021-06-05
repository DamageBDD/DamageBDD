damage BDD
==========

An Erlang OTP application to run bdd load tests at scale.

Configure
---------

Edit `configs/damage.config` runner config.
Edit `behave.yaml` for context data.


Build
-----

    $ rebar3 shell
    > damage:execute('test')
