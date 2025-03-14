%https://prometheus.io/docs/prometheus/latest/querying/api/
-module(damage_analytics).

-export([trails/0]).

trails() -> [{"/analytics/[:action]", damage_analytics, #{}}].
