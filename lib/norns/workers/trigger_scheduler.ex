defmodule Norns.Workers.TriggerScheduler do
  @moduledoc """
  Minutely Oban job that fires due cron triggers.

  The Cron plugin enqueues this every minute (`config.exs`); the actual
  per-trigger dedupe lives in `Norns.Triggers.fire_due/1`, so an overlapping
  or retried job cannot double-fire. `max_attempts: 1` — a missed minute is
  a missed firing, not something to replay late against a fresh minute.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Norns.Triggers

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    minute = %{DateTime.utc_now() | second: 0, microsecond: {0, 6}}
    {_fired, _skipped} = Triggers.fire_due(minute)
    :ok
  end
end
