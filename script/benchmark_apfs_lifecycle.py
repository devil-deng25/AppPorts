#!/usr/bin/env python3
"""Compare complete APFS operations on separately owned, identical test images.

Build both checkouts first. The baseline needs prepare_apfs_baseline.py and
OTHER_SWIFT_FLAGS='$(inherited) -DAPPPORTS_BASELINE'. Stage both test hosts with
isolate_test_host.py. This script never launches the installed AppPorts.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import statistics

from validate_private_apfs import Coordinator, read_json, write_json


SELECTOR = "AppPortsTests/APFSLifecycleBenchmarkTests/testIsolatedLifecycleBenchmark"


def run_one(repository, derived, dataset, count, timeout):
    run_file = derived / "Build/Products/LifecycleValidation.xctestrun"
    if not run_file.is_file():
        raise RuntimeError("Missing isolated test host: " + str(run_file))
    coordinator = Coordinator(repository, image_gib=4)
    try:
        coordinator.prepare()
        environment = os.environ.copy()
        for key, value in {"APPPORTS_REAL_MOUNT_ROOT": coordinator.fixture["rootPath"],
                           "APPPORTS_BENCHMARK_DATASET": dataset,
                           "APPPORTS_BENCHMARK_FILE_COUNT": str(count)}.items():
            environment[key] = value
            environment["TEST_RUNNER_" + key] = value
        coordinator.command("xcodebuild-benchmark", ["/usr/bin/xcodebuild", "test-without-building",
            "-xctestrun", str(run_file), "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
            "-only-testing:" + SELECTOR, "-resultBundlePath", str(coordinator.output / "test.xcresult")],
            timeout=timeout, environment=environment)
        result = read_json(Path(coordinator.fixture["rootPath"]) / "benchmark-result.json")
        if result.get("status") != "passed" or result.get("nonce") != coordinator.fixture["nonce"] \
                or not result.get("currentDataRestored") or not result.get("cleanupComplete"):
            raise RuntimeError("Benchmark did not complete the original user operation")
        final = coordinator.inventory()
        volumes = final.get("Volumes", [])
        if len(volumes) != 1 or volumes[0].get("APFSVolumeUUID", "").upper() != coordinator.fixture["initialVolumeUUID"].upper():
            raise RuntimeError("Unexpected volumes remain in the owned image")
        coordinator.command("detach-owned-image", ["/usr/bin/hdiutil", "detach", "/dev/" + coordinator.fixture["initialVolumeDevice"]])
        result.update(imageDetached=True, fixtureRoot=coordinator.fixture["rootPath"], artifacts=str(coordinator.output))
        write_json(coordinator.output / "summary.json", result)
        return result
    except Exception as error:
        write_json(coordinator.output / "summary.json", {"status": "failed", "error": str(error),
            "fixture": coordinator.fixture, "retainedForInspection": True})
        raise RuntimeError(f"{error}; fixture retained at {coordinator.output}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-derived-data", type=Path, required=True)
    parser.add_argument("--fixed-derived-data", type=Path, default=Path("build/LifecycleTests"))
    parser.add_argument("--datasets", default="small,large")
    parser.add_argument("--order", default="baseline,fixed,fixed,baseline")
    parser.add_argument("--small-count", type=int, default=20000)
    parser.add_argument("--large-count", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    destinations = {"baseline": args.baseline_derived_data.resolve(), "fixed": args.fixed_derived_data.resolve()}
    order = args.order.split(",")
    datasets = args.datasets.split(",")
    if any(value not in destinations for value in order) or any(value not in ["small", "large"] for value in datasets):
        parser.error("Use baseline/fixed order and small/large datasets")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = repository / "build/Validation" / ("lifecycle-benchmark-" + stamp + ".json")
    results = []
    for dataset in datasets:
        for version in order:
            print(json.dumps({"starting": version, "dataset": dataset, "results": str(output)}), flush=True)
            result = run_one(repository, destinations[version], dataset,
                args.small_count if dataset == "small" else args.large_count, args.timeout)
            result["version"] = version
            results.append(result)
            write_json(output, {"runs": results})
            print(json.dumps({"finished": version, "dataset": dataset,
                "migration": result["migration"], "restore": result["restore"]}), flush=True)
    medians = {}
    for dataset in datasets:
        medians[dataset] = {}
        for version in set(order):
            samples = [result for result in results if result["dataset"] == dataset and result["version"] == version]
            medians[dataset][version] = {direction: {phase: statistics.median(sample[direction][phase] for sample in samples)
                for phase in samples[0][direction]} for direction in ["migration", "restore"]}
    write_json(output, {"runs": results, "medians": medians})
    print(json.dumps({"results": str(output), "medians": medians}, indent=2), flush=True)


if __name__ == "__main__":
    main()
