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

    * `Female` / `Male` / `Diverse` — `Vutuv.Accounts.User.gender_label/1`
    * `Open to offers` / `Looking for a job` — the employment-status labels
      `Vutuv.Accounts.User.employment_status_label/1` returns (issue #870)
    * The visibility labels (`Everyone, including logged-out visitors` /
      `Signed-in members only` / `No one`) that
      `Vutuv.Accounts.User.visibility_label/1` returns, and the salary-period
      nouns (`hour` / `day` / `week` / `month` / `year`) that
      `Vutuv.Accounts.User.desired_salary_period_label/1` returns (issue #928)
    * `Incorrect PIN` / `PIN expired` / `This PIN has already been used.` — the
      PIN check messages in `Vutuv.Accounts`
    * `Connected` — the connection relationship word guarded by
      `VutuvWeb.ConnectionVocabularyTest` (issue #797), asserted via the runtime
      API so the test file itself does not inject a msgid.
    * The `Vutuv.Prefs` registry labels/hints/value words (`label/1`, `hint/1`,
      `group_label/1`, `value_label/2`) — resolved at render time through the
      runtime API so the registry stays a plain data module. Some also appear
      in the /settings templates today; anchoring them all keeps the catalog
      stable even if a template stops using one.
  """
  use Gettext, backend: VutuvWeb.Gettext

  @doc false
  # Never called. Each entry mirrors a runtime Gettext.gettext/2 call elsewhere.
  def anchored do
    [
      gettext("Ms."),
      gettext("Mr."),
      gettext("Incorrect PIN"),
      gettext("PIN expired"),
      gettext("This PIN has already been used."),
      gettext("Connected"),
      gettext("Open to offers"),
      gettext("Looking for a job"),
      # The shared visibility labels (issue #928),
      # Vutuv.Accounts.User.visibility_label/1
      gettext("Everyone, including logged-out visitors"),
      gettext("Signed-in members only"),
      gettext("No one"),
      # The birthday-visibility granularity labels,
      # Vutuv.Accounts.User.birthdate_visibility_label/1
      gettext("Full date and age"),
      gettext("Age only, without the date"),
      gettext("Day and month, without the year"),
      gettext("Do not show my birthday"),
      # The salary-expectation period nouns (issue #928),
      # Vutuv.Accounts.User.desired_salary_period_label/1
      gettext("hour"),
      gettext("day"),
      gettext("week"),
      gettext("month"),
      gettext("year"),
      gettext("Lines on desktop"),
      gettext("Lines on mobile"),
      gettext("Hyphenate on desktop"),
      gettext("Hyphenate on mobile"),
      gettext("Show Google Maps"),
      gettext("Show OpenStreetMap"),
      gettext("Show Apple Maps"),
      gettext("Default map"),
      gettext("Lines in notifications"),
      gettext("Show my name on posts I like"),
      gettext(
        "When off, other members no longer see you among the likes of a post. The author of the post still does: we named you in the notification they got when you liked it. Either way the post keeps the same number of likes."
      ),
      gettext("Privacy"),
      # Vutuv.Prefs — the feed language preference (issue #1461)
      gettext("Posts in other languages"),
      gettext("Translate into my language"),
      gettext("Hide them"),
      gettext(
        "What your feed does with posts outside your chosen languages: show them as they are, translate them for you, or hide them. Posts that declare no language always show."
      ),
      gettext("Feed"),
      # Vutuv.Prefs — the feed's tab ticker (issue #1668)
      gettext("Feed tabs"),
      gettext("Quote what arrives on the other tab"),
      gettext("How long the quote stands"),
      gettext("When off, a tab holding something new wears its dot and says nothing more."),
      gettext("Between 4 and 20 seconds."),
      gettext("0 means posts are never shortened."),
      gettext("How much of a post a notification quotes before it is cut off."),
      gettext("Opens first, as the main button. The others appear as alternatives."),
      gettext("Posts"),
      gettext("Maps"),
      gettext("On"),
      gettext("Off"),
      # Vutuv.Prefs + Vutuv.DateRegions — the viewer clock (issue #1502)
      gettext("Date format"),
      gettext("Time zone"),
      gettext("Date & time"),
      gettext(
        "The order and punctuation of every date you read here, and whether times run on a 12- or 24-hour clock."
      ),
      gettext(
        "Posts, messages and notifications are stamped in this zone. New accounts take it from the browser."
      ),
      # Vutuv.DateRegions.label/1 — the regions each date shape is named after
      gettext("Germany, Austria, Switzerland"),
      gettext("United Kingdom, France, Brazil"),
      gettext("United States"),
      gettext("ISO 8601 (Sweden, Japan, China)")
    ]
  end
end
