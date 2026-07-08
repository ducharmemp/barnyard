```
>> building barnyard (release)…
>> warming direct (2s)…
   direct    simple    c1   tps=25265        lat=0.040 ms
   direct    simple    c8   tps=81876        lat=0.098 ms
   direct    simple    c16  tps=95963        lat=0.167 ms
   direct    simple    c32  tps=127001       lat=0.252 ms
   direct    simple    c64  tps=129987       lat=0.492 ms
   direct    extended  c1   tps=22720        lat=0.044 ms
   direct    extended  c8   tps=84111        lat=0.095 ms
   direct    extended  c16  tps=91326        lat=0.175 ms
   direct    extended  c32  tps=110099       lat=0.291 ms
   direct    extended  c64  tps=112041       lat=0.571 ms
>> starting barnyard on 7669 (pool 64, --ponymaxthreads=2)…
>> warming barnyard@2 (2s)…
   barnyard@2 simple    c1   tps=11730        lat=0.085 ms
   barnyard@2 simple    c8   tps=40705        lat=0.197 ms
   barnyard@2 simple    c16  tps=40734        lat=0.393 ms
   barnyard@2 simple    c32  tps=39574        lat=0.809 ms
   barnyard@2 simple    c64  tps=35277        lat=1.814 ms
   barnyard@2 extended  c1   tps=10841        lat=0.092 ms
   barnyard@2 extended  c8   tps=35402        lat=0.226 ms
   barnyard@2 extended  c16  tps=35254        lat=0.454 ms
   barnyard@2 extended  c32  tps=33923        lat=0.943 ms
   barnyard@2 extended  c64  tps=31112        lat=2.057 ms
>> starting barnyard on 7669 (pool 64, --ponymaxthreads=4)…
>> warming barnyard@4 (2s)…
   barnyard@4 simple    c1   tps=11339        lat=0.088 ms
   barnyard@4 simple    c8   tps=38857        lat=0.206 ms
   barnyard@4 simple    c16  tps=42892        lat=0.373 ms
   barnyard@4 simple    c32  tps=48015        lat=0.666 ms
   barnyard@4 simple    c64  tps=48231        lat=1.327 ms
   barnyard@4 extended  c1   tps=9952         lat=0.100 ms
   barnyard@4 extended  c8   tps=36762        lat=0.218 ms
   barnyard@4 extended  c16  tps=39160        lat=0.409 ms
   barnyard@4 extended  c32  tps=43029        lat=0.744 ms
   barnyard@4 extended  c64  tps=42543        lat=1.504 ms
>> starting barnyard on 7669 (pool 64, --ponymaxthreads=8)…
>> warming barnyard@8 (2s)…
   barnyard@8 simple    c1   tps=10249        lat=0.098 ms
   barnyard@8 simple    c8   tps=20771        lat=0.385 ms
   barnyard@8 simple    c16  tps=29048        lat=0.551 ms
   barnyard@8 simple    c32  tps=39740        lat=0.805 ms
   barnyard@8 simple    c64  tps=46247        lat=1.384 ms
   barnyard@8 extended  c1   tps=8918         lat=0.112 ms
   barnyard@8 extended  c8   tps=18474        lat=0.433 ms
   barnyard@8 extended  c16  tps=26063        lat=0.614 ms
   barnyard@8 extended  c32  tps=35399        lat=0.904 ms
   barnyard@8 extended  c64  tps=41236        lat=1.552 ms
>> starting pgbouncer on 6432…
>> warming pgbouncer (2s)…
   pgbouncer simple    c1   tps=17242        lat=0.058 ms
   pgbouncer simple    c8   tps=60995        lat=0.131 ms
   pgbouncer simple    c16  tps=66733        lat=0.240 ms
   pgbouncer simple    c32  tps=65646        lat=0.487 ms
   pgbouncer simple    c64  tps=61431        lat=1.042 ms
   pgbouncer extended  c1   tps=17014        lat=0.059 ms
   pgbouncer extended  c8   tps=58422        lat=0.137 ms
   pgbouncer extended  c16  tps=63481        lat=0.252 ms
   pgbouncer extended  c32  tps=62676        lat=0.511 ms
   pgbouncer extended  c64  tps=59387        lat=1.078 ms
>> starting pgcat on 6433…
>> warming pgcat (2s)…
   pgcat     simple    c1   tps=11554        lat=0.087 ms
   pgcat     simple    c8   tps=54915        lat=0.146 ms
   pgcat     simple    c16  tps=60381        lat=0.265 ms
   pgcat     simple    c32  tps=70969        lat=0.451 ms
   pgcat     simple    c64  tps=71628        lat=0.894 ms
   pgcat     extended  c1   tps=10392        lat=0.096 ms
   pgcat     extended  c8   tps=46419        lat=0.172 ms
   pgcat     extended  c16  tps=51939        lat=0.308 ms
   pgcat     extended  c32  tps=60500        lat=0.529 ms
   pgcat     extended  c64  tps=64708        lat=0.989 ms

=== THROUGHPUT  (read-only SELECT, pool=64, 8s/run) ===
mode      conc         direct   barnyard@2   barnyard@4   barnyard@8    pgbouncer        pgcat   tps
simple    c1            25265        11730        11339        10249        17242        11554
simple    c8            81876        40705        38857        20771        60995        54915
simple    c16           95963        40734        42892        29048        66733        60381
simple    c32          127001        39574        48015        39740        65646        70969
simple    c64          129987        35277        48231        46247        61431        71628
extended  c1            22720        10841         9952         8918        17014        10392
extended  c8            84111        35402        36762        18474        58422        46419
extended  c16           91326        35254        39160        26063        63481        51939
extended  c32          110099        33923        43029        35399        62676        60500
extended  c64          112041        31112        42543        41236        59387        64708

=== LATENCY  (read-only SELECT, pool=64, 8s/run) ===
mode      conc         direct   barnyard@2   barnyard@4   barnyard@8    pgbouncer        pgcat   avg ms
simple    c1            0.040        0.085        0.088        0.098        0.058        0.087
simple    c8            0.098        0.197        0.206        0.385        0.131        0.146
simple    c16           0.167        0.393        0.373        0.551        0.240        0.265
simple    c32           0.252        0.809        0.666        0.805        0.487        0.451
simple    c64           0.492        1.814        1.327        1.384        1.042        0.894
extended  c1            0.044        0.092        0.100        0.112        0.059        0.096
extended  c8            0.095        0.226        0.218        0.433        0.137        0.172
extended  c16           0.175        0.454        0.409        0.614        0.252        0.308
extended  c32           0.291        0.943        0.744        0.904        0.511        0.529
extended  c64           0.571        2.057        1.504        1.552        1.078        0.989
```
