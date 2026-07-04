defmodule VutuvWeb.GettextExtractionAnchors do
  @moduledoc """
  Anchors for strings that reach gettext only through the **runtime** API
  (`Gettext.gettext/2` with a computed msgid or backend) at their real call
  sites. `mix gettext.extract` scans for the compile-time `gettext/1` macro, so
  it cannot see those call sites and `mix gettext.merge` would prune the
  translations on the next reconcile — silently turning them into English
  islands in production.

  Listing each one through the macro here keeps it in the catalog. Nothing in
  this module is ever executed; it exists purely so extraction can find these
  msgids. When you add a new runtime `Gettext.gettext/2,3` call with a literal
  msgid, add the same literal here.

    * `Male` / `Female` / `Diverse` — `Vutuv.Accounts.User.gender_gettext/1`
    * `Incorrect PIN` / `PIN expired` / `This PIN has already been used.` — the
      PIN check messages in `Vutuv.Accounts`
    * `Connected` — the connection relationship word guarded by
      `VutuvWeb.ConnectionVocabularyTest` (issue #797), asserted via the runtime
      API so the test file itself does not inject a msgid.
  """
  use Gettext, backend: VutuvWeb.Gettext

  @doc false
  # Never called. Each entry mirrors a runtime Gettext.gettext/2 call elsewhere.
  def anchored do
    [
      gettext("Male"),
      gettext("Female"),
      gettext("Diverse"),
      gettext("Incorrect PIN"),
      gettext("PIN expired"),
      gettext("This PIN has already been used."),
      gettext("Connected")
    ]
  end
end
