import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any

from prometheus_client import Gauge


logger = logging.getLogger("net_observer")
logger.setLevel(logging.INFO)


@dataclass
class TargetSpec:
    address: str
    class_name: str
    location: str
    provider: str


@dataclass
class RouteHistory:
    last_route: list[str] = field(default_factory=list)
    route_change_count: int = 0


@dataclass
class ProbeResult:
    target: TargetSpec
    success: bool
    duration_seconds: float
    collected_at_unix: int
    report: dict[str, Any] | None


INFO = Gauge(
    "net_observer_instance_info",
    "Static info about this net observer instance",
    ["provider", "region", "instance"],
)

EXPORTER_UP = Gauge("net_observer_up", "Exporter process health")
TARGETS_TOTAL = Gauge("net_observer_targets_total", "Number of configured targets")
CYCLE_DURATION = Gauge(
    "net_observer_cycle_duration_seconds",
    "Collection cycle duration",
)
FAILED_TARGETS = Gauge(
    "net_observer_failed_targets",
    "Number of targets that failed in the last cycle",
)

BASE_LABELS = ["dst", "target_class", "target_location", "target_provider"]
HOP_LABELS = BASE_LABELS + ["hop", "hop_ip", "is_final"]
SUSPECT_LABELS = BASE_LABELS + ["suspect_hop", "suspect_ip"]

PROBE_SUCCESS = Gauge("net_probe_success", "Probe success status", BASE_LABELS)
PROBE_DURATION = Gauge("net_probe_duration_seconds", "Probe duration in seconds", BASE_LABELS)
PROBE_TIMESTAMP = Gauge("net_probe_timestamp_seconds", "Probe timestamp", BASE_LABELS)

TARGET_REACHABLE = Gauge("net_target_reachable", "Target reachability", BASE_LABELS)
TARGET_LATENCY = Gauge("net_target_latency", "Final hop average latency", BASE_LABELS)
TARGET_LOSS = Gauge("net_target_loss", "Final hop packet loss percent", BASE_LABELS)
TARGET_STDEV = Gauge("net_target_stdev", "Final hop latency stdev", BASE_LABELS)
TARGET_HOPS = Gauge("net_target_hops", "Hop count to target", BASE_LABELS)
TARGET_ROUTE_CHANGED = Gauge("net_target_route_changed", "Whether route changed this cycle", BASE_LABELS)
TARGET_ROUTE_CHANGE_COUNT = Gauge(
    "net_target_route_change_count",
    "Number of observed route changes",
    BASE_LABELS,
)
TARGET_FINAL_HOP_MATCHES_DST = Gauge(
    "net_target_final_hop_matches_dst",
    "Whether the final hop IP matches the target address",
    BASE_LABELS,
)

TARGET_LOSS_SUSPECT = Gauge(
    "net_target_loss_suspect",
    "Packet loss suspect hop",
    SUSPECT_LABELS,
)
TARGET_LATENCY_JUMP_SUSPECT = Gauge(
    "net_target_latency_jump_suspect",
    "Latency jump suspect hop",
    SUSPECT_LABELS,
)
TARGET_LATENCY_JUMP_MS = Gauge(
    "net_target_latency_jump_ms",
    "Latency jump size in ms",
    SUSPECT_LABELS,
)

HOP_LOSS = Gauge("net_loss", "Packet loss per hop", HOP_LABELS)
HOP_LATENCY = Gauge("net_latency", "Average latency per hop", HOP_LABELS)
HOP_STDEV = Gauge("net_stdev", "Latency stdev per hop", HOP_LABELS)
HOP_BEST = Gauge("net_hop_best", "Best latency per hop", HOP_LABELS)
HOP_WORST = Gauge("net_hop_worst", "Worst latency per hop", HOP_LABELS)
HOP_LAST = Gauge("net_hop_last", "Last latency per hop", HOP_LABELS)
HOP_SENT = Gauge("net_hop_sent", "Packets sent per hop", HOP_LABELS)
HOP_LATENCY_DELTA = Gauge("net_hop_latency_delta", "Latency delta vs previous hop", HOP_LABELS)
HOP_RESPONDING = Gauge("net_hop_responding", "Whether hop is responding", HOP_LABELS)

DYNAMIC_GAUGES = [
    PROBE_SUCCESS,
    PROBE_DURATION,
    PROBE_TIMESTAMP,
    TARGET_REACHABLE,
    TARGET_LATENCY,
    TARGET_LOSS,
    TARGET_STDEV,
    TARGET_HOPS,
    TARGET_ROUTE_CHANGED,
    TARGET_ROUTE_CHANGE_COUNT,
    TARGET_FINAL_HOP_MATCHES_DST,
    TARGET_LOSS_SUSPECT,
    TARGET_LATENCY_JUMP_SUSPECT,
    TARGET_LATENCY_JUMP_MS,
    HOP_LOSS,
    HOP_LATENCY,
    HOP_STDEV,
    HOP_BEST,
    HOP_WORST,
    HOP_LAST,
    HOP_SENT,
    HOP_LATENCY_DELTA,
    HOP_RESPONDING,
]


def unix_now() -> int:
    return int(time.time())


def get_num(obj: dict[str, Any], key: str) -> float | None:
    value = obj.get(key)
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def clear_dynamic_metrics() -> None:
    for gauge in DYNAMIC_GAUGES:
        gauge.clear()


def load_targets(net_cfg: dict[str, Any]) -> list[TargetSpec]:
    raw_targets = net_cfg.get("targets", [])
    if not isinstance(raw_targets, list):
        raise RuntimeError("config.toml: 'net_observer.targets' must be an array of tables")

    targets: list[TargetSpec] = []
    seen: set[str] = set()

    for item in raw_targets:
        if not isinstance(item, dict):
            continue

        address = str(item.get("address", "")).strip()
        if not address or address in seen:
            continue

        seen.add(address)
        targets.append(
            TargetSpec(
                address=address,
                class_name=str(item.get("class_name", "unknown")).strip() or "unknown",
                location=str(item.get("location", "unknown")).strip() or "unknown",
                provider=str(item.get("provider", "unknown")).strip() or "unknown",
            )
        )

    if not targets:
        raise RuntimeError("No targets found in config.toml under [[net_observer.targets]]")

    return targets


def first_loss_suspect(hubs: list[dict[str, Any]]) -> tuple[int, str] | None:
    for idx, hop in enumerate(hubs):
        if idx + 1 == len(hubs):
            break

        loss = get_num(hop, "Loss%") or 0.0
        host = str(hop.get("host", "?"))

        if host != "?" and loss > 0.0:
            hop_num = int(hop.get("count", idx + 1))
            return hop_num, host

    return None


def biggest_latency_jump(hubs: list[dict[str, Any]]) -> tuple[int, str, float] | None:
    best: tuple[int, str, float] | None = None
    prev_avg: float | None = None

    for idx, hop in enumerate(hubs):
        avg = get_num(hop, "Avg")
        if avg is None:
            return None

        host = str(hop.get("host", "?"))

        if prev_avg is not None:
            delta = avg - prev_avg
            if delta > 0.0 and host != "?":
                hop_num = int(hop.get("count", idx + 1))
                if best is None or delta > best[2]:
                    best = (hop_num, host, delta)

        prev_avg = avg

    return best


async def run_mtr_probe(
    target: TargetSpec,
    count: int,
    max_hops: int,
    timeout_seconds: int,
    collected_at_unix: int,
) -> ProbeResult:
    started = time.perf_counter()

    try:
        process = await asyncio.create_subprocess_exec(
            "mtr",
            "--json",
            "-n",
            "-c",
            str(count),
            "-m",
            str(max_hops),
            target.address,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, _stderr = await asyncio.wait_for(
            process.communicate(),
            timeout=timeout_seconds,
        )

        if process.returncode == 0:
            try:
                report = json.loads(stdout.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                report = None

            return ProbeResult(
                target=target,
                success=report is not None,
                duration_seconds=time.perf_counter() - started,
                collected_at_unix=collected_at_unix,
                report=report,
            )
    except Exception as e:
        logger.error(f"Probe failed for {target.address}: {e}")

    return ProbeResult(
        target=target,
        success=False,
        duration_seconds=time.perf_counter() - started,
        collected_at_unix=collected_at_unix,
        report=None,
    )


def base_labels(target: TargetSpec) -> dict[str, str]:
    return {
        "dst": target.address,
        "target_class": target.class_name,
        "target_location": target.location,
        "target_provider": target.provider,
    }


async def metric_updater(net_cfg: dict[str, Any]):
    provider = str(net_cfg.get("provider", "unknown"))
    region = str(net_cfg.get("region", "unknown"))
    instance = str(net_cfg.get("instance", "unknown"))

    interval_seconds = int(net_cfg.get("interval_seconds", 30))
    mtr_count = int(net_cfg.get("mtr_count", 5))
    mtr_max_hops = int(net_cfg.get("mtr_max_hops", 30))
    mtr_timeout_seconds = int(net_cfg.get("mtr_timeout_seconds", 15))

    targets = load_targets(net_cfg)
    history: dict[str, RouteHistory] = {}

    logger.info(
        f"Starting net_observer collector with {len(targets)} targets | "
        f"provider={provider} region={region} instance={instance}"
    )

    while True:
        cycle_started = time.perf_counter()
        now_unix = unix_now()

        INFO.labels(
            provider=provider,
            region=region,
            instance=instance,
        ).set(1)

        EXPORTER_UP.set(1)
        TARGETS_TOTAL.set(len(targets))

        tasks = [
            run_mtr_probe(
                target=target,
                count=mtr_count,
                max_hops=mtr_max_hops,
                timeout_seconds=mtr_timeout_seconds,
                collected_at_unix=now_unix,
            )
            for target in targets
        ]

        results = await asyncio.gather(*tasks)
        cycle_duration = time.perf_counter() - cycle_started
        failed_targets = sum(1 for result in results if not result.success)

        CYCLE_DURATION.set(cycle_duration)
        FAILED_TARGETS.set(failed_targets)

        clear_dynamic_metrics()

        for result in results:
            target = result.target
            labels = base_labels(target)

            PROBE_SUCCESS.labels(**labels).set(1 if result.success else 0)
            PROBE_DURATION.labels(**labels).set(result.duration_seconds)
            PROBE_TIMESTAMP.labels(**labels).set(result.collected_at_unix)

            if not result.success or not isinstance(result.report, dict):
                TARGET_REACHABLE.labels(**labels).set(0)
                TARGET_ROUTE_CHANGED.labels(**labels).set(0)
                continue

            hubs = result.report.get("report", {}).get("hubs", [])
            if not isinstance(hubs, list) or not hubs:
                TARGET_REACHABLE.labels(**labels).set(0)
                TARGET_ROUTE_CHANGED.labels(**labels).set(0)
                continue

            route_ips: list[str] = []
            last_avg = 0.0

            hop_count = len(hubs)
            final_hop = hubs[-1]

            final_hop_ip = str(final_hop.get("host", "?"))
            final_loss = get_num(final_hop, "Loss%") or 100.0
            final_avg = get_num(final_hop, "Avg") or 0.0
            final_stdev = get_num(final_hop, "StDev") or 0.0

            final_reachable = 1 if final_loss < 100.0 else 0
            final_matches_dst = 1 if final_hop_ip == target.address else 0

            for idx, hop in enumerate(hubs):
                hop_num = int(hop.get("count", idx + 1))
                hop_ip = str(hop.get("host", "?"))

                loss = get_num(hop, "Loss%") or 100.0
                avg = get_num(hop, "Avg") or 0.0
                stdev = get_num(hop, "StDev") or 0.0
                best = get_num(hop, "Best") or 0.0
                wrst = get_num(hop, "Wrst") or 0.0
                last = get_num(hop, "Last") or 0.0
                sent = get_num(hop, "Snt") or 0.0

                responding = 1 if hop_ip != "?" and loss < 100.0 else 0
                is_final = "1" if idx + 1 == hop_count else "0"
                latency_delta = 0.0 if idx == 0 else avg - last_avg

                if hop_ip != "?":
                    route_ips.append(hop_ip)

                hop_labels = {
                    **labels,
                    "hop": str(hop_num),
                    "hop_ip": hop_ip,
                    "is_final": is_final,
                }

                HOP_LOSS.labels(**hop_labels).set(loss)
                HOP_LATENCY.labels(**hop_labels).set(avg)
                HOP_STDEV.labels(**hop_labels).set(stdev)
                HOP_BEST.labels(**hop_labels).set(best)
                HOP_WORST.labels(**hop_labels).set(wrst)
                HOP_LAST.labels(**hop_labels).set(last)
                HOP_SENT.labels(**hop_labels).set(sent)
                HOP_LATENCY_DELTA.labels(**hop_labels).set(latency_delta)
                HOP_RESPONDING.labels(**hop_labels).set(responding)

                last_avg = avg

            entry = history.setdefault(target.address, RouteHistory())

            if not entry.last_route:
                route_changed = 0
            elif entry.last_route != route_ips:
                entry.route_change_count += 1
                route_changed = 1
            else:
                route_changed = 0

            entry.last_route = route_ips

            TARGET_LATENCY.labels(**labels).set(final_avg)
            TARGET_LOSS.labels(**labels).set(final_loss)
            TARGET_STDEV.labels(**labels).set(final_stdev)
            TARGET_REACHABLE.labels(**labels).set(final_reachable)
            TARGET_HOPS.labels(**labels).set(hop_count)
            TARGET_ROUTE_CHANGED.labels(**labels).set(route_changed)
            TARGET_ROUTE_CHANGE_COUNT.labels(**labels).set(entry.route_change_count)
            TARGET_FINAL_HOP_MATCHES_DST.labels(**labels).set(final_matches_dst)

            if final_loss > 0.0:
                suspect = first_loss_suspect(hubs)
                if suspect is not None:
                    suspect_hop, suspect_ip = suspect
                    suspect_labels = {
                        **labels,
                        "suspect_hop": str(suspect_hop),
                        "suspect_ip": suspect_ip,
                    }
                    TARGET_LOSS_SUSPECT.labels(**suspect_labels).set(1)

            jump = biggest_latency_jump(hubs)
            if jump is not None:
                suspect_hop, suspect_ip, delta = jump
                suspect_labels = {
                    **labels,
                    "suspect_hop": str(suspect_hop),
                    "suspect_ip": suspect_ip,
                }
                TARGET_LATENCY_JUMP_SUSPECT.labels(**suspect_labels).set(1)
                TARGET_LATENCY_JUMP_MS.labels(**suspect_labels).set(delta)

        logger.info(
            f"net_observer metrics updated | "
            f"targets={len(targets)} failed={failed_targets} cycle={cycle_duration:.2f}s"
        )

        await asyncio.sleep(interval_seconds)
