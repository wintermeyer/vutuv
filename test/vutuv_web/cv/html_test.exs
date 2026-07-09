defmodule VutuvWeb.CV.HtmlTest do
  @moduledoc """
  The self-contained print/download CV document. An entry description is
  Markdown rendered through the profile's sanitizing pipeline; its relative
  `/handle` links are absolutized so a downloaded standalone file still
  resolves them against this installation's URL.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.CV.Html
  alias VutuvWeb.Endpoint

  # A minimal CV data map with a single work-experience entry carrying `body`
  # as its Markdown description; everything else is empty.
  defp cv(body) do
    %{
      name: "Erika Mustermann",
      headline: nil,
      photo: nil,
      email: nil,
      phone: nil,
      profile_url: nil,
      address_lines: [],
      birthdate: nil,
      gender: nil,
      sections: [
        %{
          heading: "Experience",
          entries: [
            %{
              id: "entry-1",
              period: nil,
              title: "Developer",
              organization: nil,
              description: body
            }
          ]
        }
      ],
      skills: [],
      qualifications: [],
      languages: [],
      links: [],
      social_media: []
    }
  end

  test "a root-relative /handle link in a description is absolutized" do
    html = Html.render(cv("See [my profile](/erika)"))

    assert html =~ ~s(href="#{Endpoint.url()}/erika")
    refute html =~ ~s(href="/erika")
  end

  test "a protocol-relative //host link is left alone, not prefixed with base" do
    html = Html.render(cv("See [this](//evil.com)"))

    # The negative lookahead must skip `//`: prefixing it would corrupt the
    # link into `#{Endpoint.url()}//evil.com`.
    assert html =~ ~s(href="//evil.com")
    refute html =~ ~s(href="#{Endpoint.url()}//evil.com")
  end
end
