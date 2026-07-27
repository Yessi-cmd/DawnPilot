import contextlib
import datetime as dt
import hashlib
import io
import json
import math
import os
import tempfile
import threading
import time
import unittest
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

from server.dawnpilot_server import (
    CACHE_SCHEMA_VERSION,
    ENSEMBLE_MODELS,
    ENSEMBLE_URL,
    UPSTREAM_URL,
    Config,
    ConfigurationError,
    ForecastCache,
    UpstreamError,
    create_handler,
    derive_ensemble_probabilities,
    fetch_open_meteo,
    normalize_open_meteo,
    validate_normalized_forecast,
)


TEST_TOKEN = hashlib.sha256(b"DawnPilot unit-test credential").hexdigest()


class ConfigTests(unittest.TestCase):
    def test_production_defaults_require_loopback_and_strong_token(self) -> None:
        with mock.patch.dict(os.environ, {"DAWNPILOT_TOKEN": TEST_TOKEN}, clear=True):
            config = Config.from_environment()

        self.assertEqual(config.bind_host, "127.0.0.1")
        self.assertEqual(config.port, 8787)
        self.assertEqual(config.bearer_token, TEST_TOKEN)

    def test_rejects_non_loopback_or_nonstandard_port(self) -> None:
        cases = [
            {"DAWNPILOT_BIND": "0.0.0.0"},
            {"DAWNPILOT_PORT": "8788"},
        ]
        for values in cases:
            with self.subTest(values=values):
                environment = {"DAWNPILOT_TOKEN": TEST_TOKEN, **values}
                with mock.patch.dict(os.environ, environment, clear=True):
                    with self.assertRaises(ConfigurationError):
                        Config.from_environment()

    def test_rejects_empty_weak_whitespace_and_placeholder_tokens(self) -> None:
        tokens = [
            "",
            "too-short",
            "a" * 64,
            "abcd1234" * 8,
            " " + TEST_TOKEN,
            TEST_TOKEN + "\n",
            "replace-with-a-long-random-token",
        ]
        for token in tokens:
            with self.subTest(token=repr(token)):
                with mock.patch.dict(
                    os.environ,
                    {"DAWNPILOT_TOKEN": token},
                    clear=True,
                ):
                    with self.assertRaises(ConfigurationError):
                        Config.from_environment()

    def test_rejects_invalid_backoff_range(self) -> None:
        environment = {
            "DAWNPILOT_TOKEN": TEST_TOKEN,
            "DAWNPILOT_FAILURE_BACKOFF": "120",
            "DAWNPILOT_FAILURE_BACKOFF_MAX": "60",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(ConfigurationError):
                Config.from_environment()


class NormalizeOpenMeteoTests(unittest.TestCase):
    def test_normalizes_complete_hourly_rows_with_timezone_offset(self) -> None:
        result = normalize_open_meteo(make_open_meteo_raw(), "Asia/Shanghai")

        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["source"], "open-meteo")
        self.assertEqual(result["hourly"][1]["precipitation_probability"], 60)
        self.assertTrue(result["hourly"][0]["time"].endswith("+08:00"))
        validate_normalized_forecast(result, expected_timezone="Asia/Shanghai")

    def test_rejects_empty_or_mismatched_hourly_arrays(self) -> None:
        empty = make_open_meteo_raw()
        for key in empty["hourly"]:
            empty["hourly"][key] = []
        short = make_open_meteo_raw()
        short["hourly"]["rain"] = [0]
        missing = make_open_meteo_raw()
        missing["hourly"].pop("weather_code")

        for raw in (empty, short, missing):
            with self.subTest(raw=raw):
                with self.assertRaises(UpstreamError):
                    normalize_open_meteo(raw, "Asia/Shanghai")

    def test_rejects_non_finite_out_of_range_or_wrong_type_values(self) -> None:
        mutations = [
            ("precipitation_probability", 0, 101),
            ("precipitation_probability", 0, math.nan),
            ("precipitation", 0, -0.1),
            ("weather_code", 0, 61.0),
            ("weather_code", 0, 100),
        ]
        for field, index, value in mutations:
            with self.subTest(field=field, value=value):
                raw = make_open_meteo_raw()
                raw["hourly"][field][index] = value
                with self.assertRaises(UpstreamError):
                    normalize_open_meteo(raw, "Asia/Shanghai")

    def test_rejects_duplicate_unordered_or_non_hourly_timestamps(self) -> None:
        first = int(
            dt.datetime(2026, 7, 15, 23, tzinfo=dt.timezone.utc).timestamp()
        )
        second = first + 3600
        timestamp_sets = [
            [first, first],
            [second, first],
            [first + 1800, second],
        ]
        for timestamps in timestamp_sets:
            with self.subTest(timestamps=timestamps):
                raw = make_open_meteo_raw()
                raw["hourly"]["time"] = timestamps
                with self.assertRaises(UpstreamError):
                    normalize_open_meteo(raw, "Asia/Shanghai")

    def test_dst_fallback_epochs_remain_unique_and_strictly_ordered(self) -> None:
        zone = ZoneInfo("America/New_York")
        first_local_hour = dt.datetime(
            2026,
            11,
            1,
            1,
            tzinfo=zone,
            fold=0,
        )
        second_local_hour = dt.datetime(
            2026,
            11,
            1,
            1,
            tzinfo=zone,
            fold=1,
        )
        raw = make_open_meteo_raw()
        raw["hourly"]["time"] = [
            int(first_local_hour.timestamp()),
            int(second_local_hour.timestamp()),
        ]

        result = normalize_open_meteo(raw, "America/New_York")
        timestamps = [
            dt.datetime.fromisoformat(row["time"]) for row in result["hourly"]
        ]

        self.assertEqual(timestamps[0].hour, 1)
        self.assertEqual(timestamps[1].hour, 1)
        self.assertNotEqual(timestamps[0].utcoffset(), timestamps[1].utcoffset())
        self.assertLess(
            timestamps[0].astimezone(dt.timezone.utc),
            timestamps[1].astimezone(dt.timezone.utc),
        )

    def test_rejects_missing_or_invalid_coordinates(self) -> None:
        values = [None, math.inf, -91]
        for value in values:
            with self.subTest(value=value):
                raw = make_open_meteo_raw()
                raw["latitude"] = value
                with self.assertRaises(UpstreamError):
                    normalize_open_meteo(raw, "Asia/Shanghai")


class EnsembleProbabilityTests(unittest.TestCase):
    def test_probability_is_the_share_of_members_reaching_measurable_rain(self) -> None:
        result = derive_ensemble_probabilities(make_ensemble_raw(wet_members=30))

        self.assertEqual(result["member_count"], 40)
        self.assertEqual(result["models"], list(ENSEMBLE_MODELS))
        self.assertEqual(set(result["probabilities"].values()), {75.0})

    def test_members_below_the_measurable_threshold_do_not_count_as_rain(self) -> None:
        raw = make_ensemble_raw(wet_members=0)
        for index in range(10):
            raw["hourly"][f"precipitation_member{index:02d}_ecmwf_ifs025_ensemble"] = [
                0.09,
                0.09,
            ]

        result = derive_ensemble_probabilities(raw)

        self.assertEqual(set(result["probabilities"].values()), {0.0})

    def test_missing_member_values_are_ignored_until_too_few_remain(self) -> None:
        raw = make_ensemble_raw(wet_members=40)
        # First hour keeps 40 usable members, second hour drops below the floor.
        for index in range(5):
            raw["hourly"][f"precipitation_member{index:02d}_ecmwf_ifs025_ensemble"] = [
                1.0,
                None,
            ]

        result = derive_ensemble_probabilities(raw)
        epochs = sorted(result["probabilities"])

        self.assertEqual(len(epochs), 1)
        self.assertEqual(result["probabilities"][epochs[0]], 100.0)

    def test_rejects_too_few_members_and_invalid_values(self) -> None:
        with self.assertRaises(UpstreamError):
            derive_ensemble_probabilities(make_ensemble_raw(member_count=39))

        negative = make_ensemble_raw()
        negative["hourly"]["precipitation_member00_ecmwf_ifs025_ensemble"] = [-1.0, 0.0]
        with self.assertRaises(UpstreamError):
            derive_ensemble_probabilities(negative)

        text = make_ensemble_raw()
        text["hourly"]["precipitation_member00_ecmwf_ifs025_ensemble"] = ["1.0", 0.0]
        with self.assertRaises(UpstreamError):
            derive_ensemble_probabilities(text)

        unordered = make_ensemble_raw()
        unordered["hourly"]["time"] = list(reversed(unordered["hourly"]["time"]))
        with self.assertRaises(UpstreamError):
            derive_ensemble_probabilities(unordered)

    def test_significant_probability_counts_only_commute_changing_rain(self) -> None:
        raw = make_ensemble_raw(wet_members=0)
        # 20 members drizzle, 10 members reach commute-changing rain.
        for index in range(20):
            amount = 0.6 if index < 10 else 0.2
            raw["hourly"][f"precipitation_member{index:02d}_ecmwf_ifs025_ensemble"] = [
                amount,
                amount,
            ]

        result = derive_ensemble_probabilities(raw)

        self.assertEqual(set(result["probabilities"].values()), {50.0})
        self.assertEqual(set(result["significant_probabilities"].values()), {25.0})

    def test_normalization_publishes_both_probabilities_per_hour(self) -> None:
        raw = make_ensemble_raw(wet_members=0)
        for index in range(20):
            amount = 0.6 if index < 10 else 0.2
            raw["hourly"][f"precipitation_member{index:02d}_ecmwf_ifs025_ensemble"] = [
                amount,
                amount,
            ]
        ensemble = derive_ensemble_probabilities(raw)

        result = normalize_open_meteo(
            make_open_meteo_raw(),
            "Asia/Shanghai",
            ensemble=ensemble,
        )

        for row in result["hourly"]:
            self.assertEqual(row["precipitation_probability"], 50.0)
            self.assertEqual(row["precipitation_probability_significant"], 25.0)
        validate_normalized_forecast(result, expected_timezone="Asia/Shanghai")

    def test_deterministic_fallback_omits_the_significant_probability(self) -> None:
        result = normalize_open_meteo(make_open_meteo_raw(), "Asia/Shanghai")

        for row in result["hourly"]:
            self.assertNotIn("precipitation_probability_significant", row)
        validate_normalized_forecast(result, expected_timezone="Asia/Shanghai")

    def test_validation_rejects_an_out_of_range_significant_probability(self) -> None:
        payload = normalize_open_meteo(
            make_open_meteo_raw(),
            "Asia/Shanghai",
            ensemble=derive_ensemble_probabilities(make_ensemble_raw(wet_members=10)),
        )
        payload["hourly"][0]["precipitation_probability_significant"] = 140

        with self.assertRaises(UpstreamError):
            validate_normalized_forecast(payload, expected_timezone="Asia/Shanghai")

    def test_normalization_prefers_ensemble_probability_over_deterministic(self) -> None:
        ensemble = derive_ensemble_probabilities(make_ensemble_raw(wet_members=10))

        result = normalize_open_meteo(
            make_open_meteo_raw(),
            "Asia/Shanghai",
            ensemble=ensemble,
        )

        self.assertEqual(result["probability_source"], "ensemble")
        self.assertEqual(result["ensemble_member_count"], 40)
        self.assertEqual(result["ensemble_models"], list(ENSEMBLE_MODELS))
        for row in result["hourly"]:
            self.assertEqual(row["precipitation_probability"], 25.0)
        validate_normalized_forecast(result, expected_timezone="Asia/Shanghai")

    def test_partial_or_missing_ensemble_keeps_the_deterministic_probability(self) -> None:
        full = derive_ensemble_probabilities(make_ensemble_raw(wet_members=10))
        partial = {
            "probabilities": {min(full["probabilities"]): 25.0},
            "member_count": 40,
            "models": list(ENSEMBLE_MODELS),
        }

        for ensemble in (None, partial):
            with self.subTest(ensemble=ensemble):
                result = normalize_open_meteo(
                    make_open_meteo_raw(),
                    "Asia/Shanghai",
                    ensemble=ensemble,
                )

                self.assertEqual(result["probability_source"], "deterministic")
                self.assertEqual(result["ensemble_member_count"], 0)
                self.assertEqual(result["ensemble_models"], [])
                self.assertEqual(
                    [row["precipitation_probability"] for row in result["hourly"]],
                    [20, 60],
                )

    def test_failed_ensemble_request_still_produces_a_forecast(self) -> None:
        def fake_request(url, parameters, timeout_seconds):
            if url == ENSEMBLE_URL:
                raise UpstreamError("ensemble is unavailable")
            return make_open_meteo_raw()

        with mock.patch(
            "server.dawnpilot_server.request_open_meteo_json",
            side_effect=fake_request,
        ):
            result = fetch_open_meteo(31.25, 121.5, "Asia/Shanghai", 5)

        self.assertEqual(result["probability_source"], "deterministic")
        self.assertEqual(
            [row["precipitation_probability"] for row in result["hourly"]],
            [20, 60],
        )

    def test_unexpected_ensemble_exception_still_produces_a_forecast(self) -> None:
        def fake_request(url, parameters, timeout_seconds):
            if url == ENSEMBLE_URL:
                raise RuntimeError("ensemble parser failed")
            return make_open_meteo_raw()

        with mock.patch(
            "server.dawnpilot_server.request_open_meteo_json",
            side_effect=fake_request,
        ):
            result = fetch_open_meteo(31.25, 121.5, "Asia/Shanghai", 5)

        self.assertEqual(result["probability_source"], "deterministic")
        self.assertEqual(
            [row["precipitation_probability"] for row in result["hourly"]],
            [20, 60],
        )

    def test_both_upstream_requests_are_issued_for_one_forecast(self) -> None:
        requested_urls = []

        def fake_request(url, parameters, timeout_seconds):
            requested_urls.append(url)
            if url == ENSEMBLE_URL:
                return make_ensemble_raw(wet_members=40)
            return make_open_meteo_raw()

        with mock.patch(
            "server.dawnpilot_server.request_open_meteo_json",
            side_effect=fake_request,
        ):
            result = fetch_open_meteo(31.25, 121.5, "Asia/Shanghai", 5)

        self.assertEqual(sorted(requested_urls), sorted([UPSTREAM_URL, ENSEMBLE_URL]))
        self.assertEqual(result["probability_source"], "ensemble")
        self.assertEqual(
            [row["precipitation_probability"] for row in result["hourly"]],
            [100.0, 100.0],
        )

    def test_deterministic_failure_still_fails_the_fetch(self) -> None:
        def fake_request(url, parameters, timeout_seconds):
            if url == UPSTREAM_URL:
                raise UpstreamError("deterministic forecast is unavailable")
            return make_ensemble_raw(wet_members=40)

        with mock.patch(
            "server.dawnpilot_server.request_open_meteo_json",
            side_effect=fake_request,
        ):
            with self.assertRaises(UpstreamError):
                fetch_open_meteo(31.25, 121.5, "Asia/Shanghai", 5)


class NormalizedForecastValidationTests(unittest.TestCase):
    def test_rejects_unknown_schema_timezone_and_stale_new_payload(self) -> None:
        mutations = [
            ("schema_version", 2),
            ("timezone", "UTC"),
            ("stale", True),
        ]
        for field, value in mutations:
            with self.subTest(field=field):
                payload = make_payload(31.23, 121.47, "Asia/Shanghai")
                payload[field] = value
                with self.assertRaises(UpstreamError):
                    validate_normalized_forecast(
                        payload,
                        expected_timezone="Asia/Shanghai",
                    )

    def test_rejects_empty_or_semantically_invalid_normalized_rows(self) -> None:
        payloads = []
        empty = make_payload(31.23, 121.47, "Asia/Shanghai")
        empty["hourly"] = []
        payloads.append(empty)

        missing_metric = make_payload(31.23, 121.47, "Asia/Shanghai")
        missing_metric["hourly"][0].pop("rain_mm")
        payloads.append(missing_metric)

        duplicate = make_payload(31.23, 121.47, "Asia/Shanghai", hour_count=2)
        duplicate["hourly"][1]["time"] = duplicate["hourly"][0]["time"]
        payloads.append(duplicate)

        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(UpstreamError):
                    validate_normalized_forecast(
                        payload,
                        expected_timezone="Asia/Shanghai",
                    )

    def test_enforces_request_coordinates_with_grid_drift_tolerance(self) -> None:
        nearby = make_payload(31.28, 121.52, "Asia/Shanghai")
        validate_normalized_forecast(
            nearby,
            expected_timezone="Asia/Shanghai",
            expected_latitude=31.23,
            expected_longitude=121.47,
        )

        for latitude, longitude in ((31.34, 121.47), (31.23, 121.58)):
            with self.subTest(latitude=latitude, longitude=longitude):
                mismatched = make_payload(
                    latitude,
                    longitude,
                    "Asia/Shanghai",
                )
                with self.assertRaises(UpstreamError):
                    validate_normalized_forecast(
                        mismatched,
                        expected_timezone="Asia/Shanghai",
                        expected_latitude=31.23,
                        expected_longitude=121.47,
                    )


class ForecastCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.cache_file = Path(self.temporary_directory.name) / "cache.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_fresh_cache_avoids_duplicate_upstream_fetch(self) -> None:
        calls = []

        def fetcher(latitude, longitude, timezone, timeout):
            calls.append((latitude, longitude, timezone, timeout))
            return make_payload(latitude, longitude, timezone)

        cache = ForecastCache(self.config(cache_ttl_seconds=900), fetcher=fetcher)
        first = cache.get(31.23, 121.47, "Asia/Shanghai")
        second = cache.get(31.23, 121.47, "Asia/Shanghai")

        self.assertEqual(len(calls), 1)
        self.assertFalse(first["stale"])
        self.assertFalse(second["stale"])

    def test_concurrent_cold_misses_share_one_upstream_fetch(self) -> None:
        calls = 0
        calls_lock = threading.Lock()

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal calls
            with calls_lock:
                calls += 1
            time.sleep(0.05)
            return make_payload(latitude, longitude, timezone)

        cache = ForecastCache(self.config(), fetcher=fetcher)
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(
                executor.map(
                    lambda _index: cache.get(31.23, 121.47, "Asia/Shanghai"),
                    range(8),
                )
            )

        self.assertEqual(calls, 1)
        self.assertTrue(all(not result["stale"] for result in results))

    def test_total_upstream_concurrency_is_bounded(self) -> None:
        active = 0
        maximum_active = 0
        active_lock = threading.Lock()

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal active, maximum_active
            with active_lock:
                active += 1
                maximum_active = max(maximum_active, active)
            time.sleep(0.05)
            with active_lock:
                active -= 1
            return make_payload(latitude, longitude, timezone)

        cache = ForecastCache(
            self.config(max_upstream_concurrency=2),
            fetcher=fetcher,
        )
        with ThreadPoolExecutor(max_workers=6) as executor:
            list(
                executor.map(
                    lambda index: cache.get(
                        30.0 + index,
                        121.47,
                        "Asia/Shanghai",
                    ),
                    range(6),
                )
            )

        self.assertEqual(maximum_active, 2)

    def test_expired_cache_returns_stale_immediately_and_applies_failure_backoff(self) -> None:
        calls = 0
        refresh_finished = threading.Event()

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal calls
            calls += 1
            if calls == 1:
                return make_payload(latitude, longitude, timezone)
            time.sleep(0.2)
            refresh_finished.set()
            raise UpstreamError("offline")

        cache = ForecastCache(
            self.config(
                cache_ttl_seconds=0,
                failure_backoff_seconds=30,
                failure_backoff_max_seconds=30,
            ),
            fetcher=fetcher,
        )
        cache.get(31.23, 121.47, "Asia/Shanghai")

        started = time.monotonic()
        stale = cache.get(31.23, 121.47, "Asia/Shanghai")
        elapsed = time.monotonic() - started

        self.assertTrue(stale["stale"])
        self.assertLess(elapsed, 0.1)
        self.assertTrue(refresh_finished.wait(timeout=2))
        wait_until(lambda: not cache._inflight)

        again = cache.get(31.23, 121.47, "Asia/Shanghai")
        self.assertTrue(again["stale"])
        self.assertIn("warning", again)
        self.assertEqual(calls, 2)

    def test_invalid_refresh_never_replaces_last_known_good(self) -> None:
        calls = 0

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal calls
            calls += 1
            payload = make_payload(latitude, longitude, timezone)
            payload["source"] = "known-good" if calls == 1 else "invalid"
            if calls > 1:
                payload["hourly"][0]["precipitation_probability"] = None
            return payload

        cache = ForecastCache(self.config(cache_ttl_seconds=0), fetcher=fetcher)
        cache.get(31.23, 121.47, "Asia/Shanghai")
        stale = cache.get(31.23, 121.47, "Asia/Shanghai")
        self.assertTrue(stale["stale"])
        wait_until(lambda: not cache._inflight)

        retained = cache.get(31.23, 121.47, "Asia/Shanghai")
        self.assertEqual(retained["source"], "known-good")
        self.assertTrue(retained["stale"])

    def test_mismatched_location_payload_is_not_cached_under_request_key(self) -> None:
        def fetcher(latitude, longitude, timezone, timeout):
            return make_payload(latitude + 1, longitude, timezone)

        cache = ForecastCache(self.config(), fetcher=fetcher)

        with self.assertRaises(UpstreamError):
            cache.get(31.23, 121.47, "Asia/Shanghai")
        self.assertEqual(cache.entry_count(), 0)

    def test_cache_is_bounded_lru_and_uses_six_decimal_keys(self) -> None:
        calls = []

        def fetcher(latitude, longitude, timezone, timeout):
            calls.append(latitude)
            return make_payload(latitude, longitude, timezone)

        cache = ForecastCache(
            self.config(cache_max_entries=2),
            fetcher=fetcher,
        )
        cache.get(31.230410, 121.47, "Asia/Shanghai")
        cache.get(31.230440, 121.47, "Asia/Shanghai")
        cache.get(31.230470, 121.47, "Asia/Shanghai")

        self.assertEqual(cache.entry_count(), 2)
        self.assertEqual(len(calls), 3)

    def test_cache_survives_process_restart_and_has_private_mode(self) -> None:
        first = ForecastCache(
            self.config(),
            fetcher=lambda lat, lon, zone, timeout: make_payload(lat, lon, zone),
        )
        first.get(31.23, 121.47, "Asia/Shanghai")
        self.assertEqual(self.cache_file.stat().st_mode & 0o777, 0o600)

        def should_not_fetch(*_args):
            raise AssertionError("fresh persisted cache should be used")

        second = ForecastCache(self.config(), fetcher=should_not_fetch)
        result = second.get(31.23, 121.47, "Asia/Shanghai")

        self.assertFalse(result["stale"])
        self.assertEqual(second.entry_count(), 1)
        self.assertTrue(second.persistence_is_healthy())

    def test_existing_regular_cache_is_hardened_to_mode_0600_on_load(self) -> None:
        self.cache_file.write_text(
            json.dumps(
                {
                    "schema_version": CACHE_SCHEMA_VERSION,
                    "entries": [
                        make_cache_entry(31.23, 121.47, "Asia/Shanghai")
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.cache_file.chmod(0o644)

        cache = ForecastCache(self.config())

        self.assertEqual(cache.entry_count(), 1)
        self.assertEqual(self.cache_file.stat().st_mode & 0o777, 0o600)
        self.assertTrue(cache.persistence_is_healthy())

    def test_symlink_cache_is_not_followed_or_replaced(self) -> None:
        target = Path(self.temporary_directory.name) / "sensitive-target"
        target.write_text("do not touch", encoding="utf-8")
        self.cache_file.symlink_to(target)

        cache = ForecastCache(self.config())
        cache.stop()

        self.assertEqual(cache.entry_count(), 0)
        self.assertFalse(cache.persistence_is_healthy())
        self.assertTrue(self.cache_file.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), "do not touch")

    def test_load_recovers_valid_entries_individually_and_marks_degraded(self) -> None:
        valid = make_cache_entry(31.23, 121.47, "Asia/Shanghai")
        self.cache_file.write_text(
            json.dumps(
                {
                    "schema_version": CACHE_SCHEMA_VERSION,
                    "entries": [valid, {"broken": True}],
                }
            ),
            encoding="utf-8",
        )

        cache = ForecastCache(self.config())

        self.assertEqual(cache.entry_count(), 1)
        self.assertFalse(cache.persistence_is_healthy())

    def test_load_migrates_legacy_schema_one_and_rejects_unknown_schema(self) -> None:
        legacy = make_cache_entry(31.23, 121.47, "Asia/Shanghai")
        legacy.pop("last_accessed_at")
        self.cache_file.write_text(
            json.dumps({"schema_version": 1, "entries": [legacy]}),
            encoding="utf-8",
        )
        self.assertEqual(ForecastCache(self.config()).entry_count(), 1)

        self.cache_file.write_text(
            json.dumps({"schema_version": 99, "entries": [legacy]}),
            encoding="utf-8",
        )
        unknown = ForecastCache(self.config())
        self.assertEqual(unknown.entry_count(), 0)
        self.assertFalse(unknown.persistence_is_healthy())
        unknown.stop()
        self.assertEqual(
            json.loads(self.cache_file.read_text(encoding="utf-8"))["schema_version"],
            99,
        )

    def test_load_prunes_entries_past_retention(self) -> None:
        expired = make_cache_entry(31.23, 121.47, "Asia/Shanghai")
        expired_at = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
        ).replace(microsecond=0).isoformat()
        expired["last_accessed_at"] = expired_at
        self.cache_file.write_text(
            json.dumps(
                {
                    "schema_version": CACHE_SCHEMA_VERSION,
                    "entries": [expired],
                }
            ),
            encoding="utf-8",
        )

        cache = ForecastCache(self.config(cache_retention_seconds=60))

        self.assertEqual(cache.entry_count(), 0)

    def test_background_refresh_persists_only_once_per_batch(self) -> None:
        fetch_calls = 0

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal fetch_calls
            fetch_calls += 1
            return make_payload(latitude, longitude, timezone)

        cache = ForecastCache(self.config(), fetcher=fetcher)
        cache.get(31.23, 121.47, "Asia/Shanghai")
        cache.get(32.23, 121.47, "Asia/Shanghai")
        persist_calls = 0
        original_persist = cache._persist_locked

        def counted_persist():
            nonlocal persist_calls
            persist_calls += 1
            return original_persist()

        cache._persist_locked = counted_persist
        cache._refresh_all_once()

        self.assertEqual(fetch_calls, 4)
        self.assertEqual(persist_calls, 1)

    def config(self, **overrides) -> Config:
        values = {
            "bearer_token": TEST_TOKEN,
            "cache_file": self.cache_file,
        }
        values.update(overrides)
        return Config(**values)


class HTTPHandlerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        cache_path = Path(self.temporary_directory.name) / "cache.json"
        self.config = Config(bearer_token=TEST_TOKEN, cache_file=cache_path)
        self.cache = ForecastCache(
            self.config,
            fetcher=lambda lat, lon, zone, timeout: make_payload(lat, lon, zone),
        )
        self.handler_type = create_handler(self.cache, self.config)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_health_is_minimal_and_forecast_requires_authentication(self) -> None:
        status, body = self.invoke("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ok"})

        status, body = self.invoke(
            "/v1/forecast?latitude=31.23&longitude=121.47&timezone=Asia%2FShanghai"
        )
        self.assertEqual(status, 401)
        self.assertEqual(body, {"error": "unauthorized"})

    def test_authenticated_forecast_and_log_redaction(self) -> None:
        path = "/v1/forecast?" + urllib.parse.urlencode(
            {
                "latitude": "31.2304",
                "longitude": "121.4737",
                "timezone": "Asia/Shanghai",
            }
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status, body = self.invoke(
                path,
                headers={"Authorization": f"Bearer {TEST_TOKEN}"},
            )
            handler = self.make_handler("/v1/forecast?latitude=secret")
            handler.log_message('"%s" %s %s', "request with coordinates", "200", "-")

        self.assertEqual(status, 200)
        self.assertEqual(body["schema_version"], 1)
        self.assertNotIn("31.2304", output.getvalue())
        self.assertNotIn("Asia", output.getvalue())
        self.assertIn("GET /v1/forecast 200", output.getvalue())

    def test_persistence_failure_marks_health_degraded(self) -> None:
        self.cache._persistence_ok = False
        status, body = self.invoke("/healthz")
        self.assertEqual(status, 503)
        self.assertEqual(body, {"status": "degraded"})

    def invoke(self, path, headers=None):
        handler = self.make_handler(path, headers=headers)
        response = {}

        def capture(status, payload):
            response["status"] = status.value
            response["payload"] = payload

        handler._send_json = capture
        handler.do_GET()
        return response["status"], response["payload"]

    def make_handler(self, path, headers=None):
        handler = object.__new__(self.handler_type)
        handler.path = path
        handler.headers = headers or {}
        handler.command = "GET"
        handler.client_address = ("127.0.0.1", 12345)
        return handler


def make_open_meteo_raw():
    first_hour = int(
        dt.datetime(2026, 7, 15, 23, tzinfo=dt.timezone.utc).timestamp()
    )
    return {
        "latitude": 31.25,
        "longitude": 121.5,
        "hourly": {
            "time": [first_hour, first_hour + 3600],
            "precipitation_probability": [20, 60],
            "precipitation": [0, 0.4],
            "rain": [0, 0.4],
            "showers": [0, 0],
            "snowfall": [0, 0],
            "weather_code": [2, 61],
        },
    }


def make_ensemble_raw(member_count=40, wet_members=0):
    """Ensemble response matching make_open_meteo_raw's two hours."""
    first_hour = int(
        dt.datetime(2026, 7, 15, 23, tzinfo=dt.timezone.utc).timestamp()
    )
    hourly = {"time": [first_hour, first_hour + 3600]}
    for index in range(member_count):
        amount = 1.0 if index < wet_members else 0.0
        hourly[f"precipitation_member{index:02d}_ecmwf_ifs025_ensemble"] = [
            amount,
            amount,
        ]
    return {"latitude": 31.25, "longitude": 121.5, "hourly": hourly}


def make_payload(latitude, longitude, timezone, hour_count=1):
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    start = now.replace(minute=0, second=0, microsecond=0) + dt.timedelta(hours=1)
    rows = []
    for offset in range(hour_count):
        rows.append(
            {
                "time": (start + dt.timedelta(hours=offset)).isoformat(),
                "precipitation_probability": 20,
                "precipitation_mm": 0,
                "rain_mm": 0,
                "showers_mm": 0,
                "snowfall_cm": 0,
                "weather_code": 2,
            }
        )
    return {
        "schema_version": 1,
        "source": "test",
        "fetched_at": now.isoformat(),
        "served_at": now.isoformat(),
        "stale": False,
        "latitude": latitude,
        "longitude": longitude,
        "timezone": timezone,
        "hourly": rows,
    }


def make_cache_entry(latitude, longitude, timezone):
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    return {
        "latitude": latitude,
        "longitude": longitude,
        "timezone": timezone,
        "stored_at": now,
        "last_accessed_at": now,
        "payload": make_payload(latitude, longitude, timezone),
    }


def wait_until(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("condition was not reached before timeout")


if __name__ == "__main__":
    unittest.main()
