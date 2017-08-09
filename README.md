# Application Metric Publisher to DalmatinerDB

An application metric publisher to DalmatinerDB.

This software shall automatically poll applications like
rabbitmq, riakts and push the metrics to DalmatinerDB
for monitoring.

There is one actor per bucket, which will observe it for
changes.

> [ddb_proxy](https://github.com/dalmatinerdb/ddb_proxy) is used
> as the bootstrap for this project.

Debian Package Build
--------------------

Note that building a debian package is as simple as a makefile target,
as shown below.

```bash
$ sudo make deb-pacakge
```

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

Supported Applications
----------------------

1. RabbitMQ
2. Riak

Sample Configurations
---------------------

Base Config
~~~~~~~~~~~

    run_user_home = /data/appmetric2ddb
    ddb.enabled = on
    ddb.endpoint = 127.0.0.1:5555
    nodename = appmetric2ddb@127.0.0.1
    distributed_cookie = appmetric2ddb_cookie
    erlang.async_threads = 30
    log.console = file
    log.console.level = info
    log.console.file = /data/appmetric2ddb/log/console.log
    log.error.file = /data/appmetric2ddb/log/error.log
    log.debug.file = /data/appmetric2ddb/log/debug.log
    log.syslog = off
    log.crash.file = /data/appmetric2ddb/log/crash.log
    log.crash.msg_size = 64KB
    log.crash.size = 10MB
    log.crash.date = $D0
    log.crash.count = 5
    log.error.redirect = on
    log.error.messages_per_second = 100

RabbitMQ Part
~~~~~~~~~~~~~

    ddb.rabbitmq.1.name = ddbrabbitmq1_worker
    ddb.rabbitmq.1.bucket = bucketname
    ddb.rabbitmq.1.interval = 10000
    ddb.rabbitmq.1.rmq_endpoint = 127.0.0.1:15672
    ddb.rabbitmq.1.rmq_user = guest
    ddb.rabbitmq.1.rmq_password = guest

Riak Part
~~~~~~~~~

    ddb.riak.1.name = riak1_worker
    ddb.riak.1.interval = 10000
    ddb.riak.1.riak_endpoint = 127.0.0.1:8098

