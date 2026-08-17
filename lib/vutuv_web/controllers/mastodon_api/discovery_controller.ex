defmodule VutuvWeb.MastodonApi.DiscoveryController do
  @moduledoc """
  Public instance and OAuth discovery documents used before a Mastodon client
  has registered or obtained a bearer token.
  """

  use VutuvWeb, :controller

  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.NodeInfo
  alias Vutuv.Posts.Post

  @source_url "https://github.com/wintermeyer/vutuv"
  def instance_v2(conn, _params) do
    usage = NodeInfo.usage()

    json(conn, %{
      domain: MastodonApi.local_domain(),
      title: node_name(),
      version: MastodonApi.compatibility_version(),
      source_url: @source_url,
      description: node_description(),
      usage: %{users: %{active_month: usage.users.active_month}},
      thumbnail: %{
        url: MastodonApi.main_url("/images/icon-512.png"),
        blurhash: nil,
        versions: %{
          "@1x" => MastodonApi.main_url("/images/icon-192.png"),
          "@2x" => MastodonApi.main_url("/images/icon-512.png")
        }
      },
      languages: locales(),
      configuration: configuration(),
      registrations: %{enabled: false, approval_required: false, message: nil},
      contact: %{email: "", account: nil},
      rules: []
    })
  end

  def instance_v1(conn, _params) do
    usage = NodeInfo.usage()

    json(conn, %{
      uri: MastodonApi.local_domain(),
      title: node_name(),
      short_description: node_description(),
      description: node_description(),
      email: "",
      version: MastodonApi.compatibility_version(),
      urls: %{streaming_api: nil},
      stats: %{
        user_count: usage.users.total,
        status_count: usage.local_posts + usage.local_comments,
        domain_count: 0
      },
      thumbnail: MastodonApi.main_url("/images/icon-512.png"),
      languages: locales(),
      registrations: false,
      approval_required: false,
      invites_enabled: false,
      configuration: configuration(),
      contact_account: nil,
      rules: [],
      max_toot_chars: Post.max_body_length()
    })
  end

  # Every endpoint is named on the host the client actually reached us on, so a
  # client that typed the main address is never sent across to the subdomain
  # mid-flow — which is exactly where a bearer token gets dropped. The consent
  # screen is the one deliberate exception: it is a browser page and lives on
  # the main host whatever the client used.
  def oauth_metadata(conn, _params) do
    here = &MastodonApi.client_url(conn.host, &1)

    json(conn, %{
      issuer: here.("/"),
      service_documentation: "https://docs.joinmastodon.org/",
      authorization_endpoint: MastodonApi.main_url("/oauth/authorize"),
      token_endpoint: here.("/oauth/token"),
      app_registration_endpoint: here.("/api/v1/apps"),
      revocation_endpoint: here.("/oauth/revoke"),
      scopes_supported: Scopes.all(),
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      code_challenge_methods_supported: ["S256"],
      grant_types_supported: ["authorization_code", "refresh_token", "client_credentials"],
      token_endpoint_auth_methods_supported: ["client_secret_post"]
    })
  end

  def not_found(conn, _params), do: send_resp(conn, 404, "")

  defp configuration do
    %{
      urls: %{streaming: nil},
      accounts: %{max_featured_tags: 10},
      statuses: %{
        max_characters: Post.max_body_length(),
        max_media_attachments: 0,
        characters_reserved_per_url: 0
      },
      media_attachments: %{
        supported_mime_types: [],
        image_size_limit: 0,
        image_matrix_limit: 0,
        video_size_limit: 0,
        video_frame_rate_limit: 0,
        video_matrix_limit: 0
      },
      polls: %{
        max_options: 0,
        max_characters_per_option: 0,
        min_expiration: 0,
        max_expiration: 0
      },
      translation: %{enabled: false}
    }
  end

  defp node_name, do: Application.fetch_env!(:vutuv, :node_name)
  defp node_description, do: Application.fetch_env!(:vutuv, :node_description)

  defp locales do
    {:ok, config} = Application.fetch_env(:vutuv, VutuvWeb.Endpoint)
    config[:locales]
  end
end
