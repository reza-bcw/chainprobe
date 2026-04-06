import argparse
import asyncio
from prometheus_client import start_http_server
from config import load_config
from binary.version import report_binary_version_daily

def run():
    parser = argparse.ArgumentParser(description="Multi-Protocol Prometheus Exporter")
    parser.add_argument(
        "--config",
        type=str,
        default="config.toml",
        help="Path to config TOML file (default: config.toml)"
    )
    args = parser.parse_args()

    config = load_config(args.config)
    protocol = config.get("protocol", "").lower()

    tasks = []

    # Primary chain protocol collector
    if protocol == "cosmos":
        from collector import cosmos
        tasks.append(cosmos.metric_updater(config))

    elif protocol == "evm":
        from collector import evm
        tasks.append(evm.metric_updater(config))

    elif protocol in ("other", ""):
        print("[~] No primary chain collector enabled.")

    else:
        print(f"[!] Protocol '{protocol}' not supported for metrics collection.")
        print("[~] Skipping primary chain collector.")

    # Optional net observer collector
    net_observer_cfg = config.get("net_observer", {})
    if isinstance(net_observer_cfg, dict) and net_observer_cfg.get("enabled", False):
        from collector import net_observer
        tasks.append(net_observer.metric_updater(net_observer_cfg))
        print("[+] net_observer collector enabled")

    # Always run binary version metric
    tasks.append(report_binary_version_daily(config))

    print(f"Exporter running on :{config['metrics_port']}/metrics using config: {args.config}")
    start_http_server(config["metrics_port"])

    async def main():
        await asyncio.gather(*tasks)

    asyncio.run(main())

if __name__ == "__main__":
    run()
