# Exercise 14 — Distributed Tracing Investigation

## Incident

Users complain the checkout API is slow.

```
Grafana:      95th percentile latency = 4.8 seconds
Prometheus:   request count normal
Tempo trace:  checkout-service -> inventory-service -> payment-service
              payment-service = 4.2s
```

## Task

Use metrics, logs, and traces together to find the bottleneck.

---

## Request waterfall

```
checkout-service span — total 4.8s
  checkout logic        ~0.4s
  inventory-service      ~0.2s
  payment-service         4.2s  <- bottleneck, 87.5% of total latency
```

The trace already narrows the problem down to one service before any further digging.

---

## Step 1 — Rule out load and resource issues with Prometheus

Request count being normal means this is not a traffic spike problem. Confirm with a query:

```promql
sum(rate(http_requests_total{service="payment-service"}[5m]))
```

Expected: same as the historical baseline, no anomaly.

This rules out an autoscaling or capacity issue. If request count were spiking alongside latency, that would point to resource exhaustion. Since it is flat, the slowness is inside individual requests, not request volume.

Check CPU and memory too, to rule out resource starvation:

```promql
sum(rate(container_cpu_usage_seconds_total{pod=~"payment-service.*"}[5m])) by (pod)
sum(container_memory_working_set_bytes{pod=~"payment-service.*"}) by (pod)
```

If CPU and memory are also normal, the bottleneck is not resource starvation either. It is something inside the request logic itself.

---

## Step 2 — Drill into the trace (Tempo)

In Grafana, go to Explore, select Tempo, open the slow trace, and expand the payment-service span.

A 4.2 second span inside one service is almost always one of these:

```
Database query            - slow SQL, missing index, lock contention
External API call         - third-party dependency timeout or slowness
Synchronous retry loop     - code retrying a failing call repeatedly
Lock or mutex wait         - thread blocked waiting for a resource
```

Example of what a useful trace breakdown looks like once child spans are visible:

```
payment-service span         total: 4.2s
  validate-request             0.05s
  db.query "SELECT ..."        0.1s
  external-call "stripe"       3.9s   <- the real bottleneck
  write-response                0.05s
```

This tells you the bottleneck is not payment-service's own code. It is a downstream dependency it calls, in this example a third-party payment gateway.

---

## Step 3 — Correlate with logs (Loki)

Once the slow operation is identified from the trace, search logs from that exact time window:

```logql
{namespace="default", pod=~"payment-service.*"} |= "stripe" | json
```

Look for timeout or retry patterns:

```
level=warn msg="external call to stripe taking longer than expected" duration=3.8s
level=warn msg="retrying payment gateway call" attempt=2
```

Repeated retries in the logs confirm the mechanism: the code is retrying a slow or failing downstream call, multiplying the delay on top of the original slowness.

---

## Step 4 — Check the downstream dependency's own health

If the downstream service has its own metrics, check those directly to see if the root cause is actually one level further down the chain:

```promql
sum(rate(http_request_duration_seconds_sum{service="stripe-gateway"}[5m]))
/
sum(rate(http_request_duration_seconds_count{service="stripe-gateway"}[5m]))
```

If the downstream dependency itself shows elevated latency, the root cause is not payment-service at all, it is whatever payment-service depends on.

---

## Full investigation summary

```
Metrics (Prometheus)   -> request count normal, CPU and memory normal
                           rules out load spike and resource starvation

Trace (Tempo)           -> 4.2s of 4.8s total spent in payment-service
                           narrows the bottleneck to ONE specific service

Trace child spans        -> 3.9s of that 4.2s spent in one specific operation
                           narrows further to ONE specific call, e.g. external API

Logs (Loki)             -> confirms retries or timeouts on that exact call
                           confirms the mechanism of the slowdown
```

This is the textbook reason all three observability pillars matter together. Metrics tell you something is wrong and rule out broad causes like traffic or capacity. Traces tell you exactly where in the call chain the time is going. Logs tell you why, with the actual error or retry detail.

---

## Fix options depending on what is found

```
If downstream API is genuinely slow:
  - add a timeout and circuit breaker so payment-service fails fast instead of hanging
  - cache or queue non-critical calls instead of blocking the request

If it is a missing DB index:
  - add the index, verify with EXPLAIN ANALYZE

If it is a retry storm:
  - add exponential backoff with a max retry cap
  - add a circuit breaker (resilience4j, Polly, etc) to stop hammering a failing dependency
```

---

## Key concepts to explain in interview

| Signal | What it tells you |
|---|---|
| Request count flat in Prometheus | Not a traffic spike |
| CPU/memory flat in Prometheus | Not resource starvation |
| One service consumes most of total trace time | Bottleneck is isolated to that service |
| One child span consumes most of that service's time | Bottleneck is isolated to one specific operation |
| Logs show retries/timeouts at that point | Confirms the mechanism, not just the location |

### Why "request count normal" matters as a first check

It is tempting to jump straight into the trace, but checking request count first is what tells you this is a per-request problem rather than a scaling problem. If request count had spiked with latency, the fix would be entirely different, more replicas, better autoscaling thresholds, rather than digging into a single service's code path.

### Why the trace alone is not the full answer

Knowing payment-service takes 4.2 seconds tells you where, not why. The child spans inside that one span are what actually explain the cause, whether it is a slow query, an external call, or a retry loop. Logs from that exact window then confirm the behavior pattern, like repeated retry attempts, that the trace duration alone cannot show.

---

## Interview answer (say this)

> "I would start with Prometheus to rule out the obvious. Request count was normal, so this is not a traffic spike, and I would also check CPU and memory on payment-service to rule out resource starvation. Since both were normal, the slowness has to be inside individual request logic, not capacity. The Tempo trace already narrows it down significantly: 4.2 of the 4.8 second total is spent inside payment-service specifically, so checkout-service and inventory-service are not the problem. From there I would expand the payment-service span to look at its child spans, which is usually where the real answer is, whether it is a slow database query, lock contention, or in this case most likely a slow external call like a payment gateway. I would then correlate that exact time window in Loki to look for timeout or retry log messages, which would confirm whether the service is retrying a failing downstream call repeatedly, multiplying the delay. The fix depends on what is found, usually adding a timeout and circuit breaker around the slow external dependency so the request fails fast instead of blocking for several seconds, rather than trying to optimize payment-service's own code, which is not actually the bottleneck."