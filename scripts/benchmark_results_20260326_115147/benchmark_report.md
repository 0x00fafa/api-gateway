# API Gateway Performance Benchmark Report

**Generated:** Thu Mar 26 11:53:18 AM UTC 2026

**Gateway URL:** https://api.0x00fafa.com

---

## Test Environment

- **Tool:** wrk
- **Duration:** 30s
- **Warmup:** 5s
- **Connections:** 100
- **Threads:** 4

---

## Test: zerion_cached

```
Running 30s test @ https://api.0x00fafa.com/zerion/v1/wallets/0x831b3291917C51bbAca867f178742ccc87d17227/portfolio
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    80.38ms   27.63ms 600.43ms   90.05%
    Req/Sec   315.96     62.48   444.00     70.85%
  37414 requests in 30.09s, 23.88MB read
  Non-2xx or 3xx responses: 37383
Requests/sec:   1243.40
Transfer/sec:    812.65KB
```

## Test: zerion_proxy

```
Running 30s test @ https://api.0x00fafa.com/zerion/v1/wallets/0x831b3291917C51bbAca867f178742ccc87d17227/portfolio
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    99.83ms   41.72ms   1.19s    88.24%
    Req/Sec   257.85     69.64   420.00     65.82%
  30406 requests in 30.10s, 19.41MB read
  Non-2xx or 3xx responses: 30376
Requests/sec:   1010.26
Transfer/sec:    660.34KB
```

## Test: health

```
Running 30s test @ https://api.0x00fafa.com/health
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    13.80ms    8.79ms 263.17ms   93.90%
    Req/Sec     1.90k   371.64     3.53k    75.69%
  225049 requests in 30.09s, 52.56MB read
Requests/sec:   7480.33
Transfer/sec:      1.75MB
```

---

## Summary

See individual test files for detailed results.
