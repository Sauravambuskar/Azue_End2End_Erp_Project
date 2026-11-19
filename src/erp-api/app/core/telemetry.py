"""OpenTelemetry -> Azure Monitor / Application Insights wiring."""
import logging

from app.core.config import get_settings

log = logging.getLogger(__name__)


def configure_telemetry(app) -> None:  # noqa: ANN001
    settings = get_settings()
    if not settings.appinsights_connection_string:
        log.info("App Insights connection string absent - telemetry disabled")
        return
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        configure_azure_monitor(
            connection_string=settings.appinsights_connection_string,
            logger_name="erp",
        )
        FastAPIInstrumentor.instrument_app(app)
        log.info("Azure Monitor OpenTelemetry configured")
    except Exception:  # pragma: no cover - never crash the app on telemetry
        log.exception("Failed to configure Azure Monitor")
