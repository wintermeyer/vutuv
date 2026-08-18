defmodule Vutuv.OpsLogVisibilityTest do
  @moduledoc """
  Production runs the global Logger at :error (config/prod.exs) to keep the
  journal quiet - which used to swallow the email-deliverability ops alarms
  entirely: the watcher's policy-bounce warning (our SPF/DKIM may be broken),
  its startup line (the only liveness signal), the DSN webhook's bounce lines
  and the emailer's dropped-mail warnings. The AI image scan's verdict log
  (`image_scan rejected` / `cleared`, the record of a machine deleting a
  member's image) would go the same way. `Vutuv.Application` raises exactly
  those modules to :info via per-module log levels at boot; this covers the
  override so the alarms can never go silent again - and covers the boot line
  that says so, because a per-module level is invisible to every check an
  operator would run (issue #1575).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @modules [
    Vutuv.Deliverability.Watcher,
    Vutuv.Deliverability.Sweeper,
    Vutuv.Moderation.ImageScans,
    Vutuv.Notifications.Bounces,
    Vutuv.Notifications.Emailer
  ]

  test "ensure_ops_logs_visible/0 raises the ops modules to :info" do
    # The flag is off in test config (the suite wants the quiet :warning
    # default), so app start has not applied the override - apply and clean
    # up here.
    refute Application.get_env(:vutuv, :ops_log_visibility)
    reset_module_levels()

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

  test "the override announces itself in the log, at the raised level" do
    # Issue #1575: production logged [warning] while `config/prod.exs`,
    # `Logger.level()` and `:logger`'s primary config all said :error, and
    # none of those three can ever show a per-module override - so the node
    # has to say it out loud. The line rides the override it announces
    # (Vutuv.Application raises itself too), which is why it survives a
    # global level that is quieter than :info - :warning here, :error in
    # production.
    refute Application.get_env(:vutuv, :ops_log_visibility)
    assert Logger.level() == :warning
    reset_module_levels()

    log = capture_log(fn -> Vutuv.Application.ensure_ops_logs_visible() end)

    assert log =~ "logger_override primary=warning"
    for mod <- @modules, do: assert(log =~ inspect(mod))
  end

  defp reset_module_levels do
    Logger.delete_module_level(Vutuv.Application.ops_log_modules())
    on_exit(fn -> Logger.delete_module_level(Vutuv.Application.ops_log_modules()) end)
  end
end
