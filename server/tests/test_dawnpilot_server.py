import datetime as dt
import tempfile
import unittest
from pathlib import Path

from server.dawnpilot_server import Config, ForecastCache, UpstreamError, normalize_open_meteo


class NormalizeOpenMeteoTests(unittest.TestCase):
    def test_normalizes_hourly_rows_with_timezone_offset(self) -> None:
        raw = {
            "latitude": 31.25,
            "longitude": 121.5,
            "hourly": {
                "time": ["2026-07-16T07:00", "2026-07-16T08:00"],
                "precipitation_probability": [20, 60],
                "precipitation": [0, 0.4],
                "rain": [0, 0.4],
                "showers": [0, 0],
                "snowfall": [0, 0],
                "weather_code": [2, 61],
            },
        }

        result = normalize_open_meteo(raw, "Asia/Shanghai")

        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["source"], "open-meteo")
        self.assertEqual(result["hourly"][1]["precipitation_probability"], 60)
        self.assertTrue(result["hourly"][0]["time"].endswith("+08:00"))


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

    def test_upstream_failure_returns_persisted_stale_payload(self) -> None:
        calls = 0

        def fetcher(latitude, longitude, timezone, timeout):
            nonlocal calls
            calls += 1
            if calls == 1:
                return make_payload(latitude, longitude, timezone)
            raise UpstreamError("offline")

        cache = ForecastCache(self.config(cache_ttl_seconds=0), fetcher=fetcher)
        cache.get(31.23, 121.47, "Asia/Shanghai")
        result = cache.get(31.23, 121.47, "Asia/Shanghai")

        self.assertTrue(result["stale"])
        self.assertIn("warning", result)

    def test_cache_survives_process_restart(self) -> None:
        first = ForecastCache(
            self.config(cache_ttl_seconds=900),
            fetcher=lambda lat, lon, zone, timeout: make_payload(lat, lon, zone),
        )
        first.get(31.23, 121.47, "Asia/Shanghai")

        def should_not_fetch(*_args):
            raise AssertionError("fresh persisted cache should be used")

        second = ForecastCache(self.config(cache_ttl_seconds=900), fetcher=should_not_fetch)
        result = second.get(31.23, 121.47, "Asia/Shanghai")

        self.assertFalse(result["stale"])
        self.assertEqual(second.entry_count(), 1)

    def config(self, cache_ttl_seconds: int) -> Config:
        return Config(
            bearer_token="test-token",
            cache_ttl_seconds=cache_ttl_seconds,
            cache_file=self.cache_file,
        )


def make_payload(latitude, longitude, timezone):
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    return {
        "schema_version": 1,
        "source": "test",
        "fetched_at": now,
        "served_at": now,
        "stale": False,
        "latitude": latitude,
        "longitude": longitude,
        "timezone": timezone,
        "hourly": [],
    }


if __name__ == "__main__":
    unittest.main()
