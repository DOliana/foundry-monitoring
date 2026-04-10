import azure.functions as func
import logging

from functions import quota_snapshot, deployment_config, token_usage, model_catalog

app = func.FunctionApp()


@app.timer_trigger(schedule="0 20 * * * *", arg_name="timer", run_on_startup=False)
async def fn_quota_snapshot(timer: func.TimerRequest) -> None:
    """Collect quota snapshots hourly (at :20, 15-min delay for finalization)."""
    if timer.past_due:
        logging.warning("fn_quota_snapshot is past due")
    await quota_snapshot.run()


@app.timer_trigger(schedule="0 5 * * * *", arg_name="timer", run_on_startup=False)
async def fn_deployment_config(timer: func.TimerRequest) -> None:
    """Collect deployment configurations hourly (at :05)."""
    if timer.past_due:
        logging.warning("fn_deployment_config is past due")
    await deployment_config.run()


@app.timer_trigger(schedule="0 35 * * * *", arg_name="timer", run_on_startup=False)
async def fn_token_usage(timer: func.TimerRequest) -> None:
    """Collect token usage metrics hourly (at :35, 30-min delay for finalization)."""
    if timer.past_due:
        logging.warning("fn_token_usage is past due")
    await token_usage.run()


@app.timer_trigger(schedule="0 0 6 * * *", arg_name="timer", run_on_startup=False)
async def fn_model_catalog(timer: func.TimerRequest) -> None:
    """Collect available models from the model catalog daily (at 06:00 UTC)."""
    if timer.past_due:
        logging.warning("fn_model_catalog is past due")
    await model_catalog.run()