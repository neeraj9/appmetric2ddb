# Application Metric Publisher to DalmatinerDB

An application metric publisher to DalmatinerDB.

This software shall automatically poll applications like
rabbitmq, riakts and push the metrics to DalmatinerDB
for monitoring.

There is one actor per bucket, which will observe it for
changes.

> [ddb_proxy](https://github.com/dalmatinerdb/ddb_proxy) is used
> as the bootstrap for this project.

Build
-----

```bash
$ rebar3 compile
```

Release
-------

```bash
$ rebar3 release
```

Todo
----

1. RiakTS support
2. RabbitMQ support
