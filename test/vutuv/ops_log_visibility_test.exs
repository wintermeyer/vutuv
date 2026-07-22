defmodule Vutuv.OpsLogVisibilityTest do
  @moduledoc """
  Production runs the global Logger at :error (config/prod.exs) to keep the
  journal quiet - which used to swallow the email-deliverability ops alarms
  entirely: the watcher's policy-bounce warning (our SPF/DKIM may be broken),
  its startup line (the only liveness signal), the DSN webhook's bounce lines
  and the emailer's dropped-mail warnings. `Vutuv.Application` raises exactly
  those modules to :info via per-module log levels at boot; this covers the
  override so the alarms can never go silent again.
  """
  use ExUnit.Case, async: false

  @modules [
    Vutuv.Deliverability.Watcher,
    Vutuv.Deliverability.Sweeper,
    Vutuv.Notifications.Bounces,
    Vutuv.Notifications.Emailer
  ]

  test "ensure_ops_logs_visible/0 raises the deliverability modules to :info" do
    # The flag is off in test config (the suite wants the quiet :warning
    # default), so app start has not applied the override - apply and clean
    # up here.
    refute Application.get_env(:vutuv, :ops_log_visibility)
    on_exit(fn -> Logger.delete_module_level(@modules) end)

    assert :ok = Vutuv.Application.ensure_ops_logs_visible()

    for mod <- @modules do
      assert :logger.get_module_level(mod) == [{mod, :info}]
    end
  end

  test "the override is config-gated so tests keep the global level" do
    # Guards that nobody flips the test flag on by accident: with it off, no
    # module carries an override after boot.
    for mod <- @modules do
      assert :logger.get_module_level(mod) == []
    end
  end
end
