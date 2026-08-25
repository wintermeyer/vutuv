defmodule VutuvWeb.MastodonApi.DiscoveryController do
  @moduledoc """
  Public instance and OAuth discovery documents used before a Mastodon client
  has registered or obtained a bearer token.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Languages
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.NodeInfo
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.SourceRepo
  alias Vutuv.Uploads.Spec
  alias VutuvWeb.MastodonApi.Errors

  def instance_v2(conn, _params) do
    usage = NodeInfo.usage()

    json(conn, %{
      domain: MastodonApi.local_domain(),
      title: node_name(),
      version: MastodonApi.compatibility_version(),
      source_url: SourceRepo.url(),
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
      configuration: configuration(conn),
      registrations: %{enabled: false, approval_required: false, message: nil},
      api_versions: MastodonApi.api_versions(),
      contact: %{email: MastodonApi.operator_email(), account: contact_account()},
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
      email: MastodonApi.operator_email(),
      version: MastodonApi.compatibility_version(),
      urls: %{streaming_api: MastodonApi.streaming_url(conn.host)},
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
      configuration: configuration(conn),
      contact_account: contact_account(),
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

  @doc """
  The root of the technical API host, for the person who typed it.

  Everything on this origin is for a client, and every other path answers JSON,
  so the one address a human plausibly reaches by hand deserves the site rather
  than an error. It is a redirect and not a page on purpose: this host must not
  start serving anything readable, or it becomes a second address for the same
  content.
  """
  def root(conn, _params), do: redirect(conn, external: MastodonApi.main_url("/"))

  @doc """
  The answer for a Mastodon path this adapter does not implement.

  JSON, in Mastodon's own error shape, because a client decodes **every**
  response body as JSON. On the main host — the one a member types into a phone
  app, and so the one every client actually uses — an unrouted `/api/v1/…` used
  to fall through to the website's HTML error page, so a startup call for a
  resource we simply do not have (`/api/v1/announcements`, `/api/v1/trends/…`,
  `POST /api/v1/markers`) handed the client a page of markup where it expected
  an object. That is not a missing feature to a client, it is a broken server.
  """
  def not_found(conn, _params), do: Errors.not_found(conn)

  # The MIME types the post-image uploader really accepts, from its own
  # extension whitelist, so this cannot drift from what an upload does.
  defp supported_mime_types do
    Vutuv.PostImageStore.extension_whitelist()
    |> Enum.map(&MIME.from_path("x" <> &1))
    |> Enum.uniq()
  end

  # Mastodon states the pixel budget of an image, not its dimensions. Ours is
  # the largest served version squared — a generous bound, since a picture is
  # scaled down to that width anyway.
  defp image_matrix_limit do
    width = Spec.max_width(:post_image)
    width * width
  end

  # What this installation can actually do. Every figure here used to be a zero
  # or an empty list, and a client believes them: `supported_mime_types: []` is
  # what a phone client reads before it converts a picture out of the photo
  # library, so with nothing to convert *to* it uploads the camera's original
  # HEIC, which the uploader then refuses — the "Send a JPEG, PNG or WebP image"
  # a member saw after waiting for the upload. `max_media_attachments: 0` says
  # posts take no pictures at all. They are derived now, so an installation
  # whose libvips decodes HEIC advertises it without anybody editing this.
  defp configuration(conn) do
    %{
      urls: %{streaming: MastodonApi.streaming_url(conn.host)},
      accounts: %{max_featured_tags: 10},
      statuses: %{
        max_characters: Post.max_body_length(),
        max_media_attachments: Posts.max_images_per_post(),
        characters_reserved_per_url: 0
      },
      media_attachments: %{
        supported_mime_types: supported_mime_types(),
        image_size_limit: Posts.max_image_filesize(),
        image_matrix_limit: image_matrix_limit(),
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
    |> put_vapid()
  end

  # Where a Mastodon client has looked for the server's push key since 4.3,
  # which is why its absence broke switching push on before the client ever
  # reached `/api/v1/push/subscription`. Upstream carries it in the v2 document
  # only; it rides the shared builder here on purpose, since both documents
  # describe the same instance and an extra key costs a v1 client nothing.
  # Absent — not null — where push is off, so a client is told "no push here"
  # rather than handed an empty key to subscribe with.
  defp put_vapid(configuration) do
    case WebPush.public_key() do
      nil -> configuration
      key -> Map.put(configuration, :vapid, %{public_key: key})
    end
  end

  # The operator as a full Account entity, which is what a client links to. Both
  # documents used to answer an empty string and a `null` account, which a client
  # renders as an instance with nobody behind it — "Instance administrator" with
  # a blank line under it.
  #
  # Resolved through the member table on every request rather than stored: a
  # handle that names nobody here (the vutuv.de default on somebody else's
  # installation) has to answer `null`, not a dead profile — the same rule the
  # media kit's press contact follows. Counts are left at the entity's zeroes:
  # this is a contact card, not a profile header, and no client shows figures
  # on it.
  defp contact_account do
    with handle when is_binary(handle) and handle != "" <- MastodonApi.operator_handle(),
         %User{} = user <- Accounts.get_user_by_username(handle) do
      Presenter.account(user)
    else
      _no_such_member -> nil
    end
  end

  defp node_name, do: Application.fetch_env!(:vutuv, :node_name)
  defp node_description, do: Application.fetch_env!(:vutuv, :node_description)

  defp locales, do: Languages.site_locales()
end
