defmodule VutuvWeb.PushLine do
  @moduledoc """
  The generic line a Web Push turns into on a lock screen, per kind and per
  locale (issue #1729).

  The third per-kind vocabulary in this app, beside `VutuvWeb.NotificationLine`
  (the row under the bell) and `VutuvWeb.NotificationDigestText` (the summary
  mail) — and deliberately the shortest of the three, because it is the only
  one whose reader has not opened anything yet. A push carries **no content**
  (see `Vutuv.WebPush`), so what a phone shows is drawn from this table alone:
  it may say what *sort* of thing happened and must never say the thing itself.
  Anything the member wants to read is one tap away under the bell.

  Three kinds, not thirty. Every other kind is `:activity`, which is a product
  decision rather than a gap: "Someone endorsed you" and "Someone replied" are
  the same errand to somebody glancing at a locked phone, and each extra line
  is a translation in every locale this installation serves.

  It answers for **every** locale at once, because the reader is a service
  worker: it has no session and no gettext, so it is handed the whole table and
  picks by the `locale` in the payload (`assets/js/sw.js`). That is also why
  the worker never hardcodes the kind list — it reads the keys of this table.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Languages

  @kinds [:message, :follower, :activity]

  @doc "The kinds a push can name. Everything else is drawn as `:activity`."
  def kinds, do: @kinds

  @doc """
  `%{kind => %{locale => line}}` for every locale this installation serves —
  the table `VutuvWeb.ServiceWorkerController` hands the worker.
  """
  def table do
    Map.new(@kinds, fn kind -> {kind, per_locale(kind)} end)
  end

  defp per_locale(kind) do
    Map.new(Languages.site_locales(), fn locale ->
      {locale, Gettext.with_locale(VutuvWeb.Gettext, locale, fn -> line(kind) end)}
    end)
  end

  defp line(:message), do: gettext("New message on vutuv")
  defp line(:follower), do: gettext("Someone started following you on vutuv")
  defp line(:activity), do: gettext("Something new on vutuv")
end
