damage BDD
==========

An Erlang OTP application to run bdd load tests at scale.
Inspired by [https://github.com/behave/behave](behave).

Configure
---------

1. Edit `configs/damage.config` runner config.

   ```
    %%-*-erlang-*- 
    {url, "http://localhost:8000"}.
    {extension, "feature"}.
    {context_yaml, "config/behave.yaml"}.
    {deployment, local}.
    {stop, true}.
    {feature_dir, "features"}.
   ```

2. Edit `behave.yaml` for context data.
   ```
   deployments:
     local:
       variable1: value1
     remote:
       variable1: value1
   ```
3. Create features in `feature_dir` [default: ./features]

Run
-----

    $ rebar3 shell
    > damage:execute('test')

Implementation Roadmap
----------------------
- capture metrics eg:
    - response timing
    - calls, percentile, fails
- auditing of the results, authenticity, validity
    - tracking history
    - sharing result
    - explaining results
- documentation, unittests
- dynamic concurrency tuning 
- junit report output
- generate readable bdd output
- generate failure report


HTTP Steps
---------

Make a simple http GET request and verify results.
```
When I make a GET request to "/v3/debug"
Then the response status must be "200"
Then the json at path "$.status" must be "ok"
```

Make a simple http POST request with post data in body.

```
I make a POST request to {path}
{
   "data1": "value1", 
   "data2": "value2"
}
Then the response status must be "202"
```
