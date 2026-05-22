"""Prometheus metrics for the OTP Relay monitor."""

from prometheus_client import Counter, Gauge, Histogram

OTP_IPHONE_PRESENT = Gauge(
    "otp_iphone_present",
    "Whether the monitored iPhone is currently reachable by ARP",
)
OTP_IPHONE_ABSENCE_SECONDS = Gauge(
    "otp_iphone_absence_seconds",
    "Current iPhone absence duration in seconds; zero while the phone is reachable",
)
OTP_IPHONE_ABSENCE_EVENTS_TOTAL = Counter(
    "otp_iphone_absence_events_total",
    "Total number of iPhone absence events detected by the monitor",
)
OTP_IPHONE_ABSENCE_DURATION_SECONDS = Histogram(
    "otp_iphone_absence_duration_seconds",
    "Duration in seconds of completed iPhone absence events",
)
OTP_MONITOR_ARP_LAST_SUCCESS_TIMESTAMP_SECONDS = Gauge(
    "otp_monitor_arp_last_success_timestamp_seconds",
    "Unix timestamp of the last successful ARP check",
)
