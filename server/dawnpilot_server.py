#!/usr/bin/env python3
"""Small weather cache/proxy for DawnPilot.

The service uses only Python's standard library so it runs comfortably on a
small Debian 12 VPS. It fetches Open-Meteo hourly forecasts, normalizes their
shape for the iOS app, caches known locations, and refreshes them periodically.
"""

from __future__ import annotations

import copy
import dataclasses
import datetime as dt
import hmac
import json
import os
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


UPSTREAM_URL = "https://api.open-meteo.com/v1/forecast"
HOURLY_FIELDS = (
    "precipitation_probability",
    "precipitation",
    "rain",
    "showers",
    "snowfall",
    "weather_code",
)


class ConfigurationError(ValueError):
    pass


class UpstreamError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Config:
    bind_host: str = "127.0.0.1"
    port: int = 8787
    bearer_token: str = ""
    cache_ttl_seconds: int = 900
    refresh_interval_seconds: int = 1800
    upstream_timeout_seconds: int = 15
    cache_file: Path = Path("/var/lib/dawnpilot/cache.json")

    @classmethod
    def from_environment(cls) -> "Config":
        config = cls(
            bind_host=os.environ.get("DAWNPILOT_BIND", "127.0.0.1"),
            port=_environment_int("DAWNPILOT_PORT", 8787, minimum=1, maximum=65535),
            bearer_token=os.environ.get("DAWNPILOT_TOKEN", ""),
            cache_ttl_seconds=_environment_int("DAWNPILOT_CACHE_TTL", 900, minimum=30),
            refresh_interval_seconds=_environment_int(
                "DAWNPILOT_REFRESH_INTERVAL", 1800, minimum=60
            ),
            upstream_timeout_seconds=_environment_int(
                "DAWNPILOT_UPSTREAM_TIMEOUT", 15, minimum=1, maximum=60
            ),
            cache_file=Path(
                os.environ.get("DAWNPILOT_CACHE_FILE", "/var/lib/dawnpilot/cache.json")
            ),
        )
        if not config.bearer_token:
            raise ConfigurationError("DAWNPILOT_TOKEN must not be empty")
        return config


@dataclasses.dataclass
class CacheEntry:
    latitude: float
    longitude: float
    timezone: str
    stored_at: dt.datetime
    payload: dict[str, Any]

    def to_json(self) -> dict[str, Any]:
        return {
            "latitude": self.latitude,
            "longitude": self.longitude,
            "timezone": self.timezone,
            "stored_at": isoformat(self.stored_at),
            "payload": self.payload,
        }

    @classmethod
    def from_json(cls, value: dict[str, Any]) -> "CacheEntry":
        return cls(
            latitude=float(value["latitude"]),
            longitude=float(value["longitude"]),
            timezone=str(value["timezone"]),
            stored_at=dt.datetime.fromisoformat(value["stored_at"]),
            payload=dict(value["payload"]),
        )


Fetcher = Callable[[float, float, str, int], dict[str, Any]]


class ForecastCache:
    def __init__(self, config: Config, fetcher: Fetcher | None = None) -> None:
        self.config = config
        self.fetcher = fetcher or fetch_open_meteo
        self._entries: dict[str, CacheEntry] = {}
        self._lock = threading.RLock()
        self._stop_event = threading.Event()
        self._refresh_thread: threading.Thread | None = None
        self._load()

    @staticmethod
    def key(latitude: float, longitude: float, timezone: str) -> str:
        return f"{latitude:.4f},{longitude:.4f},{timezone}"

    def get(self, latitude: float, longitude: float, timezone: str) -> dict[str, Any]:
        latitude, longitude, timezone = validate_query(latitude, longitude, timezone)
        key = self.key(latitude, longitude, timezone)
        now = utc_now()
        with self._lock:
            existing = self._entries.get(key)
            if existing and (now - existing.stored_at).total_seconds() <= self.config.cache_ttl_seconds:
                return self._served_payload(existing.payload, stale=False)

        try:
            payload = self.fetcher(
                latitude,
                longitude,
                timezone,
                self.config.upstream_timeout_seconds,
            )
        except Exception as error:
            with self._lock:
                existing = self._entries.get(key)
            if existing:
                stale_payload = self._served_payload(existing.payload, stale=True)
                stale_payload["warning"] = f"upstream refresh failed: {type(error).__name__}"
                return stale_payload
            if isinstance(error, UpstreamError):
                raise
            raise UpstreamError(str(error)) from error

        entry = CacheEntry(
            latitude=latitude,
            longitude=longitude,
            timezone=timezone,
            stored_at=now,
            payload=payload,
        )
        with self._lock:
            self._entries[key] = entry
            self._persist()
        return self._served_payload(payload, stale=False)

    def start_background_refresh(self) -> None:
        if self._refresh_thread is not None:
            return
        self._refresh_thread = threading.Thread(
            target=self._refresh_loop,
            name="weather-cache-refresh",
            daemon=True,
        )
        self._refresh_thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._refresh_thread:
            self._refresh_thread.join(timeout=5)

    def entry_count(self) -> int:
        with self._lock:
            return len(self._entries)

    def _refresh_loop(self) -> None:
        while not self._stop_event.wait(self.config.refresh_interval_seconds):
            with self._lock:
                entries = list(self._entries.values())
            for entry in entries:
                if self._stop_event.is_set():
                    return
                try:
                    payload = self.fetcher(
                        entry.latitude,
                        entry.longitude,
                        entry.timezone,
                        self.config.upstream_timeout_seconds,
                    )
                    refreshed = CacheEntry(
                        latitude=entry.latitude,
                        longitude=entry.longitude,
                        timezone=entry.timezone,
                        stored_at=utc_now(),
                        payload=payload,
                    )
                    with self._lock:
                        self._entries[self.key(entry.latitude, entry.longitude, entry.timezone)] = refreshed
                        self._persist()
                except Exception:
                    # Keep the last known good payload. The next interval retries it.
                    continue

    def _served_payload(self, payload: dict[str, Any], stale: bool) -> dict[str, Any]:
        result = copy.deepcopy(payload)
        result["served_at"] = isoformat(utc_now())
        result["stale"] = stale
        return result

    def _load(self) -> None:
        try:
            raw = json.loads(self.config.cache_file.read_text(encoding="utf-8"))
            entries = [CacheEntry.from_json(item) for item in raw.get("entries", [])]
        except (OSError, ValueError, TypeError, KeyError):
            return
        with self._lock:
            self._entries = {
                self.key(entry.latitude, entry.longitude, entry.timezone): entry for entry in entries
            }

    def _persist(self) -> None:
        try:
            self.config.cache_file.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.config.cache_file.with_suffix(".tmp")
            data = {
                "schema_version": 1,
                "entries": [entry.to_json() for entry in self._entries.values()],
            }
            temporary.write_text(
                json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )
            temporary.replace(self.config.cache_file)
        except OSError:
            # A read-only cache path must not make the API unavailable.
            return


def fetch_open_meteo(
    latitude: float,
    longitude: float,
    timezone: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    query = urllib.parse.urlencode(
        {
            "latitude": f"{latitude:.6f}",
            "longitude": f"{longitude:.6f}",
            "timezone": timezone,
            "forecast_days": "3",
            "hourly": ",".join(HOURLY_FIELDS),
        }
    )
    request = urllib.request.Request(
        f"{UPSTREAM_URL}?{query}",
        headers={"Accept": "application/json", "User-Agent": "DawnPilot/0.1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            raw = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise UpstreamError(f"Open-Meteo request failed: {error}") from error
    return normalize_open_meteo(raw, requested_timezone=timezone)


def normalize_open_meteo(raw: dict[str, Any], requested_timezone: str) -> dict[str, Any]:
    try:
        hourly = raw["hourly"]
        times = hourly["time"]
        zone = ZoneInfo(requested_timezone)
    except (KeyError, TypeError, ZoneInfoNotFoundError) as error:
        raise UpstreamError("Open-Meteo response is missing required fields") from error

    rows: list[dict[str, Any]] = []
    for index, local_time in enumerate(times):
        try:
            parsed = dt.datetime.fromisoformat(local_time)
        except (TypeError, ValueError) as error:
            raise UpstreamError("Open-Meteo returned an invalid hourly timestamp") from error
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=zone)
        rows.append(
            {
                "time": isoformat(parsed),
                "precipitation_probability": value_at(hourly, "precipitation_probability", index),
                "precipitation_mm": value_at(hourly, "precipitation", index),
                "rain_mm": value_at(hourly, "rain", index),
                "showers_mm": value_at(hourly, "showers", index),
                "snowfall_cm": value_at(hourly, "snowfall", index),
                "weather_code": value_at(hourly, "weather_code", index),
            }
        )

    return {
        "schema_version": 1,
        "source": "open-meteo",
        "fetched_at": isoformat(utc_now()),
        "served_at": isoformat(utc_now()),
        "stale": False,
        "latitude": float(raw.get("latitude", 0)),
        "longitude": float(raw.get("longitude", 0)),
        "timezone": requested_timezone,
        "hourly": rows,
    }


def value_at(hourly: dict[str, Any], key: str, index: int) -> Any:
    values = hourly.get(key)
    if not isinstance(values, list) or index >= len(values):
        return None
    return values[index]


def validate_query(latitude: float, longitude: float, timezone: str) -> tuple[float, float, str]:
    if not -90 <= latitude <= 90:
        raise ValueError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise ValueError("longitude must be between -180 and 180")
    try:
        ZoneInfo(timezone)
    except ZoneInfoNotFoundError as error:
        raise ValueError("unknown timezone") from error
    return round(latitude, 6), round(longitude, 6), timezone


def create_handler(cache: ForecastCache, config: Config) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "DawnPilotServer/0.1"

        def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/healthz":
                self._send_json(
                    HTTPStatus.OK,
                    {"status": "ok", "cached_locations": cache.entry_count()},
                )
                return
            if parsed.path != "/v1/forecast":
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if not self._authorized():
                self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                return

            query = urllib.parse.parse_qs(parsed.query)
            try:
                latitude = float(single_value(query, "latitude"))
                longitude = float(single_value(query, "longitude"))
                timezone = single_value(query, "timezone")
                payload = cache.get(latitude, longitude, timezone)
            except (KeyError, ValueError) as error:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
                return
            except UpstreamError as error:
                self._send_json(HTTPStatus.BAD_GATEWAY, {"error": str(error)})
                return
            self._send_json(HTTPStatus.OK, payload)

        def log_message(self, format_string: str, *args: Any) -> None:
            message = format_string % args
            print(f"{self.address_string()} {message}", flush=True)

        def _authorized(self) -> bool:
            provided = self.headers.get("Authorization", "")
            expected = f"Bearer {config.bearer_token}"
            return hmac.compare_digest(provided, expected)

        def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status.value)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    return Handler


def single_value(query: dict[str, list[str]], key: str) -> str:
    values = query[key]
    if len(values) != 1 or not values[0]:
        raise ValueError(f"{key} must appear exactly once")
    return values[0]


def isoformat(value: dt.datetime) -> str:
    return value.replace(microsecond=0).isoformat()


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _environment_int(name: str, default: int, minimum: int, maximum: int | None = None) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ConfigurationError(f"{name} must be an integer") from error
    if value < minimum or (maximum is not None and value > maximum):
        raise ConfigurationError(f"{name} is outside the supported range")
    return value


def main() -> None:
    config = Config.from_environment()
    cache = ForecastCache(config)
    cache.start_background_refresh()
    server = ThreadingHTTPServer((config.bind_host, config.port), create_handler(cache, config))

    def stop_server(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    print(f"DawnPilot server listening on {config.bind_host}:{config.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        cache.stop()
        server.server_close()


if __name__ == "__main__":
    main()
