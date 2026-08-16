defmodule VutuvWeb.AgentDocs.MediaKitDoc do
  @moduledoc """
  The `/system/media-kit` page as a data map for the agent formats, and the
  owner of the boilerplate a journalist is meant to copy.

  The three boilerplate lengths, the fact list and the asset list live here
  rather than in the template, so the page and its `.md` sibling hand out the
  same words — and the `.md` sibling is the one that matters most on this page,
  because the thing most likely to fetch a media kit today is a language model
  writing about the software.

  Nothing here is translated: English only in every locale (see
  `VutuvWeb.CompanyController`).
  """

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.InvestorsDoc
  alias VutuvWeb.Endpoint

  # The size of the network a vutuv profile is reachable from, quoted with its
  # source and the day it was read (api.fedidb.org/v1/stats, 2026-08-16:
  # 14,209,407 accounts, 42,821 servers, 1,178,138 active in the past month).
  # Rounded down, never up, and the active figure travels with the total: a
  # boilerplate that names only the 14 million invites the first journalist who
  # looks it up to call it inflated. It is a fixed string rather than a live
  # fetch because boilerplate is copied into articles, where a number without a
  # date is worse than a slightly old one - and because an intranet installation
  # must not phone a third party to render its own media kit.
  @fediverse_accounts "14 million"
  @fediverse_servers "40,000"
  @fediverse_active "1.1 million"
  @fediverse_asof "FediDB, August 2026"

  @doc """
  The boilerplate in three lengths, so a writer can take the one that fits the
  hole they have. Each is complete on its own; the longer ones are not the
  shorter one with sentences bolted on.
  """
  def boilerplate do
    %{
      short:
        "Think LinkedIn, but without premium accounts and without a gated community: " <>
          "every profile is a public web page, and everything the site can do, it does " <>
          "for everybody. vutuv is open source, federates over ActivityPub and is paid " <>
          "for by advertising rather than by subscriptions.",
      medium:
        "Think LinkedIn, but quieter. vutuv is a professional network for your working " <>
          "life: a profile, a CV you can tailor and export, and a chronological feed with " <>
          "no algorithm deciding what you see. There are no premium accounts, because the " <>
          "site is paid for by advertising: one text ad per day, the same one for " <>
          "everybody, with no profiling behind it. There is no gated community either: a " <>
          "profile is a public web page that anyone can read without an account. It speaks " <>
          "ActivityPub, so a new vutuv profile reaches the whole Fediverse on its first " <>
          "day: more than #{@fediverse_accounts} accounts on over #{@fediverse_servers} " <>
          "servers, Mastodon among them, can follow it without joining vutuv " <>
          "(#{@fediverse_asof}). The software is MIT-licensed and anyone can run their " <>
          "own installation, on the internet or inside a company network.",
      long:
        "Think LinkedIn, but without the premium accounts and without the gated " <>
          "community. vutuv is a professional network for your working life. Members keep " <>
          "a profile with " <>
          "their work history, skills and qualifications, build a CV from it that they can " <>
          "tailor per application and export as PDF, Word, LaTeX or JSON Resume, and read a " <>
          "strictly chronological feed: no algorithm decides what reaches them, and no " <>
          "tracking follows them off the site. The site is paid for by advertising, one " <>
          "text ad per day shown to everybody with no profiling behind it, so no feature " <>
          "is held back for a paying tier. Nothing is walled off either: a profile is a " <>
          "public web page at a stable address, readable in full without an account and " <>
          "served as Markdown, plain text, JSON and XML for machines. vutuv speaks " <>
          "ActivityPub, so a profile can be followed from Mastodon and every other " <>
          "Fediverse server, and posts travel both ways. That means a brand-new profile " <>
          "starts with reach rather than with an empty room: more than " <>
          "#{@fediverse_accounts} accounts on over #{@fediverse_servers} servers can " <>
          "follow it without joining vutuv, about #{@fediverse_active} of them active in " <>
          "the past month (#{@fediverse_asof}). The software is written in Elixir " <>
          "on the Phoenix framework, is MIT-licensed " <>
          "and self-hostable, and runs on modest hardware: a company or an association can " <>
          "put an installation inside its own network without any part of it phoning home. " <>
          this_installation()
    }
  end

  # The one sentence in the boilerplate that is about an installation rather
  # than about the software, built from the operator identity so a third-party
  # installation names itself and never us.
  defp this_installation do
    "#{Endpoint.host()} is the installation operated by " <>
      Application.fetch_env!(:vutuv, :operator_name) <> "."
  end

  @doc "The key facts, as `{label, value}` pairs in the order they are shown."
  def facts do
    [
      {"License", "MIT"},
      {"Protocol", "ActivityPub (Mastodon-compatible)"},
      {"Stack", "Elixir, Phoenix, PostgreSQL"},
      {"Self-hostable", "Yes, on the internet or on an intranet"},
      {"Source", "https://github.com/wintermeyer/vutuv"},
      # The oldest account on vutuv.de was created on 2016-11-20, and 2,615
      # members had joined before 2017. 2019 was wrong.
      {"Founded", "2016"}
    ]
  end

  @doc """
  The brand assets, each `%{name:, note:, path:, kind:}`. `path` is served from
  `priv/static`, so a download link is the path itself.
  """
  def assets do
    [
      %{
        name: "Wordmark, dark",
        note: "For light backgrounds. SVG, scales to any size.",
        path: "/images/brand/vutuv-wordmark.svg",
        kind: "SVG"
      },
      %{
        name: "Wordmark, white",
        note: "For dark backgrounds and photos.",
        path: "/images/brand/vutuv-wordmark-white.svg",
        kind: "SVG"
      },
      %{
        name: "Icon mark",
        note: "The v on the brand square, for avatars and favicons.",
        path: "/images/brand/vutuv-mark.svg",
        kind: "SVG"
      },
      %{
        name: "App icon, 512px",
        note: "Raster version of the icon mark, for stores and directories.",
        path: "/images/brand/vutuv-app-icon-512.png",
        kind: "PNG"
      }
    ]
  end

  @doc "The brand colours, as `{name, hex, note}`."
  def colors do
    [
      {"Brand blue", "#2563EB", "Primary. Buttons, links, the icon mark."},
      {"Brand blue, deep", "#1E40AF", "The dark end of the icon mark's gradient."},
      {"Coral", "#F97362", "Accent. Unread counts and the one thing that wants a look."},
      {"Ink", "#0F172A", "Text on light backgrounds."},
      {"Canvas", "#F1F5F9", "The page behind the white cards."}
    ]
  end

  @doc "The typefaces, as `{role, name, note}`."
  def typography do
    [
      {"Everything", "system UI stack",
       "vutuv ships no webfont: it renders in the reader's own system typeface " <>
         "(San Francisco, Segoe UI, Roboto). Nothing is loaded from another host."},
      {"Code", "monospace system stack", "Code blocks and technical values."}
    ]
  end

  @doc "The screenshots, as `%{name:, note:, path:}`."
  def screenshots do
    [
      %{
        name: "Profile",
        note: "A member profile with work history, skills and posts.",
        path: "/images/brand/screenshot-profile.png"
      },
      %{
        name: "Feed",
        note: "The chronological feed, vutuv posts and Fediverse posts side by side.",
        path: "/images/brand/screenshot-feed.png"
      },
      %{
        name: "CV builder",
        note: "The CV assembled from the profile, tailored per application.",
        path: "/images/brand/screenshot-cv.png"
      },
      %{
        name: "Start page",
        note: "What a visitor sees who is not signed in.",
        path: "/images/brand/screenshot-landing.png"
      }
    ]
  end

  @doc "The usage rules, one sentence each."
  def usage_rules do
    [
      "Use the logo in reporting about vutuv without asking us first, unmodified and with " <>
        "clear space around it.",
      "Do not stretch, recolour or rebuild the logo, and do not put it on a background it " <>
        "cannot be read against.",
      "Using the logo does not imply that we endorse what it sits next to.",
      "If you run your own vutuv installation, give it your own name and brand: the vutuv " <>
        "wordmark stands for this project, not for every installation of it.",
      "The screenshots on this page may be reproduced in reporting about vutuv."
    ]
  end

  @doc """
  Where a journalist writes to — the same operator contact the investor page
  uses, so a third-party installation names its own operator.
  """
  def press_contact, do: InvestorsDoc.contact_email()

  @doc """
  The person behind that address. `:operator_recipient` carries the name beside
  the email, so naming them costs no second config key and a third-party
  installation names its own operator.
  """
  def press_contact_name do
    {name, _email} = Application.fetch_env!(:vutuv, :operator_recipient)
    name
  end

  @doc """
  Their profile on this installation, for the contact details a media kit
  should not spell out itself (phone, messengers, other addresses), or `nil`.
  Both company pages offer it, so it lives beside the address in
  `InvestorsDoc`.
  """
  defdelegate press_contact_profile_url, to: InvestorsDoc, as: :contact_profile_url

  @doc "The media kit as a doc map."
  def build do
    AgentDocs.doc_meta("media_kit", "/system/media-kit")
    |> Map.merge(%{
      title: "Media Kit",
      description: "Boilerplate, brand assets, screenshots and press contact for vutuv.",
      language: "en",
      boilerplate: boilerplate(),
      facts: Map.new(facts()),
      assets: Enum.map(assets(), &Map.put(&1, :url, AgentDocs.abs_url(&1.path))),
      colors: Enum.map(colors(), fn {name, hex, note} -> %{name: name, hex: hex, note: note} end),
      typography:
        Enum.map(typography(), fn {role, name, note} ->
          %{role: role, name: name, note: note}
        end),
      screenshots: Enum.map(screenshots(), &Map.put(&1, :url, AgentDocs.abs_url(&1.path))),
      usage: usage_rules(),
      press_contact: %{
        name: press_contact_name(),
        email: press_contact(),
        profile_url: press_contact_profile_url()
      },
      operator: %{
        name: Application.fetch_env!(:vutuv, :operator_name),
        url: Application.fetch_env!(:vutuv, :operator_url)
      }
    })
  end
end
