defmodule VutuvWeb.OrganizationVocabularyTest do
  @moduledoc """
  The organization-page entry points must read for a normal member, not for a
  domain admin. The old German "Organisation beanspruchen" ("claim") was jargon
  most members did not understand, so the call to action is now the plain
  "Ihre Organisation hinzufügen" ("add your organization") and the claim wizard
  spells out *why* a domain has to be verified and *who* to ask for the
  technical step. This guards that copy against drift in the gettext catalog.

  Calls go through `Gettext.gettext/2,3` (the runtime API, not the macro) on
  purpose, so `mix gettext.extract` does not treat these strings as new msgids
  (see `VutuvWeb.ConnectionVocabularyTest`).
  """
  use ExUnit.Case, async: true

  @backend VutuvWeb.Gettext

  setup do
    Gettext.put_locale(@backend, "de")
    :ok
  end

  defp de(msgid), do: Gettext.gettext(@backend, msgid)
  defp de(msgid, bindings), do: Gettext.gettext(@backend, msgid, bindings)

  test "the call to action says 'hinzufügen', never the old 'beanspruchen' jargon" do
    assert de("Add your organization") == "Ihre Organisation hinzufügen"
    refute de("Add your organization") =~ "beanspruch"
  end

  test "the directory title is the plural 'Organisationen'" do
    # Regression: it used to be the singular "Organisation".
    assert de("Organizations") == "Organisationen"
  end

  test "the wizard explains why we verify and who to ask, in German" do
    # Why we verify at all (trust, no impersonation).
    why =
      de(
        "So visitors can trust the page. We only publish it once you prove that you control the organization's web domain, so nobody can put up a page that pretends to be your organization."
      )

    assert why =~ "vertrauen"
    assert why =~ "Domain"
    refute why =~ "web domain", "should be translated, not an English island"

    # Non-technical members are pointed at their IT / website admin.
    help =
      de(
        "The proof is a small technical change to your domain: a DNS entry or a file on your website. If you don't manage the website yourself, ask the person or team who does. That is usually your IT department or the company that runs your website. We show the exact instructions on the next step, so you can simply pass them on."
      )

    assert help =~ "IT"
    assert help =~ "Website"
  end

  test "the pending verification panel is fully translated (no English island)" do
    prove = de("Prove you control %{domain} to publish this page.", domain: "acme.example")
    assert prove =~ "acme.example"
    refute prove =~ "Prove you control", "the German msgstr must not fall back to English"
  end

  test "the 'Your organizations' settings hub explains ownership in German" do
    assert de("Your organizations") == "Ihre Organisationen"

    # The creator-becomes-owner rule.
    assert de("Whoever creates a page becomes its owner.") =~ "Besitzer"

    # Invite others + transfer ownership, fully translated.
    invite =
      de(
        "The owner can invite other members onto the page as admins or recruiters, and can hand ownership over to someone else at any time."
      )

    assert invite =~ "einladen"
    assert invite =~ "übergeben"
    refute invite =~ "invite other members", "the German msgstr must not fall back to English"
  end
end
