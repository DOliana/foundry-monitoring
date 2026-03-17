"""Singleton client instances for Azure services."""

import os

from azure.data.tables import TableClient
from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient

_credential = None
_ingestion_client = None
_watermark_client = None


def get_credential() -> DefaultAzureCredential:
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    return _credential


def get_ingestion_client() -> LogsIngestionClient:
    global _ingestion_client
    if _ingestion_client is None:
        _ingestion_client = LogsIngestionClient(
            endpoint=os.environ["DCE_ENDPOINT"],
            credential=get_credential(),
        )
    return _ingestion_client


def get_watermark_client() -> TableClient:
    global _watermark_client
    if _watermark_client is None:
        _watermark_client = TableClient(
            endpoint=os.environ["WATERMARK_STORAGE_ENDPOINT"],
            table_name=os.environ.get("WATERMARK_TABLE_NAME", "watermarks"),
            credential=get_credential(),
        )
    return _watermark_client
