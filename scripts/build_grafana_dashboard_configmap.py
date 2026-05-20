#!/usr/bin/env python3
"""Generate Grafana dashboard ConfigMap YAML from dashboard JSON.

The JSON dashboard file is the single source of truth. This script embeds it
into a Kubernetes ConfigMap with the grafana_dashboard=1 label watched by the
kube-prometheus-stack Grafana sidecar.

It supports both:
  - classic Grafana dashboard JSON
  - Grafana dashboard.grafana.app/v2 export JSON

The sidecar provisioning path expects classic dashboard JSON, so v2 exports are
converted before being embedded into the ConfigMap.

Important provisioning rules enforced here:
  - never keep Grafana's exported numeric dashboard id
  - always emit id: null
  - use a stable dashboard uid
  - strip folder UID metadata exported from another Grafana instance
  - strip dashboard.grafana.app/v2 wrapper fields
"""

from __future__ import annotations

import argparse
import copy
import json
import re
from pathlib import Path
from typing import Any


DEFAULT_SOURCE = Path("k8s/observability/dashboards/otp-relay-live.json")
DEFAULT_OUTPUT = Path("k8s/observability/grafana-dashboard-otp-relay-live.yaml")
DEFAULT_CONFIGMAP_NAME = "otp-relay-live-dashboard"
DEFAULT_NAMESPACE = "observability"
DEFAULT_KEY = "otp-relay-live.json"
DEFAULT_DASHBOARD_UID = "otp-relay-live"


def _indent_literal_block(text: str, spaces: int = 4) -> str:
    prefix = " " * spaces
    return "".join(prefix + line if line.strip() else "\n" for line in text.splitlines(True))


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _drop_none(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if item is not None}


def _stable_uid(*candidates: Any) -> str:
    """Return a safe, stable Grafana dashboard UID.

    Grafana's database/provisioning path must not receive an exported numeric
    dashboard id. For this repo we prefer the source object name
    "otp-relay-live", falling back to a sanitized candidate only if needed.
    """

    for candidate in candidates:
        if not isinstance(candidate, str):
            continue

        value = candidate.strip()
        if not value:
            continue

        # Do not use long UUIDs or integer-like exported identifiers as the UID.
        if re.fullmatch(r"\d+", value):
            continue
        if len(value) > 40:
            continue

        value = re.sub(r"[^A-Za-z0-9_-]+", "-", value).strip("-")
        if value:
            return value[:40]

    return DEFAULT_DASHBOARD_UID


def _sanitize_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    metadata = copy.deepcopy(metadata)

    annotations = metadata.get("annotations")
    if isinstance(annotations, dict):
        for key in [
            "grafana.app/folder",
            "grafana.app/folderTitle",
            "grafana.app/folderUrl",
            "grafana.app/createdBy",
            "grafana.app/updatedBy",
            "grafana.app/updatedTimestamp",
            "grafana.app/saved-from-ui",
        ]:
            annotations.pop(key, None)

        if not annotations:
            metadata.pop("annotations", None)

    labels = metadata.get("labels")
    if isinstance(labels, dict):
        labels.pop("grafana.app/deprecatedInternalID", None)
        if not labels:
            metadata.pop("labels", None)

    for key in [
        "resourceVersion",
        "generation",
        "creationTimestamp",
        "managedFields",
        "selfLink",
    ]:
        metadata.pop(key, None)

    return metadata


def _convert_time_settings(spec: dict[str, Any]) -> tuple[dict[str, str], str | None, str | None]:
    time_settings = _as_dict(spec.get("timeSettings"))
    classic_time = _as_dict(spec.get("time"))

    time_range = {
        "from": str(
            time_settings.get("from")
            or time_settings.get("fromNow")
            or classic_time.get("from")
            or "now-6h"
        ),
        "to": str(
            time_settings.get("to")
            or classic_time.get("to")
            or "now"
        ),
    }

    refresh = (
        time_settings.get("autoRefresh")
        or time_settings.get("refresh")
        or spec.get("refresh")
    )
    timezone = (
        time_settings.get("timezone")
        or spec.get("timezone")
    )

    return time_range, str(refresh) if refresh else None, str(timezone) if timezone else None


def _convert_timepicker_settings(spec: dict[str, Any]) -> dict[str, Any]:
    """Convert Grafana v2 timeSettings metadata into classic dashboard timepicker.

    Provisioned classic dashboards can carry refresh="15s" without exposing the
    expected refresh choices in the UI unless the timepicker metadata is also
    present. Preserve the v2 autoRefreshIntervals list so 15s is available and
    selected consistently after provisioning.
    """

    time_settings = _as_dict(spec.get("timeSettings"))
    classic_timepicker = _as_dict(spec.get("timepicker"))

    refresh_intervals = _as_list(
        time_settings.get("autoRefreshIntervals")
        or classic_timepicker.get("refresh_intervals")
    )
    if not refresh_intervals:
        refresh_intervals = [
            "5s",
            "10s",
            "15s",
            "30s",
            "1m",
            "5m",
            "15m",
            "30m",
            "1h",
        ]

    time_options = _as_list(classic_timepicker.get("time_options"))
    if not time_options:
        time_options = [
            "5m",
            "15m",
            "1h",
            "6h",
            "12h",
            "24h",
            "2d",
            "7d",
            "30d",
        ]

    timepicker = {
        "refresh_intervals": [str(value) for value in refresh_intervals],
        "time_options": [str(value) for value in time_options],
    }

    hide_timepicker = time_settings.get("hideTimepicker")
    if hide_timepicker is not None:
        timepicker["hidden"] = bool(hide_timepicker)
    elif "hidden" in classic_timepicker:
        timepicker["hidden"] = bool(classic_timepicker.get("hidden"))

    return timepicker


def _annotation_to_classic(annotation: dict[str, Any], index: int) -> dict[str, Any]:
    annotation_spec = _as_dict(annotation.get("spec"))
    query = _as_dict(annotation_spec.get("query"))
    query_spec = _as_dict(query.get("spec"))

    classic = copy.deepcopy(query_spec) if query_spec else {}
    classic.update(
        _drop_none(
            {
                "name": annotation_spec.get("name") or f"Annotation {index}",
                "enable": annotation_spec.get("enable", True),
                "hide": annotation_spec.get("hide", True),
                "iconColor": annotation_spec.get("iconColor"),
                "type": "dashboard",
                "builtIn": 1 if index == 1 else 0,
            }
        )
    )

    datasource = _as_dict(query.get("datasource"))
    if datasource:
        classic["datasource"] = _drop_none(
            {
                "type": datasource.get("type"),
                "uid": datasource.get("uid"),
            }
        ) or datasource.get("name")

    return classic


def _layout_items_by_element(spec: dict[str, Any]) -> dict[str, dict[str, int]]:
    layout = _as_dict(spec.get("layout"))
    layout_spec = _as_dict(layout.get("spec"))
    items = _as_list(layout_spec.get("items"))

    positions: dict[str, dict[str, int]] = {}

    for item in items:
        item_spec = _as_dict(_as_dict(item).get("spec"))
        element = _as_dict(item_spec.get("element"))
        name = element.get("name")
        if not isinstance(name, str):
            continue

        positions[name] = {
            "x": int(item_spec.get("x", 0) or 0),
            "y": int(item_spec.get("y", 0) or 0),
            "w": int(item_spec.get("width", item_spec.get("w", 12)) or 12),
            "h": int(item_spec.get("height", item_spec.get("h", 8)) or 8),
        }

    return positions


def _query_to_target(query: dict[str, Any], index: int) -> dict[str, Any]:
    query_spec = _as_dict(query.get("spec"))
    data_query = _as_dict(query_spec.get("query"))
    data_query_spec = _as_dict(data_query.get("spec"))

    target = copy.deepcopy(data_query_spec) if data_query_spec else copy.deepcopy(query_spec)
    target.setdefault("refId", query_spec.get("refId") or chr(ord("A") + index))

    datasource = _as_dict(data_query.get("datasource")) or _as_dict(target.get("datasource"))
    if datasource:
        target["datasource"] = _drop_none(
            {
                "type": datasource.get("type"),
                "uid": datasource.get("uid"),
            }
        ) or datasource

    return target


def _panel_type_from_viz_config(viz_config: dict[str, Any], element_spec: dict[str, Any]) -> str:
    """Return a real Grafana panel plugin id.

    Grafana v2 exports use vizConfig.kind="VizConfig", which is a wrapper kind,
    not a renderable panel plugin. The actual plugin is normally in
    vizConfig.spec.pluginId. File provisioning must receive plugin ids such as
    stat, timeseries, gauge, table, logs, or text.
    """

    viz_spec = _as_dict(viz_config.get("spec"))

    candidates = [
        viz_config.get("group"),
        viz_spec.get("pluginId"),
        viz_spec.get("type"),
        viz_spec.get("kind"),
        element_spec.get("type"),
    ]

    aliases = {
        "timeseries": "timeseries",
        "time-series": "timeseries",
        "time series": "timeseries",
        "stat": "stat",
        "gauge": "gauge",
        "bargauge": "bargauge",
        "bar-gauge": "bargauge",
        "bar gauge": "bargauge",
        "table": "table",
        "logs": "logs",
        "log": "logs",
        "text": "text",
        "row": "row",
    }

    invalid_wrapper_types = {
        "vizconfig",
        "viz-config",
        "viz config",
        "panel",
    }

    for candidate in candidates:
        if not isinstance(candidate, str):
            continue

        value = candidate.strip()
        if not value:
            continue

        normalized = value.lower()
        if normalized in invalid_wrapper_types:
            continue

        return aliases.get(normalized, normalized)

    # Safe fallback: every supported Grafana install has timeseries.
    return "timeseries"




def _panel_to_classic(
    name: str,
    element: dict[str, Any],
    grid_pos: dict[str, int],
    panel_id: int,
) -> dict[str, Any]:
    element_spec = _as_dict(element.get("spec"))
    viz_config = _as_dict(element_spec.get("vizConfig"))
    viz_spec = _as_dict(viz_config.get("spec"))
    data = _as_dict(element_spec.get("data"))
    data_spec = _as_dict(data.get("spec"))

    targets = [
        _query_to_target(query, index)
        for index, query in enumerate(_as_list(data_spec.get("queries")))
        if isinstance(query, dict)
    ]

    panel = {
        "id": panel_id,
        "title": element_spec.get("title") or name,
        "type": _panel_type_from_viz_config(viz_config, element_spec),
        "gridPos": grid_pos,
        "targets": targets,
        "fieldConfig": viz_spec.get("fieldConfig", {"defaults": {}, "overrides": []}),
        "options": viz_spec.get("options", {}),
    }

    datasource = element_spec.get("datasource")
    if datasource is None and targets:
        datasource = targets[0].get("datasource")
    if datasource is not None:
        panel["datasource"] = datasource

    for optional_key in [
        "description",
        "transparent",
        "links",
        "repeat",
        "repeatDirection",
        "maxPerRow",
        "pluginVersion",
    ]:
        if optional_key in element_spec:
            panel[optional_key] = element_spec[optional_key]

    return panel


def _convert_v2_dashboard_to_classic(dashboard: dict[str, Any]) -> dict[str, Any]:
    metadata = _sanitize_metadata(_as_dict(dashboard.get("metadata")))
    spec = copy.deepcopy(_as_dict(dashboard.get("spec")))

    time_range, refresh, timezone = _convert_time_settings(spec)
    positions = _layout_items_by_element(spec)
    elements = _as_dict(spec.get("elements"))

    def panel_sort_key(name: str) -> tuple[int, int, str]:
        pos = positions.get(name, {})
        return (
            int(pos.get("y", 999999)),
            int(pos.get("x", 999999)),
            name,
        )

    panels: list[dict[str, Any]] = []
    for panel_id, name in enumerate(sorted(elements.keys(), key=panel_sort_key), start=1):
        element = _as_dict(elements.get(name))
        if element.get("kind") != "Panel":
            continue

        grid_pos = positions.get(name, {"x": 0, "y": (panel_id - 1) * 8, "w": 12, "h": 8})
        panels.append(_panel_to_classic(name, element, grid_pos, panel_id))

    annotations = [
        _annotation_to_classic(annotation, index)
        for index, annotation in enumerate(_as_list(spec.get("annotations")), start=1)
        if isinstance(annotation, dict)
    ]

    dashboard_uid = _stable_uid(
        metadata.get("name"),
        spec.get("uid"),
        metadata.get("uid"),
        DEFAULT_DASHBOARD_UID,
    )

    classic = {
        # Critical for provisioning: never persist an exported Grafana DB id.
        "id": None,
        "uid": dashboard_uid,
        "title": spec.get("title") or metadata.get("name") or "OTP Relay",
        "tags": spec.get("tags", []),
        "timezone": timezone or "browser",
        "schemaVersion": spec.get("schemaVersion", 39),
        "version": 1,
        "refresh": refresh or "15s",
        "time": time_range,
        "timepicker": _convert_timepicker_settings(spec),
        "annotations": {"list": annotations},
        "panels": panels,
        "editable": spec.get("editable", True),
        "graphTooltip": spec.get("graphTooltip", 0),
        "weekStart": _as_dict(spec.get("timeSettings")).get("weekStart", spec.get("weekStart", "")),
        "fiscalYearStartMonth": (
            _as_dict(spec.get("timeSettings")).get(
                "fiscalYearStartMonth",
                spec.get("fiscalYearStartMonth", 0),
            )
        ),
    }

    if "description" in spec:
        classic["description"] = spec["description"]
    if "templating" in spec:
        classic["templating"] = spec["templating"]
    if "links" in spec:
        classic["links"] = spec["links"]

    return classic


def _sanitize_classic_dashboard(dashboard: dict[str, Any]) -> dict[str, Any]:
    """Make an already-classic Grafana dashboard safe for sidecar provisioning."""

    dashboard = copy.deepcopy(dashboard)

    # These are wrappers/export metadata, not valid persisted dashboard fields for
    # file provisioning.
    for key in [
        "apiVersion",
        "kind",
        "metadata",
        "meta",
        "status",
        "__inputs",
        "__requires",
    ]:
        dashboard.pop(key, None)

    # Critical for provisioning: never carry Grafana's exported numeric DB id.
    dashboard["id"] = None

    dashboard["uid"] = _stable_uid(
        dashboard.get("uid"),
        dashboard.get("title"),
        DEFAULT_DASHBOARD_UID,
    )

    # Folder identity from another Grafana instance can break the provider.
    for key in ["folderId", "folderUid", "folderTitle", "folderUrl"]:
        dashboard.pop(key, None)

    dashboard["refresh"] = str(dashboard.get("refresh") or "15s")
    dashboard.setdefault("time", {"from": "now-6h", "to": "now"})
    dashboard["timepicker"] = _convert_timepicker_settings(dashboard)

    for panel in _as_list(dashboard.get("panels")):
        if not isinstance(panel, dict):
            continue
        panel_type = panel.get("type")
        if isinstance(panel_type, str) and panel_type.strip().lower() in {"vizconfig", "viz-config", "viz config"}:
            panel["type"] = "timeseries"

    # Keep generated diffs stable and avoid stale optimistic-lock versions.
    dashboard["version"] = 1

    return dashboard


def _sanitize_dashboard(dashboard: dict[str, Any]) -> dict[str, Any]:
    """Return sidecar-compatible classic dashboard JSON."""

    dashboard = copy.deepcopy(dashboard)

    if (
        isinstance(dashboard.get("apiVersion"), str)
        and dashboard.get("apiVersion", "").startswith("dashboard.grafana.app/")
        and dashboard.get("kind") == "Dashboard"
        and isinstance(dashboard.get("spec"), dict)
    ):
        return _convert_v2_dashboard_to_classic(dashboard)

    return _sanitize_classic_dashboard(dashboard)


def build_configmap_yaml(
    source: Path,
    name: str,
    namespace: str,
    key: str,
) -> str:
    try:
        dashboard = json.loads(source.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Dashboard JSON not found: {source}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Dashboard JSON is invalid: {source}: {exc}") from exc

    dashboard = _sanitize_dashboard(dashboard)

    # Normalize formatting so generated YAML diffs are stable.
    dashboard_json = json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n"
    embedded = _indent_literal_block(dashboard_json, spaces=4)

    return (
        "apiVersion: v1\n"
        "kind: ConfigMap\n"
        "metadata:\n"
        f"  name: {name}\n"
        f"  namespace: {namespace}\n"
        "  labels:\n"
        '    grafana_dashboard: "1"\n'
        "data:\n"
        f"  {key}: |\n"
        f"{embedded}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=str(DEFAULT_SOURCE), help="Dashboard JSON source file")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Generated ConfigMap YAML output file")
    parser.add_argument("--name", default=DEFAULT_CONFIGMAP_NAME, help="ConfigMap name")
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE, help="ConfigMap namespace")
    parser.add_argument("--key", default=DEFAULT_KEY, help="ConfigMap data key")
    args = parser.parse_args()

    source = Path(args.source)
    output = Path(args.output)

    yaml_text = build_configmap_yaml(
        source=source,
        name=args.name,
        namespace=args.namespace,
        key=args.key,
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(yaml_text, encoding="utf-8")
    print(f"Generated {output} from {source}")


if __name__ == "__main__":
    main()
