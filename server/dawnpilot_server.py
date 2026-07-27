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
import math
import os
import signal
import stat
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
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
# Amounts and weather codes stay on the deterministic best-match forecast. The
# probability of precipitation instead comes from ensemble members, which have a
# far better resolved tail than the single ensemble behind the deterministic
# precipitation_probability field.
ENSEMBLE_URL = "https://ensemble-api.open-meteo.com/v1/ensemble"
ENSEMBLE_MODELS = ("ecmwf_ifs025", "icon_global", "gfs025")
ENSEMBLE_HOURLY_FIELD = "precipitation"
MEASURABLE_PRECIPITATION_MM = 0.1
# Rain worth leaving earlier for. Measurable drizzle wets the ground without
# changing a commute, so the app decides on this threshold and keeps the
# measurable one for the milder hedge.
SIGNIFICANT_PRECIPITATION_MM = 0.5
# Below this many usable members the ensemble is not better than the
# deterministic field, so the forecast keeps the deterministic probability.
MINIMUM_ENSEMBLE_MEMBERS = 40
PROBABILITY_SOURCE_ENSEMBLE = "ensemble"
PROBABILITY_SOURCE_DETERMINISTIC = "deterministic"
CACHE_SCHEMA_VERSION = 2
FORECAST_SCHEMA_VERSION = 1
MAXIMUM_COORDINATE_DRIFT_DEGREES = 0.1
MINIMUM_TOKEN_LENGTH = 32
TOKEN_PLACEHOLDERS = {
    "change-me",
    "development-token",
    "replace-with-a-long-random-token",
    "test-token",
}


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
    cache_max_entries: int = 32
    cache_retention_seconds: int = 7 * 24 * 60 * 60
    max_upstream_concurrency: int = 2
    failure_backoff_seconds: int = 60
    failure_backoff_max_seconds: int = 900

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
            cache_max_entries=_environment_int(
                "DAWNPILOT_CACHE_MAX_ENTRIES", 32, minimum=1, maximum=512
            ),
            cache_retention_seconds=_environment_int(
                "DAWNPILOT_CACHE_RETENTION", 7 * 24 * 60 * 60, minimum=3600
            ),
            max_upstream_concurrency=_environment_int(
                "DAWNPILOT_MAX_UPSTREAM_CONCURRENCY", 2, minimum=1, maximum=8
            ),
            failure_backoff_seconds=_environment_int(
                "DAWNPILOT_FAILURE_BACKOFF", 60, minimum=1, maximum=3600
            ),
            failure_backoff_max_seconds=_environment_int(
                "DAWNPILOT_FAILURE_BACKOFF_MAX", 900, minimum=1, maximum=86400
            ),
        )
        validate_bearer_token(config.bearer_token)
        if config.failure_backoff_max_seconds < config.failure_backoff_seconds:
            raise ConfigurationError(
                "DAWNPILOT_FAILURE_BACKOFF_MAX must be at least DAWNPILOT_FAILURE_BACKOFF"
            )
        if config.bind_host != "127.0.0.1" or config.port != 8787:
            raise ConfigurationError("bind must remain exactly 127.0.0.1:8787")
        return config


@dataclasses.dataclass
class CacheEntry:
    latitude: float
    longitude: float
    timezone: str
    stored_at: dt.datetime
    last_accessed_at: dt.datetime
    payload: dict[str, Any]

    def to_json(self) -> dict[str, Any]:
        return {
            "latitude": self.latitude,
            "longitude": self.longitude,
            "timezone": self.timezone,
            "stored_at": isoformat(self.stored_at),
            "last_accessed_at": isoformat(self.last_accessed_at),
            "payload": self.payload,
        }

    @classmethod
    def from_json(cls, value: dict[str, Any]) -> "CacheEntry":
        stored_at = parse_aware_datetime(value["stored_at"], "stored_at")
        last_accessed_at = parse_aware_datetime(
            value.get("last_accessed_at", value["stored_at"]),
            "last_accessed_at",
        )
        return cls(
            latitude=float(value["latitude"]),
            longitude=float(value["longitude"]),
            timezone=str(value["timezone"]),
            stored_at=stored_at,
            last_accessed_at=last_accessed_at,
            payload=dict(value["payload"]),
        )


@dataclasses.dataclass
class FailureState:
    attempts: int
    next_retry_at: dt.datetime


@dataclasses.dataclass
class InFlightFetch:
    event: threading.Event = dataclasses.field(default_factory=threading.Event)
    error: UpstreamError | None = None
    payload: dict[str, Any] | None = None


Fetcher = Callable[[float, float, str, int], dict[str, Any]]


class ForecastCache:
    def __init__(self, config: Config, fetcher: Fetcher | None = None) -> None:
        self.config = config
        self.fetcher = fetcher or fetch_open_meteo
        self._entries: OrderedDict[str, CacheEntry] = OrderedDict()
        self._failures: OrderedDict[str, FailureState] = OrderedDict()
        self._inflight: dict[str, InFlightFetch] = {}
        self._lock = threading.RLock()
        self._upstream_slots = threading.BoundedSemaphore(config.max_upstream_concurrency)
        self._stop_event = threading.Event()
        self._refresh_thread: threading.Thread | None = None
        self._persistence_ok = True
        self._persistence_writes_blocked = False
        self._load()

    @staticmethod
    def key(latitude: float, longitude: float, timezone: str) -> str:
        return f"{latitude:.6f},{longitude:.6f},{timezone}"

    def get(self, latitude: float, longitude: float, timezone: str) -> dict[str, Any]:
        latitude, longitude, timezone = validate_query(latitude, longitude, timezone)
        key = self.key(latitude, longitude, timezone)
        now = utc_now()
        with self._lock:
            if self._prune_locked(now):
                self._persist_locked()
            existing = self._entries.get(key)
            if existing is not None:
                existing.last_accessed_at = now
                self._entries.move_to_end(key)
                age = (now - existing.stored_at).total_seconds()
                if age <= self.config.cache_ttl_seconds:
                    return self._served_payload(existing.payload, stale=False)
                warning = self._stale_warning_locked(key, now)
                self._schedule_refresh_locked(key, existing, now)
                return self._served_payload(existing.payload, stale=True, warning=warning)

            failure = self._failures.get(key)
            if failure is not None and now < failure.next_retry_at:
                raise UpstreamError("upstream retry is temporarily deferred")

            flight = self._inflight.get(key)
            owner = flight is None
            if owner:
                flight = InFlightFetch()
                self._inflight[key] = flight

        assert flight is not None
        if owner:
            payload = self._execute_fetch(
                key,
                latitude,
                longitude,
                timezone,
                flight,
                persist=True,
            )
            return self._served_payload(payload, stale=False)

        # Keep the follower wait shorter than the app's 30-second request
        # timeout so a slow upstream produces a served error, not a client that
        # already hung up.
        wait_timeout = self.config.upstream_timeout_seconds + 5
        if not flight.event.wait(timeout=wait_timeout):
            raise UpstreamError("timed out waiting for an in-flight upstream request")
        if flight.error is not None:
            raise flight.error
        with self._lock:
            existing = self._entries.get(key)
            if existing is None:
                if flight.payload is None:
                    raise UpstreamError("in-flight upstream request produced no forecast")
                return self._served_payload(flight.payload, stale=False)
            existing.last_accessed_at = utc_now()
            self._entries.move_to_end(key)
            return self._served_payload(existing.payload, stale=False)

    def start_background_refresh(self) -> None:
        with self._lock:
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
        with self._lock:
            self._persist_locked()

    def entry_count(self) -> int:
        with self._lock:
            if self._prune_locked(utc_now()):
                self._persist_locked()
            return len(self._entries)

    def persistence_is_healthy(self) -> bool:
        with self._lock:
            return self._persistence_ok

    def _refresh_loop(self) -> None:
        while not self._stop_event.wait(self.config.refresh_interval_seconds):
            self._refresh_all_once()

    def _refresh_all_once(self) -> None:
        with self._lock:
            changed = self._prune_locked(utc_now())
            entries = list(self._entries.items())
        for key, entry in entries:
            if self._stop_event.is_set():
                break
            if self._refresh_existing(key, entry, persist=False):
                changed = True
        if changed:
            with self._lock:
                self._persist_locked()

    def _refresh_existing(self, key: str, entry: CacheEntry, persist: bool) -> bool:
        now = utc_now()
        with self._lock:
            failure = self._failures.get(key)
            if failure is not None and now < failure.next_retry_at:
                return False
            if key in self._inflight or key not in self._entries:
                return False
            flight = InFlightFetch()
            self._inflight[key] = flight
        try:
            self._execute_fetch(
                key,
                entry.latitude,
                entry.longitude,
                entry.timezone,
                flight,
                persist=persist,
            )
            return True
        except UpstreamError:
            return False

    def _schedule_refresh_locked(
        self,
        key: str,
        entry: CacheEntry,
        now: dt.datetime,
    ) -> None:
        failure = self._failures.get(key)
        if key in self._inflight or (failure is not None and now < failure.next_retry_at):
            return
        flight = InFlightFetch()
        self._inflight[key] = flight
        thread = threading.Thread(
            target=self._run_scheduled_refresh,
            args=(key, entry.latitude, entry.longitude, entry.timezone, flight),
            name="weather-cache-stale-refresh",
            daemon=True,
        )
        thread.start()

    def _run_scheduled_refresh(
        self,
        key: str,
        latitude: float,
        longitude: float,
        timezone: str,
        flight: InFlightFetch,
    ) -> None:
        try:
            self._execute_fetch(
                key,
                latitude,
                longitude,
                timezone,
                flight,
                persist=True,
            )
        except UpstreamError:
            # A stale payload remains available; backoff controls the next retry.
            return

    def _execute_fetch(
        self,
        key: str,
        latitude: float,
        longitude: float,
        timezone: str,
        flight: InFlightFetch,
        persist: bool,
    ) -> dict[str, Any]:
        error: UpstreamError | None = None
        payload: dict[str, Any] | None = None
        try:
            acquired = self._upstream_slots.acquire(
                timeout=self.config.upstream_timeout_seconds
            )
            if not acquired:
                raise UpstreamError("upstream concurrency limit is busy")
            try:
                payload = self.fetcher(
                    latitude,
                    longitude,
                    timezone,
                    self.config.upstream_timeout_seconds,
                )
                validate_normalized_forecast(
                    payload,
                    expected_timezone=timezone,
                    expected_latitude=latitude,
                    expected_longitude=longitude,
                )
            finally:
                self._upstream_slots.release()

            refreshed_at = utc_now()
            entry = CacheEntry(
                latitude=latitude,
                longitude=longitude,
                timezone=timezone,
                stored_at=refreshed_at,
                last_accessed_at=refreshed_at,
                payload=payload,
            )
            with self._lock:
                self._entries[key] = entry
                self._entries.move_to_end(key)
                self._failures.pop(key, None)
                self._prune_locked(refreshed_at)
                if persist:
                    self._persist_locked()
        except Exception as caught:
            error = caught if isinstance(caught, UpstreamError) else UpstreamError(str(caught))
            with self._lock:
                self._record_failure_locked(key, utc_now())
        finally:
            with self._lock:
                flight.error = error
                flight.payload = payload if error is None else None
                if self._inflight.get(key) is flight:
                    self._inflight.pop(key, None)
                flight.event.set()

        if error is not None:
            raise error
        assert payload is not None
        return payload

    def _record_failure_locked(self, key: str, now: dt.datetime) -> None:
        previous = self._failures.get(key)
        attempts = 1 if previous is None else previous.attempts + 1
        exponent = min(attempts - 1, 16)
        delay = min(
            self.config.failure_backoff_seconds * (2**exponent),
            self.config.failure_backoff_max_seconds,
        )
        self._failures[key] = FailureState(
            attempts=attempts,
            next_retry_at=now + dt.timedelta(seconds=delay),
        )
        self._failures.move_to_end(key)
        maximum_failure_entries = max(self.config.cache_max_entries * 2, 16)
        while len(self._failures) > maximum_failure_entries:
            self._failures.popitem(last=False)

    def _stale_warning_locked(self, key: str, now: dt.datetime) -> str | None:
        failure = self._failures.get(key)
        if failure is not None and now < failure.next_retry_at:
            return "upstream refresh is temporarily unavailable"
        return None

    def _prune_locked(self, now: dt.datetime) -> bool:
        changed = False
        expired_keys = [
            key
            for key, entry in self._entries.items()
            if (now - entry.last_accessed_at).total_seconds()
            > self.config.cache_retention_seconds
        ]
        for key in expired_keys:
            self._entries.pop(key, None)
            self._failures.pop(key, None)
            changed = True
        while len(self._entries) > self.config.cache_max_entries:
            key, _entry = self._entries.popitem(last=False)
            self._failures.pop(key, None)
            changed = True
        return changed

    def _served_payload(
        self,
        payload: dict[str, Any],
        stale: bool,
        warning: str | None = None,
    ) -> dict[str, Any]:
        result = copy.deepcopy(payload)
        result["served_at"] = isoformat(utc_now())
        result["stale"] = stale
        if warning is not None:
            result["warning"] = warning
        else:
            result.pop("warning", None)
        return result

    def _load(self) -> None:
        descriptor: int | None = None
        try:
            path_status = os.lstat(self.config.cache_file)
        except FileNotFoundError:
            return
        except OSError:
            self._persistence_ok = False
            self._persistence_writes_blocked = True
            return
        if not stat.S_ISREG(path_status.st_mode) or path_status.st_nlink != 1:
            self._persistence_ok = False
            self._persistence_writes_blocked = True
            return

        try:
            descriptor = os.open(
                self.config.cache_file,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            opened_status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened_status.st_mode)
                or opened_status.st_nlink != 1
                or opened_status.st_dev != path_status.st_dev
                or opened_status.st_ino != path_status.st_ino
            ):
                raise OSError("cache file changed while opening")
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                descriptor = None
                raw = json.load(handle)
        except (OSError, ValueError, TypeError):
            self._persistence_ok = False
            self._persistence_writes_blocked = True
            return
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

        if not isinstance(raw, dict) or raw.get("schema_version") not in (1, CACHE_SCHEMA_VERSION):
            self._persistence_ok = False
            self._persistence_writes_blocked = True
            return
        raw_entries = raw.get("entries")
        if not isinstance(raw_entries, list):
            self._persistence_ok = False
            self._persistence_writes_blocked = True
            return

        entries: list[CacheEntry] = []
        had_invalid_entry = False
        now = utc_now()
        for item in raw_entries:
            try:
                if not isinstance(item, dict):
                    raise ValueError("cache entry must be an object")
                entry = CacheEntry.from_json(item)
                latitude, longitude, timezone = validate_query(
                    entry.latitude,
                    entry.longitude,
                    entry.timezone,
                )
                if entry.stored_at > now + dt.timedelta(minutes=5):
                    raise ValueError("cache stored_at is in the future")
                if entry.last_accessed_at > now + dt.timedelta(minutes=5):
                    raise ValueError("cache last_accessed_at is in the future")
                validate_normalized_forecast(
                    entry.payload,
                    expected_timezone=timezone,
                    expected_latitude=latitude,
                    expected_longitude=longitude,
                )
                entry.latitude = latitude
                entry.longitude = longitude
                entry.timezone = timezone
                entries.append(entry)
            except (KeyError, TypeError, ValueError, UpstreamError):
                had_invalid_entry = True

        entries.sort(key=lambda item: item.last_accessed_at)
        with self._lock:
            for entry in entries:
                self._entries[
                    self.key(entry.latitude, entry.longitude, entry.timezone)
                ] = entry
            if self._prune_locked(now):
                had_invalid_entry = True
            if had_invalid_entry:
                self._persistence_ok = False

    def _persist_locked(self) -> bool:
        if self._persistence_writes_blocked:
            self._persistence_ok = False
            return False
        temporary_path: Path | None = None
        try:
            self.config.cache_file.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            data = {
                "schema_version": CACHE_SCHEMA_VERSION,
                "entries": [entry.to_json() for entry in self._entries.values()],
            }
            encoded = json.dumps(
                data,
                ensure_ascii=False,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{self.config.cache_file.name}.",
                suffix=".tmp",
                dir=self.config.cache_file.parent,
            )
            temporary_path = Path(temporary_name)
            try:
                os.fchmod(descriptor, 0o600)
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(encoded)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary_path, self.config.cache_file)
                temporary_path = None
                directory_descriptor = os.open(
                    self.config.cache_file.parent,
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                )
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
            except Exception:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                raise
            self._persistence_ok = True
            return True
        except (OSError, TypeError, ValueError):
            self._persistence_ok = False
            return False
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except OSError:
                    pass


def fetch_open_meteo(
    latitude: float,
    longitude: float,
    timezone: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    # Both requests run at once so elapsed latency stays bounded by the slower
    # request. Only the deterministic forecast is required; a failed ensemble
    # request degrades the probability source instead of losing the forecast.
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="dawnpilot-upstream") as pool:
        deterministic_request = pool.submit(
            request_deterministic_forecast,
            latitude,
            longitude,
            timezone,
            timeout_seconds,
        )
        ensemble_request = pool.submit(
            request_ensemble_probabilities,
            latitude,
            longitude,
            timezone,
            timeout_seconds,
        )
        try:
            ensemble = ensemble_request.result()
        except Exception:
            # The ensemble leg is deliberately best effort. request_open_meteo_json
            # normally wraps expected failures as UpstreamError, but malformed
            # responses or transport-library errors must not take down the
            # deterministic forecast either.
            ensemble = None
        raw = deterministic_request.result()
    return normalize_open_meteo(raw, requested_timezone=timezone, ensemble=ensemble)


def request_deterministic_forecast(
    latitude: float,
    longitude: float,
    timezone: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    return request_open_meteo_json(
        UPSTREAM_URL,
        {
            "latitude": f"{latitude:.6f}",
            "longitude": f"{longitude:.6f}",
            "timezone": timezone,
            "forecast_days": "3",
            "timeformat": "unixtime",
            "hourly": ",".join(HOURLY_FIELDS),
        },
        timeout_seconds,
    )


def request_ensemble_probabilities(
    latitude: float,
    longitude: float,
    timezone: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    raw = request_open_meteo_json(
        ENSEMBLE_URL,
        {
            "latitude": f"{latitude:.6f}",
            "longitude": f"{longitude:.6f}",
            "timezone": timezone,
            "forecast_days": "3",
            "timeformat": "unixtime",
            "hourly": ENSEMBLE_HOURLY_FIELD,
            "models": ",".join(ENSEMBLE_MODELS),
        },
        timeout_seconds,
    )
    return derive_ensemble_probabilities(raw)


def request_open_meteo_json(
    url: str,
    parameters: dict[str, str],
    timeout_seconds: int,
) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{url}?{urllib.parse.urlencode(parameters)}",
        headers={"Accept": "application/json", "User-Agent": "DawnPilot/0.1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise UpstreamError(f"Open-Meteo request failed: {error}") from error


def derive_ensemble_probabilities(raw: dict[str, Any]) -> dict[str, Any]:
    """Turn per-member precipitation into probabilities of precipitation.

    An hour's probability is the share of members that reach a rain threshold.
    `MEASURABLE_PRECIPITATION_MM` matches the definition Open-Meteo documents for
    its own probability field; `SIGNIFICANT_PRECIPITATION_MM` is the share that
    reaches rain heavy enough to change a commute. Both are computed across every
    member of every requested model.
    """
    try:
        if not isinstance(raw, dict):
            raise TypeError("ensemble response must be an object")
        hourly = raw["hourly"]
        if not isinstance(hourly, dict):
            raise TypeError("ensemble hourly must be an object")
        times = hourly["time"]
        if not isinstance(times, list) or not times:
            raise TypeError("ensemble hourly.time must be a non-empty array")
    except (KeyError, TypeError) as error:
        raise UpstreamError("Open-Meteo ensemble response is missing required fields") from error

    member_prefix = f"{ENSEMBLE_HOURLY_FIELD}_member"
    member_series: list[list[Any]] = []
    for field, values in hourly.items():
        if not field.startswith(member_prefix):
            continue
        if not isinstance(values, list) or len(values) != len(times):
            raise UpstreamError(
                f"Open-Meteo ensemble hourly.{field} must contain exactly "
                f"{len(times)} values"
            )
        member_series.append(values)

    if len(member_series) < MINIMUM_ENSEMBLE_MEMBERS:
        raise UpstreamError("Open-Meteo ensemble returned too few members")

    probabilities: dict[int, float] = {}
    significant_probabilities: dict[int, float] = {}
    previous_epoch: int | None = None
    for index, epoch in enumerate(times):
        if isinstance(epoch, bool) or not isinstance(epoch, int):
            raise UpstreamError("Open-Meteo ensemble returned an invalid hourly timestamp")
        if previous_epoch is not None and epoch <= previous_epoch:
            raise UpstreamError("Open-Meteo ensemble timestamps must be unique and ordered")
        previous_epoch = epoch

        usable = 0
        wet = 0
        significant = 0
        for values in member_series:
            value = values[index]
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise UpstreamError("Open-Meteo ensemble member values must be numeric")
            amount = float(value)
            if not math.isfinite(amount) or amount < 0:
                raise UpstreamError("Open-Meteo ensemble member values must be finite and positive")
            usable += 1
            if amount >= MEASURABLE_PRECIPITATION_MM:
                wet += 1
            if amount >= SIGNIFICANT_PRECIPITATION_MM:
                significant += 1
        if usable < MINIMUM_ENSEMBLE_MEMBERS:
            continue
        probabilities[epoch] = round(100 * wet / usable, 1)
        significant_probabilities[epoch] = round(100 * significant / usable, 1)

    if not probabilities:
        raise UpstreamError("Open-Meteo ensemble produced no usable hours")

    return {
        "probabilities": probabilities,
        "significant_probabilities": significant_probabilities,
        "member_count": len(member_series),
        "models": list(ENSEMBLE_MODELS),
    }


def normalize_open_meteo(
    raw: dict[str, Any],
    requested_timezone: str,
    ensemble: dict[str, Any] | None = None,
) -> dict[str, Any]:
    try:
        if not isinstance(raw, dict):
            raise TypeError("response must be an object")
        hourly = raw["hourly"]
        if not isinstance(hourly, dict):
            raise TypeError("hourly must be an object")
        times = hourly["time"]
        if not isinstance(times, list) or not times:
            raise TypeError("hourly.time must be a non-empty array")
        zone = ZoneInfo(requested_timezone)
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError) as error:
        raise UpstreamError("Open-Meteo response is missing required fields") from error

    for field in HOURLY_FIELDS:
        values = hourly.get(field)
        if not isinstance(values, list) or len(values) != len(times):
            raise UpstreamError(
                f"Open-Meteo hourly.{field} must contain exactly {len(times)} values"
            )

    # An hour keeps its deterministic probability unless the ensemble covers the
    # whole timeline, so one payload never mixes two probability definitions.
    ensemble_probabilities: dict[int, float] = {}
    ensemble_significant: dict[int, float] = {}
    if isinstance(ensemble, dict):
        candidate = ensemble.get("probabilities")
        significant_candidate = ensemble.get("significant_probabilities")
        if (
            isinstance(candidate, dict)
            and isinstance(significant_candidate, dict)
            and all(
                isinstance(local_time, int)
                and not isinstance(local_time, bool)
                and local_time in candidate
                and local_time in significant_candidate
                for local_time in times
            )
        ):
            ensemble_probabilities = candidate
            ensemble_significant = significant_candidate

    rows: list[dict[str, Any]] = []
    previous_instant: dt.datetime | None = None
    for index, local_time in enumerate(times):
        try:
            parsed = normalize_hourly_time(local_time, zone)
        except ValueError as error:
            raise UpstreamError("Open-Meteo returned an invalid hourly timestamp") from error
        instant = parsed.astimezone(dt.timezone.utc)
        if previous_instant is not None and instant <= previous_instant:
            raise UpstreamError("Open-Meteo hourly timestamps must be unique and ordered")
        previous_instant = instant
        row = {
            "time": isoformat(parsed),
            "precipitation_probability": require_number(
                ensemble_probabilities.get(
                    local_time,
                    hourly["precipitation_probability"][index],
                )
                if ensemble_probabilities
                else hourly["precipitation_probability"][index],
                "hourly.precipitation_probability",
                minimum=0,
                maximum=100,
            ),
            "precipitation_mm": require_number(
                hourly["precipitation"][index],
                "hourly.precipitation",
                minimum=0,
            ),
            "rain_mm": require_number(
                hourly["rain"][index],
                "hourly.rain",
                minimum=0,
            ),
            "showers_mm": require_number(
                hourly["showers"][index],
                "hourly.showers",
                minimum=0,
            ),
            "snowfall_cm": require_number(
                hourly["snowfall"][index],
                "hourly.snowfall",
                minimum=0,
            ),
            "weather_code": require_integer(
                hourly["weather_code"][index],
                "hourly.weather_code",
                minimum=0,
                maximum=99,
            ),
        }
        # Only present when the ensemble covers the timeline. The app treats a
        # missing value as "unknown" and stays on the more cautious old rule.
        if ensemble_significant:
            row["precipitation_probability_significant"] = require_number(
                ensemble_significant[local_time],
                "hourly.precipitation_probability_significant",
                minimum=0,
                maximum=100,
            )
        rows.append(row)

    fetched_at = utc_now()
    payload = {
        "schema_version": FORECAST_SCHEMA_VERSION,
        "source": "open-meteo",
        "fetched_at": isoformat(fetched_at),
        "served_at": isoformat(fetched_at),
        "stale": False,
        "latitude": require_number(
            raw.get("latitude"),
            "latitude",
            minimum=-90,
            maximum=90,
        ),
        "longitude": require_number(
            raw.get("longitude"),
            "longitude",
            minimum=-180,
            maximum=180,
        ),
        "timezone": requested_timezone,
        # Informational only: older app builds ignore unknown fields, and the
        # forecast schema itself is unchanged.
        "probability_source": (
            PROBABILITY_SOURCE_ENSEMBLE
            if ensemble_probabilities
            else PROBABILITY_SOURCE_DETERMINISTIC
        ),
        "ensemble_member_count": (
            int(ensemble.get("member_count", 0))
            if ensemble_probabilities and isinstance(ensemble, dict)
            else 0
        ),
        "ensemble_models": (
            list(ensemble.get("models", []))
            if ensemble_probabilities and isinstance(ensemble, dict)
            else []
        ),
        "hourly": rows,
    }
    validate_normalized_forecast(payload, expected_timezone=requested_timezone)
    return payload


def normalize_hourly_time(value: Any, zone: ZoneInfo) -> dt.datetime:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("hourly timestamp must be an integer Unix epoch")
    try:
        parsed = dt.datetime.fromtimestamp(value, tz=dt.timezone.utc).astimezone(zone)
    except (OverflowError, OSError, ValueError) as error:
        raise ValueError("hourly timestamp is outside the supported range") from error
    if parsed.minute != 0 or parsed.second != 0 or parsed.microsecond != 0:
        raise ValueError("hourly timestamp must be aligned to an hour")
    return parsed


def validate_normalized_forecast(
    payload: dict[str, Any],
    expected_timezone: str | None = None,
    expected_latitude: float | None = None,
    expected_longitude: float | None = None,
) -> None:
    if not isinstance(payload, dict):
        raise UpstreamError("normalized forecast must be an object")
    schema_version = payload.get("schema_version")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != FORECAST_SCHEMA_VERSION
    ):
        raise UpstreamError("normalized forecast has an unsupported schema version")
    if not isinstance(payload.get("source"), str) or not payload["source"].strip():
        raise UpstreamError("normalized forecast source must be non-empty")
    try:
        fetched_at = parse_aware_datetime(payload["fetched_at"], "fetched_at")
        served_at = parse_aware_datetime(payload["served_at"], "served_at")
    except (KeyError, TypeError, ValueError) as error:
        raise UpstreamError("normalized forecast timestamps are invalid") from error
    if served_at < fetched_at:
        raise UpstreamError("normalized forecast served_at precedes fetched_at")
    if payload.get("stale") is not False:
        raise UpstreamError("a newly cached normalized forecast must not be stale")

    latitude = require_number(
        payload.get("latitude"),
        "latitude",
        minimum=-90,
        maximum=90,
    )
    longitude = require_number(
        payload.get("longitude"),
        "longitude",
        minimum=-180,
        maximum=180,
    )
    if expected_latitude is not None:
        if abs(latitude - expected_latitude) > MAXIMUM_COORDINATE_DRIFT_DEGREES:
            raise UpstreamError("normalized forecast latitude does not match the request")
    if expected_longitude is not None:
        longitude_delta = abs(longitude - expected_longitude)
        longitude_delta = min(longitude_delta, 360 - longitude_delta)
        if longitude_delta > MAXIMUM_COORDINATE_DRIFT_DEGREES:
            raise UpstreamError("normalized forecast longitude does not match the request")
    timezone = payload.get("timezone")
    if not isinstance(timezone, str) or not timezone:
        raise UpstreamError("normalized forecast timezone is invalid")
    try:
        ZoneInfo(timezone)
    except (ValueError, ZoneInfoNotFoundError) as error:
        raise UpstreamError("normalized forecast timezone is invalid") from error
    if expected_timezone is not None and timezone != expected_timezone:
        raise UpstreamError("normalized forecast timezone does not match the request")

    hourly = payload.get("hourly")
    if not isinstance(hourly, list) or not hourly:
        raise UpstreamError("normalized forecast hourly must be a non-empty array")
    previous_instant: dt.datetime | None = None
    for index, row in enumerate(hourly):
        if not isinstance(row, dict):
            raise UpstreamError(f"normalized forecast hourly[{index}] must be an object")
        try:
            timestamp = parse_aware_datetime(row["time"], f"hourly[{index}].time")
        except (KeyError, TypeError, ValueError) as error:
            raise UpstreamError(
                f"normalized forecast hourly[{index}] has an invalid timestamp"
            ) from error
        if timestamp.minute != 0 or timestamp.second != 0 or timestamp.microsecond != 0:
            raise UpstreamError(
                f"normalized forecast hourly[{index}] is not aligned to an hour"
            )
        instant = timestamp.astimezone(dt.timezone.utc)
        if previous_instant is not None and instant <= previous_instant:
            raise UpstreamError(
                "normalized forecast hourly timestamps must be unique and ordered"
            )
        previous_instant = instant
        require_number(
            row.get("precipitation_probability"),
            f"hourly[{index}].precipitation_probability",
            minimum=0,
            maximum=100,
        )
        for field in ("precipitation_mm", "rain_mm", "showers_mm", "snowfall_cm"):
            require_number(row.get(field), f"hourly[{index}].{field}", minimum=0)
        require_integer(
            row.get("weather_code"),
            f"hourly[{index}].weather_code",
            minimum=0,
            maximum=99,
        )
        if "precipitation_probability_significant" in row:
            require_number(
                row.get("precipitation_probability_significant"),
                f"hourly[{index}].precipitation_probability_significant",
                minimum=0,
                maximum=100,
            )


def require_number(
    value: Any,
    field: str,
    minimum: float | None = None,
    maximum: float | None = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise UpstreamError(f"{field} must be numeric")
    number = float(value)
    if not math.isfinite(number):
        raise UpstreamError(f"{field} must be finite")
    if minimum is not None and number < minimum:
        raise UpstreamError(f"{field} is below the supported range")
    if maximum is not None and number > maximum:
        raise UpstreamError(f"{field} is above the supported range")
    return number


def require_integer(
    value: Any,
    field: str,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise UpstreamError(f"{field} must be an integer")
    if minimum is not None and value < minimum:
        raise UpstreamError(f"{field} is below the supported range")
    if maximum is not None and value > maximum:
        raise UpstreamError(f"{field} is above the supported range")
    return value


def parse_aware_datetime(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str):
        raise TypeError(f"{field} must be an ISO-8601 string")
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"{field} must include a timezone offset")
    return parsed


def validate_query(latitude: float, longitude: float, timezone: str) -> tuple[float, float, str]:
    if (
        isinstance(latitude, bool)
        or not isinstance(latitude, (int, float))
        or not math.isfinite(latitude)
    ):
        raise ValueError("latitude must be a finite number")
    if (
        isinstance(longitude, bool)
        or not isinstance(longitude, (int, float))
        or not math.isfinite(longitude)
    ):
        raise ValueError("longitude must be a finite number")
    if not -90 <= latitude <= 90:
        raise ValueError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise ValueError("longitude must be between -180 and 180")
    if not isinstance(timezone, str) or not timezone:
        raise ValueError("timezone must be a non-empty IANA identifier")
    try:
        ZoneInfo(timezone)
    except (ValueError, ZoneInfoNotFoundError) as error:
        raise ValueError("unknown timezone") from error
    return round(latitude, 6), round(longitude, 6), timezone


def create_handler(cache: ForecastCache, config: Config) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "DawnPilotServer/0.1"

        def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/healthz":
                persistence_ok = cache.persistence_is_healthy()
                self._send_json(
                    HTTPStatus.OK if persistence_ok else HTTPStatus.SERVICE_UNAVAILABLE,
                    {"status": "ok" if persistence_ok else "degraded"},
                )
                return
            if parsed.path != "/v1/forecast":
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if not self._authorized():
                self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                return

            try:
                query = urllib.parse.parse_qs(parsed.query, max_num_fields=10)
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
            del format_string
            route = urllib.parse.urlparse(self.path).path
            status = str(args[1]) if len(args) > 1 else "-"
            print(
                f"{self.client_address[0]} {self.command} {route} {status}",
                flush=True,
            )

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


class DawnPilotHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16


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


def validate_bearer_token(token: str) -> None:
    if not isinstance(token, str) or not token:
        raise ConfigurationError("DAWNPILOT_TOKEN must not be empty")
    if token != token.strip() or any(character.isspace() for character in token):
        raise ConfigurationError("DAWNPILOT_TOKEN must not contain whitespace")
    if len(token) < MINIMUM_TOKEN_LENGTH:
        raise ConfigurationError(
            f"DAWNPILOT_TOKEN must contain at least {MINIMUM_TOKEN_LENGTH} characters"
        )
    if token.lower() in TOKEN_PLACEHOLDERS or token.lower().startswith(
        ("replace-", "change-me")
    ):
        raise ConfigurationError("DAWNPILOT_TOKEN must not use a known placeholder")
    if len(set(token)) < 8:
        raise ConfigurationError("DAWNPILOT_TOKEN has insufficient character diversity")
    maximum_period = min(16, len(token) // 2)
    for period in range(1, maximum_period + 1):
        if len(token) % period == 0 and token == token[:period] * (len(token) // period):
            raise ConfigurationError("DAWNPILOT_TOKEN must not be a repeated pattern")
def main() -> None:
    config = Config.from_environment()
    cache = ForecastCache(config)
    cache.start_background_refresh()
    server = DawnPilotHTTPServer(
        (config.bind_host, config.port),
        create_handler(cache, config),
    )

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
